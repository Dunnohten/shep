import Foundation

// Written for Shep. The sound itself is not: see NOTICE.

/// The finish bark: one real dog bark, "Single Dog Bark" by kwahmah_02 (Freesound sound 277058, CC0 1.0, public domain
/// dedication). Taken from Freesound's preview, cut to its first 0.26 s, high-passed at 120 Hz, faded out over the last 60 ms,
/// peak-normalized to -1 dBFS, and stored here as a 22.05 kHz mono 16-bit WAV (sha256 of the WAV in NOTICE). No other sound file
/// is in the app. The app plays it through AVAudioEngine to the system output, so the system volume applies.
public enum BarkSound {
    public static let sampleRate = 22_050
    /// The loudest the bark ever plays, at volume 1 (about -3 dBFS): a bark, not an alarm.
    public static let maxPeak: Float = 0.7

    /// The WAV file, decoded once.
    public static let wav: Data = Data(base64Encoded: encoded.joined()) ?? Data()

    /// Mono samples in -1...1 from the stored WAV (16-bit PCM, little-endian), or [] when it cannot be read.
    public static let unitSamples: [Float] = decodePCM16(wav)

    /// Length of the bark in seconds.
    public static var duration: TimeInterval { Double(unitSamples.count) / Double(sampleRate) }

    /// The samples scaled for `volume` (clamped to 0...1): the peak is `maxPeak * volume`. Volume 0 gives silence.
    public static func samples(volume: Double) -> [Float] {
        let v = volume.isFinite ? Float(min(1, max(0, volume))) : 0
        let peak = unitSamples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return [] }
        let scale = maxPeak * v / peak
        return unitSamples.map { $0 * scale }
    }

    /// The `data` chunk of a mono 16-bit PCM WAV as floats; [] for anything else.
    public static func decodePCM16(_ d: Data) -> [Float] {
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { return [] }
        var i = 12
        var mono16 = false
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            let body = i + 8
            guard size >= 0, body + size <= b.count else { return [] }
            if id == "fmt " {
                guard size >= 16 else { return [] }
                mono16 = u16(body) == 1 && u16(body + 2) == 1 && u16(body + 14) == 16
            } else if id == "data" {
                guard mono16 else { return [] }
                var out = [Float]()
                out.reserveCapacity(size / 2)
                var j = body
                while j + 1 < body + size {
                    out.append(Float(Int16(bitPattern: UInt16(b[j]) | UInt16(b[j + 1]) << 8)) / 32_768)
                    j += 2
                }
                return out
            }
            i = body + size + (size & 1)
        }
        return []
    }

    private static let encoded: [String] = [
        "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",
        "//////X/6f/o/+r/+P8GAAkAAQD+/wAABAADAAEABAAKAAcAAAAAAAcADAANAAcAAQD///3/+//4//X/9f/3//v///////z/+f/0//X/+v/7//z//f8AAAQA",
        "BgAGAAMAAQABAAAAAQAEAAIAAAD+//3/AgANABAACQD8//P/+f8CAA0ADAANAAwADQAWABYAEwAKAPv/9f/4//7/AAABAAYACQACAPj/7P/t//f//P/4//j/",
        "//8HAAkAAQD//wEABgAIAAIA//8CAAYACgALAAkABgADAAAA/f/9/wAAAAAAAP7//f/8//z/+//6//n/+//9////AAAAAAAAAQABAAAAAAAAAAAAAQABAAIA",
        "AwAEAAIAAAAAAP3//v/+//7///8AAAAAAAAAAAAA//8AAAAAAAAAAAAAAAAAAAAAAAD//wAAAAD///////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]
}
