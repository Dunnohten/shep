import XCTest
@testable import ShepCore

final class BarkSynthTests: XCTestCase {
    func testLengthIsShortBark() {
        let n = BarkSynth.samples(volume: 0.6).count
        XCTAssertEqual(n, Int(BarkSynth.duration * 44_100))
        XCTAssertGreaterThanOrEqual(Double(n) / 44_100, 0.150)
        XCTAssertLessThanOrEqual(Double(n) / 44_100, 0.250)
        XCTAssertEqual(BarkSynth.samples(volume: 0.6, sampleRate: 22_050).count, Int(BarkSynth.duration * 22_050))
    }

    func testPeakNeverExceedsTheVolume() {
        for v in [0.05, 0.3, 0.6, 1.0] {
            let s = BarkSynth.samples(volume: v)
            let peak = s.map { abs(Double($0)) }.max() ?? 0
            XCTAssertLessThanOrEqual(peak, v, "volume \(v)")
            XCTAssertGreaterThan(peak, v * 0.9, "volume \(v): it should use the level it was given")
        }
    }

    func testStartsAndEndsNearSilence() {
        let s = BarkSynth.samples(volume: 1)
        XCTAssertLessThan(abs(Double(s[0])), 0.01)
        XCTAssertLessThan(abs(Double(s[s.count - 1])), 0.01)
        XCTAssertLessThan(s.suffix(20).map { abs(Double($0)) }.max() ?? 1, 0.05)
    }

    func testNoNaNOrInfinity() {
        for v in [0.0, 0.6, 1.0, 5.0, -2.0, Double.nan, Double.infinity] {
            XCTAssertTrue(BarkSynth.samples(volume: v).allSatisfy { $0.isFinite }, "\(v)")
        }
    }

    func testVolumeIsClamped() {
        XCTAssertEqual(BarkSynth.samples(volume: 0).map { abs($0) }.max() ?? 1, 0)
        XCTAssertEqual(BarkSynth.samples(volume: Double.nan).map { abs($0) }.max() ?? 1, 0)
        XCTAssertLessThanOrEqual(BarkSynth.samples(volume: 9).map { abs(Double($0)) }.max() ?? 2, 1)
    }

    func testDeterministic() {
        XCTAssertEqual(BarkSynth.samples(volume: 0.6), BarkSynth.samples(volume: 0.6))
    }

    func testItHasSoundInTheMiddleAndItDies() {
        let s = BarkSynth.samples(volume: 1)
        let early = s[0..<4_000].map { abs(Double($0)) }.max() ?? 0
        let late = s[(s.count - 3_000)...].map { abs(Double($0)) }.max() ?? 0
        XCTAssertGreaterThan(early, 0.5)
        XCTAssertLessThan(late, early * 0.5)   // decays
    }

    // MARK: shape of the bark

    private func rmsEnvelope(_ s: [Float], windowSeconds: Double) -> [Double] {
        let k = Int(windowSeconds * Double(BarkSynth.defaultSampleRate))
        var out: [Double] = []
        var i = 0
        while i + k <= s.count {
            var sum = 0.0
            for j in i..<(i + k) { sum += Double(s[j]) * Double(s[j]) }
            out.append((sum / Double(k)).squareRoot())
            i += k
        }
        return out
    }

    /// Normalised autocorrelation pitch over lags for 250...1100 Hz.
    private func pitchEstimate(_ part: [Float]) -> Double {
        let sr = Double(BarkSynth.defaultSampleRate)
        let mean = part.reduce(0.0) { $0 + Double($1) } / Double(part.count)
        let x = part.map { Double($0) - mean }
        var bestLag = 0
        var best = -Double.infinity
        for lag in Int(sr / 1_100)...Int(sr / 250) {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for i in 0..<(x.count - lag) {
                xy += x[i] * x[i + lag]; xx += x[i] * x[i]; yy += x[i + lag] * x[i + lag]
            }
            let r = xy / ((xx * yy).squareRoot() + 1e-12)
            if r > best { best = r; bestLag = lag }
        }
        return sr / Double(bestLag)
    }

    func testAttackPeakIsInTheFirstTenMilliseconds() {
        let s = BarkSynth.samples(volume: 1)
        var peakIndex = 0
        var peak = 0.0
        for (i, v) in s.enumerated() where abs(Double(v)) > peak { peak = abs(Double(v)); peakIndex = i }
        XCTAssertLessThan(Double(peakIndex) / Double(BarkSynth.defaultSampleRate), 0.010)
        XCTAssertLessThanOrEqual(BarkSynth.attack, 0.005)
    }

    func testEnvelopeDecaysWithoutWobble() {
        // 5 ms RMS windows. After the peak the envelope must fall; only a window that is at least 10 % of the peak counts as a
        // local maximum (a ripple in the quiet tail is not a wobble), and there may be at most one, the bark's own peak.
        let env = rmsEnvelope(BarkSynth.samples(volume: 1), windowSeconds: 0.005)
        let top = env.max() ?? 0
        XCTAssertGreaterThan(top, 0)
        var maxima = 0
        for i in 1..<(env.count - 1) where env[i] > env[i - 1] && env[i] > env[i + 1] && env[i] >= 0.1 * top { maxima += 1 }
        XCTAssertLessThanOrEqual(maxima, 1, "envelope: \(env)")
        let peakWindow = env.firstIndex(of: top) ?? 0
        XCTAssertLessThanOrEqual(peakWindow, 2)
        XCTAssertLessThan(env[env.count - 4], top * 0.1)   // a fast decay
    }

    func testPitchSweepsDown() {
        let s = BarkSynth.samples(volume: 1)
        let k = Int(0.040 * Double(BarkSynth.defaultSampleRate))
        let start = pitchEstimate(Array(s[0..<k]))
        let end = pitchEstimate(Array(s[(s.count - k)...]))
        XCTAssertGreaterThanOrEqual(start, 600, "start \(start) Hz")
        XCTAssertLessThan(end, start - 100, "end \(end) Hz, start \(start) Hz")
        XCTAssertGreaterThanOrEqual(BarkSynth.startPitch, 650)
        XCTAssertLessThanOrEqual(BarkSynth.startPitch, 900)
    }

    func testNoLowRumble() {
        // Energy below 200 Hz by a direct DFT of the bins 0...200 Hz against the total energy (Parseval).
        let s = BarkSynth.samples(volume: 1).map { Double($0) }
        let n = s.count
        let sr = Double(BarkSynth.defaultSampleRate)
        let total = s.reduce(0.0) { $0 + $1 * $1 }
        var low = 0.0
        let topBin = Int(200.0 * Double(n) / sr)
        for k in 0...topBin {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * Double(k) / Double(n)
            for (i, x) in s.enumerated() { re += x * cos(w * Double(i)); im -= x * sin(w * Double(i)) }
            let power = (re * re + im * im) / Double(n)
            low += (k == 0 ? 1 : 2) * power
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(low / total, 0.05, "low-frequency share \(low / total)")
    }
}

final class WavWriterTests: XCTestCase {
    func testHeader() throws {
        let samples = BarkSynth.samples(volume: 0.6)
        let d = WavWriter.data(samples: samples)
        XCTAssertEqual(d.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: d[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: d[36..<40], as: UTF8.self), "data")
        func u32(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
        XCTAssertEqual(u32(4), 36 + samples.count * 2)
        XCTAssertEqual(u32(16), 16)
        XCTAssertEqual(u16(20), 1)              // PCM
        XCTAssertEqual(u16(22), 1)              // mono
        XCTAssertEqual(u32(24), 44_100)
        XCTAssertEqual(u32(28), 88_200)         // byte rate
        XCTAssertEqual(u16(32), 2)              // block align
        XCTAssertEqual(u16(34), 16)             // bits
        XCTAssertEqual(u32(40), samples.count * 2)
    }

    func testSamplesAreClampedLittleEndian() {
        let d = WavWriter.data(samples: [0, 1, -1, 2, .nan], sampleRate: 8_000)
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[44 + 2 * i]) | UInt16(d[45 + 2 * i]) << 8)) }
        XCTAssertEqual([s16(0), s16(1), s16(2), s16(3), s16(4)], [0, 32_767, -32_767, 32_767, 0])
    }
}

final class FinishBeatTests: XCTestCase {
    func testOrderedStepsWithBarkAndHop() {
        let s = FinishBeat.steps(reduceMotion: false, barkEnabled: true, voiceOverRunning: false)
        XCTAssertEqual(s.map(\.action), [.earsUp, .announceDone, .hop, .woof, .goHome])
        XCTAssertEqual(s.map(\.at), s.map(\.at).sorted())
        XCTAssertEqual(s[0].at, 0)
        XCTAssertEqual(s[2].at, FinishBeat.woofDelay); XCTAssertEqual(s[3].at, FinishBeat.woofDelay)   // hop and woof together
        XCTAssertGreaterThanOrEqual(s[4].at, s[3].at + FinishBeat.hopSeconds + FinishBeat.holdAfterWoof - 0.0001)
    }

    func testReduceMotionHasNoHop() {
        let s = FinishBeat.steps(reduceMotion: true, barkEnabled: true, voiceOverRunning: false)
        XCTAssertEqual(s.map(\.action), [.earsUp, .announceDone, .woof, .goHome])
    }

    func testBarkOffMeansNoWoof() {
        let s = FinishBeat.steps(reduceMotion: false, barkEnabled: false, voiceOverRunning: false)
        XCTAssertFalse(s.map(\.action).contains(.woof))
        XCTAssertTrue(s.map(\.action).contains(.hop))
        XCTAssertEqual(s.last?.action, .goHome)
    }

    func testVoiceOverWaitsButNotForever() {
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: false), FinishBeat.woofDelay)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: nil), FinishBeat.voiceOverTimeout)   // never told: timeout
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: 0.9), 0.9)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: 4), FinishBeat.voiceOverTimeout)
        XCTAssertEqual(FinishBeat.woofTime(voiceOverRunning: true, voiceOverFinishedAt: 0.01), FinishBeat.woofDelay)
        let s = FinishBeat.steps(reduceMotion: false, barkEnabled: true, voiceOverRunning: true)
        XCTAssertEqual(s.first { $0.action == .woof }?.at, FinishBeat.voiceOverTimeout)
    }

    func testHopArc() {
        XCTAssertEqual(FinishBeat.hopOffset(at: 0), 0)
        XCTAssertEqual(FinishBeat.hopOffset(at: FinishBeat.hopSeconds), 0)
        XCTAssertEqual(FinishBeat.hopOffset(at: FinishBeat.hopSeconds / 2), FinishBeat.hopHeight, accuracy: 1e-9)
        XCTAssertEqual(FinishBeat.hopOffset(at: -1), 0); XCTAssertEqual(FinishBeat.hopOffset(at: 5), 0)
    }

    func testAnnouncementIsDone() { XCTAssertEqual(FinishBeat.announcement, "Done.") }
}
