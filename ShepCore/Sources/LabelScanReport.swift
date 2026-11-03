import CoreGraphics
import Foundation

// Written for Shep.

/// `Shep --fix-screen-scan <pid|bundle>`: one JSON object per line for every control the label scan checked, then a summary line.
/// It reads and prints. It does not call a model and it writes nothing, so a live run can measure the flagging on a real window.
///
/// Totals in the summary: `flagged` (= `unlabeled`) is every control judged to have no real name; `falseFlags` is how many of those carry an
/// identifier the synthetic fixture uses for a control that is named or must be skipped ("l1", "s2": always 0 on any other app);
/// `offerable` is how many of the flagged could be labeled safely (told apart from every other control of their role); `skipped` is the
/// rest of the flagged ones (cannot be told apart; `duplicates` of them share a fingerprint with another); `ignored` counts controls the scan
/// passed over on purpose (disabled, hidden, window buttons); `labeled` counts controls that already have a name.
public enum LabelScanReport {
    /// The fixture's own naming: "l<n>" is a named control, "s<n>" must be skipped. Nothing else is a known false flag.
    static func isKnownNamedIdentifier(_ id: String) -> Bool {
        guard let first = id.first, first == "l" || first == "s", id.count > 1 else { return false }
        return id.dropFirst().allSatisfy { $0.isNumber }
    }

    public static func jsonLines(scan: LabelScan, bundleID: String, pid: Int32) -> [String] {
        var lines: [String] = []
        for e in scan.entries {
            lines.append(encode([
                "kind": "control", "path": e.pathID, "role": e.role, "subrole": e.subrole, "title": e.title, "description": e.descriptionText,
                "help": e.help, "identifier": e.identifier, "value": e.value, "fingerprint": e.fingerprint, "verdict": e.verdict,
                "flagged": e.flagged, "duplicate": e.duplicate, "offerable": e.offerable,
            ]))
        }
        let ignored = scan.entries.filter { $0.verdict.hasPrefix("skipped") }.count
        let labeled = scan.entries.filter { $0.verdict == "labeled" }.count
        let flagged = scan.entries.filter { $0.flagged }
        let falseFlags = flagged.filter { isKnownNamedIdentifier($0.identifier) }.count
        lines.append(encode([
            "kind": "summary", "bundle": bundleID, "pid": Int(pid), "checked": scan.entries.count,
            "flagged": flagged.count, "unlabeled": flagged.count, "falseFlags": falseFlags,
            "offerable": scan.candidates.count, "skipped": scan.unstableSkipped, "duplicates": scan.duplicatesSkipped,
            "labeled": labeled, "ignored": ignored, "partial": scan.partial,
        ]))
        return lines
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Optional crops of the flagged controls for the model: off unless SHEP_LABEL_IMAGES is set and Screen Recording is granted.
public enum LabelCrop {
    public static let padding: CGFloat = 4
    /// A crop longer than this on a side (in points) is a pane, not a control.
    public static let maxSide: CGFloat = 160
    /// What is actually sent: no crop is longer than this on a side, in pixels.
    public static let maxPixelSide = 256
    /// And all the crops of one request together are at most this many bytes.
    public static let maxTotalBytes = 1_500_000

    /// The size a crop is scaled to: its longest side at most `maxPixelSide`, the proportions kept, never enlarged. nil for an empty crop.
    public static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        if longest <= maxPixelSide { return (width, height) }
        let scale = Double(maxPixelSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Width and height from a PNG's header (the first 24 bytes), or nil when the bytes do not start like a PNG.
    public static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(24))
        guard b.count == 24, Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
        func word(_ at: Int) -> Int { (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3]) }
        return (word(16), word(20))
    }

    /// The crops of one request, in order, until one does not fit; it and every later one are dropped.
    public struct ByteBudget: Equatable, Sendable {
        public private(set) var used = 0
        public private(set) var closed = false
        public let limit: Int
        public init(limit: Int = LabelCrop.maxTotalBytes) { self.limit = limit }

        public mutating func admit(bytes: Int) -> Bool {
            guard !closed, bytes > 0, used + bytes <= limit else { closed = true; return false }
            used += bytes
            return true
        }
    }

    /// True when these bytes may go in a request: a PNG whose longest side is within `maxPixelSide`.
    public static func isSendable(_ png: Data) -> Bool {
        guard let size = pngSize(png), size.width > 0, size.height > 0 else { return false }
        return max(size.width, size.height) <= maxPixelSide
    }

    public static func enabled(environment: [String: String], screenRecordingGranted: Bool) -> Bool {
        guard screenRecordingGranted, let v = environment["SHEP_LABEL_IMAGES"]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(v)
    }

    /// The control's window-relative rectangle in pixels of the window screenshot, padded, clipped to the image. nil for a bad rectangle,
    /// one outside the image, or one too big to be a control.
    public static func pixelRect(relative r: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, scale.isFinite, scale > 0,
              r.width > 0, r.height > 0, r.width <= maxSide, r.height <= maxSide else { return nil }
        let padded = CGRect(x: (r.minX - padding) * scale, y: (r.minY - padding) * scale,
                            width: (r.width + 2 * padding) * scale, height: (r.height + 2 * padding) * scale)
        let clipped = padded.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}
