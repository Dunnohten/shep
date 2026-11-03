import Foundation

// Written for Shep.

/// The labels Shep added, kept in one JSON file: `~/Library/Application Support/Shep/label-overlay.json`, versioned, written atomically.
/// Keyed by the app's bundle id and the element fingerprint. The only ways to change it take an approval token that only the approval
/// flow can build (`ApprovedLabels`, `ApprovedClear`).
public final class LabelOverlayStore: @unchecked Sendable {
    public static let currentVersion = 3
    /// Versions this build can read. Version 1 entries have no anchor and version 2 anchors name no window: they load, and are shown only
    /// in an app with exactly one standard window (a version 1 entry also only when the app named the control).
    static let readableVersions: Set<Int> = [1, 2, 3]

    public enum LoadState: Equatable, Sendable {
        /// No file yet.
        case fresh
        case loaded
        /// The file exists and could not be read (bad JSON, or a version this build does not know). Treated as empty; the file is left
        /// alone until a write, which first keeps an exact copy.
        case corrupt(String)
    }

    public struct ApplyResult: Equatable, Sendable {
        public var stored: Int
        /// Where the unreadable file was copied before it was replaced, if there was one.
        public var corruptBackup: URL?
    }

    struct Entry: Codable, Equatable {
        var bundleID: String
        var fingerprint: String
        var label: String
        var role: String
        var updated: Date
        /// nil in a version 1 file.
        var anchor: LabelAnchor?
    }

    struct FileShape: Codable {
        var version: Int
        var entries: [Entry]
    }

    public let fileURL: URL
    public private(set) var loadState: LoadState = .fresh
    private var entries: [Entry] = []
    private let lock = NSLock()
    private let now: () -> Date
    private var corruptBackupDone = false

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    public static func defaultFileURL(home: String) -> URL {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return URL(fileURLWithPath: h + "/Library/Application Support/Shep/label-overlay.json")
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loadState = .fresh; return }
        guard let data = try? Data(contentsOf: fileURL) else { loadState = .corrupt("the file could not be read"); return }
        do {
            let shape = try Self.decoder().decode(FileShape.self, from: data)
            guard Self.readableVersions.contains(shape.version) else { loadState = .corrupt("version \(shape.version) is not known to this build"); return }
            // An entry whose label would not pass today's checks is ignored, not trusted.
            entries = shape.entries.filter { !$0.bundleID.isEmpty && !$0.fingerprint.isEmpty && LabelSanitizer.clean($0.label) == $0.label }
            loadState = .loaded
        } catch {
            loadState = .corrupt("the file is not valid JSON")
        }
    }

    // MARK: reading

    public func label(bundleID: String, fingerprint: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.bundleID == bundleID && $0.fingerprint == fingerprint }?.label
    }

    /// The labels for one app, with the anchors they were approved against, for naming its controls.
    public func storedLabels(bundleID: String) -> [StoredLabel] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.bundleID == bundleID }.map { StoredLabel(fingerprint: $0.fingerprint, label: $0.label, anchor: $0.anchor) }
    }

    public func count(bundleID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.bundleID == bundleID }.count
    }

    // MARK: writing (approval tokens only)

    @discardableResult
    public func apply(_ approved: ApprovedLabels) throws -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        var next = entries
        let stamp = now()
        for item in approved.items {
            // One label per control per kind of window: the same layout in another kind of window keeps its own.
            next.removeAll { e in e.bundleID == approved.bundleID && e.fingerprint == item.fingerprint && e.anchor?.window == item.anchor.window }
            next.append(Entry(bundleID: approved.bundleID, fingerprint: item.fingerprint, label: item.label, role: item.role, updated: stamp,
                              anchor: item.anchor.isEmpty ? nil : item.anchor))
        }
        let backup = try write(next)
        entries = next
        loadState = .loaded
        return ApplyResult(stored: approved.items.count, corruptBackup: backup)
    }

    /// Removes every label for the app and returns how many there were. Only the store's own entries: no other file is touched.
    @discardableResult
    public func clear(_ approved: ApprovedClear) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = entries.filter { $0.bundleID != approved.bundleID }
        let removed = entries.count - next.count
        guard removed > 0 else { return 0 }
        _ = try write(next)
        entries = next
        return removed
    }

    /// Atomic write (a temporary file in the same folder, then a rename). A file that could not be read is copied aside first, once.
    private func write(_ next: [Entry]) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if case .corrupt = loadState, !corruptBackupDone, fm.fileExists(atPath: fileURL.path) {
            let stamp = Int(now().timeIntervalSince1970)
            let target = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".unreadable-\(stamp)")
            try fm.copyItem(at: fileURL, to: target)
            backup = target
        }
        let data = try Self.encoder().encode(FileShape(version: Self.currentVersion, entries: next))
        try data.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        if backup != nil { corruptBackupDone = true }
        return backup
    }
}
