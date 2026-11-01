import Foundation

/// Written for Shep.
/// The old synthesized woof. What plays now is the recorded bark (`BarkSound`); this is only the fallback when that recording
/// cannot be read (it always can: `BarkSoundTests`). Synthesized from nothing at runtime: no audio assets, no samples. One short, soft dog bark of 200 ms:
/// a sawtooth source whose pitch falls quickly from 820 Hz to 380 Hz, shaped by two formant band-pass filters (about 1.15 kHz
/// and 1.9 kHz) and a 200 Hz high-pass, so there is no low rumble. A 3 ms attack, a fast exponential decay and a little
/// band-passed noise in the first 35 ms (the breath of the burst). No tremolo, no amplitude wobble of any kind.
/// Deterministic: the same inputs give the same samples, always.
public enum BarkSynth {
    public static let defaultSampleRate = 44_100
    public static let duration = 0.2
    public static let startPitch = 820.0
    public static let endPitch = 380.0
    public static let attack = 0.003
    public static let decayTime = 0.045    // envelope time constant
    public static let fadeOut = 0.015
    public static let noiseSeconds = 0.035 // the noise burst at the start
    public static let highPassHz = 250.0

    /// Mono samples in -volume...volume (the peak is exactly the volume, a hair below). `volume` is clamped to 0...1.
    public static func samples(volume: Double, sampleRate: Int = defaultSampleRate) -> [Float] {
        let v = volume.isFinite ? min(1, max(0, volume)) : 0
        let sr = Double(max(8_000, sampleRate))
        let count = Int(duration * sr)
        guard count > 0, v > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        var f1 = Biquad.bandPass(frequency: 1_150, q: 3, sampleRate: sr)
        var f2 = Biquad.bandPass(frequency: 1_900, q: 4, sampleRate: sr)
        var breath = Biquad.bandPass(frequency: 1_600, q: 1.2, sampleRate: sr)
        var rumbleCut = Biquad.highPass(frequency: highPassHz, q: 0.707, sampleRate: sr)
        var phase = 0.0
        var noise: UInt32 = 12_345
        var raw = [Double](repeating: 0, count: count)
        var peak = 0.0
        for i in 0..<count {
            let t = Double(i) / sr
            let u = t / duration
            let pitch = startPitch * pow(endPitch / startPitch, u)
            phase += pitch / sr
            phase -= phase.rounded(.down)
            noise = noise &* 1_664_525 &+ 1_013_904_223   // deterministic breath
            let white = Double(noise >> 8) / Double(1 << 24) - 0.5
            let source = 2 * phase - 1
            let voiced = f1.process(source) + 0.7 * f2.process(source)
            let burstGain = max(0, 1 - t / noiseSeconds) * exp(-t / 0.012)
            let burst = breath.process(white) * burstGain * 1.2
            let body = rumbleCut.process(voiced + burst)
            let attackGain = min(1, t / attack)
            let decay = exp(-t / decayTime)
            let tail = min(1, (duration - t) / fadeOut)
            let y = body * attackGain * decay * max(0, tail)
            raw[i] = y
            peak = max(peak, abs(y))
        }
        guard peak > 0 else { return [Float](repeating: 0, count: count) }
        let scale = v * 0.999 / peak
        return raw.map { Float($0 * scale) }
    }
}

/// One biquad section (RBJ cookbook), direct form I.
struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    /// Band-pass, constant 0 dB peak gain.
    static func bandPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        var b = Biquad()
        b.b0 = alpha / a0; b.b1 = 0; b.b2 = -alpha / a0
        b.a1 = -2 * cos(w0) / a0; b.a2 = (1 - alpha) / a0
        return b
    }

    /// Second-order high-pass.
    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        var b = Biquad()
        b.b0 = (1 + c) / 2 / a0; b.b1 = -(1 + c) / a0; b.b2 = (1 + c) / 2 / a0
        b.a1 = -2 * c / a0; b.a2 = (1 - alpha) / a0
        return b
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// A 16-bit PCM mono WAV file, written by hand.
public enum WavWriter {
    public static func data(samples: [Float], sampleRate: Int = BarkSynth.defaultSampleRate) -> Data {
        var d = Data()
        let bytes = samples.count * 2
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples {
            let c = s.isFinite ? max(-1, min(1, s)) : 0
            var x = Int16(max(-32_767, min(32_767, (Double(c) * 32_767).rounded()))).littleEndian
            d.append(Data(bytes: &x, count: 2))
        }
        return d
    }
}

/// The finish beat: when a fix is done, Shep says "Done." to VoiceOver, puts its ears up, hops and barks once (`BarkSound`), holds the
/// happy pose for a moment, then goes home. This is only the timeline and the hop's arc; the app carries the steps out.
public enum FinishAction: String, Equatable, Sendable {
    /// The finish pose (ears up, eyes wide).
    case earsUp
    /// VoiceOver announcement "Done." (a no-op without VoiceOver).
    case announceDone
    /// A little hop (never under Reduce Motion).
    case hop
    /// The woof (only when "Bark when done" is on).
    case woof
    /// Trot home and sleep.
    case goHome
}

public struct FinishStep: Equatable, Sendable {
    public var at: TimeInterval
    public var action: FinishAction
}

public enum FinishBeat {
    public static let announcement = "Done."
    /// The woof and the hop start together this long after the ears go up.
    public static let woofDelay: TimeInterval = 0.2
    /// With VoiceOver running, the woof waits for VoiceOver to finish, but never longer than this: after "Done." has been
    /// said (`doneSpokenSeconds`) with a clear gap, since VoiceOver lowers other sound while it speaks.
    public static let voiceOverTimeout: TimeInterval = 2.2
    public static let hopSeconds: TimeInterval = 0.42
    public static let hopHeight = 9.0   // points
    /// Ears stay up this long after the woof before Shep goes home.
    public static let holdAfterWoof: TimeInterval = 0.4

    /// With Shep's own spoken reply still going ("Done."), the woof waits for it to end, but never longer than this.
    public static let replyTimeout: TimeInterval = 2.5

    /// When the woof starts: `woofDelay` normally. With VoiceOver running, when VoiceOver finished (`voiceOverFinishedAt`, seconds
    /// from the start), or the timeout when it has not said so. Likewise while Shep's spoken reply is going (`replySpeaking`; it is
    /// never spoken with VoiceOver on), with `replyFinishedAt` and `replyTimeout`. Never before `woofDelay`.
    public static func woofTime(voiceOverRunning: Bool, voiceOverFinishedAt: TimeInterval? = nil,
                                replySpeaking: Bool = false, replyFinishedAt: TimeInterval? = nil) -> TimeInterval {
        if voiceOverRunning {
            let done = voiceOverFinishedAt ?? voiceOverTimeout
            return max(woofDelay, min(done, voiceOverTimeout))
        }
        if replySpeaking {
            let done = replyFinishedAt ?? replyTimeout
            return max(woofDelay, min(done, replyTimeout))
        }
        return woofDelay
    }

    /// The steps, in order. Reduce Motion: no hop, ear pose and sound only.
    public static func steps(reduceMotion: Bool, barkEnabled: Bool, voiceOverRunning: Bool, voiceOverFinishedAt: TimeInterval? = nil,
                             replySpeaking: Bool = false, replyFinishedAt: TimeInterval? = nil) -> [FinishStep] {
        var s: [FinishStep] = [FinishStep(at: 0, action: .earsUp), FinishStep(at: 0, action: .announceDone)]
        let bark = woofTime(voiceOverRunning: voiceOverRunning, voiceOverFinishedAt: voiceOverFinishedAt,
                            replySpeaking: replySpeaking, replyFinishedAt: replyFinishedAt)
        if !reduceMotion { s.append(FinishStep(at: bark, action: .hop)) }
        if barkEnabled { s.append(FinishStep(at: bark, action: .woof)) }
        let sound = barkEnabled ? BarkSound.duration : 0
        let motion = reduceMotion ? sound : max(hopSeconds, sound)   // the longer of the hop and the bark
        s.append(FinishStep(at: bark + motion + holdAfterWoof, action: .goHome))
        return s
    }

    /// Height of the hop at `t` seconds into it: a parabola, 0 at both ends, `hopHeight` in the middle; 0 outside.
    public static func hopOffset(at t: TimeInterval) -> Double {
        guard t > 0, t < hopSeconds else { return 0 }
        let u = t / hopSeconds
        return hopHeight * 4 * u * (1 - u)
    }
}
