import Foundation
import ShepCore

// Written for Shep.

/// The files of one `--live-debug-dir` run: `<dir>/<yyyyMMdd-HHmmss>/` with `input.png`, `ax-controls.txt`, `trace.txt` and
/// `request.txt`. Opt-in only: nothing here runs unless the flag was given. Folders are mode 0700 and files 0600. A directory inside
/// a git checkout (the app's own or any other) or one that cannot be written is refused with a `live: debug dir refused:` line.
/// A dump holds a screenshot of the target window: it stays outside the repository and outside version control.
final class LiveDebugDump: LiveDebugSink {
    let directory: URL
    private let log: (String) -> Void

    private init(directory: URL, log: @escaping (String) -> Void) {
        self.directory = directory
        self.log = log
    }

    /// Checks `directory` (symlinks resolved first) and makes this run's folder. nil, after logging why, when it is refused or
    /// cannot be made.
    static func begin(directory: String, now: Date, log: @escaping (String) -> Void) -> LiveDebugDump? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        guard let normal = LiveDebug.normalizedPath(directory, home: home) else {
            log(LiveLog.debugDirRefused("the path must be absolute (or start with ~/)"))
            return nil
        }
        let resolved = resolvedPath(normal)
        let hasGit: (String) -> Bool = { path in fm.fileExists(atPath: path + "/.git") }
        let bundle = resolvedPath(Bundle.main.bundlePath)
        // Both spellings are judged: the path as typed and where it really points.
        for candidate in [normal, resolved] {
            if let why = LiveDebug.refusal(path: candidate, home: home, appBundlePath: bundle, hasGit: hasGit) {
                log(LiveLog.debugDirRefused(why))
                return nil
            }
        }
        let root = URL(fileURLWithPath: resolved, isDirectory: true)
        do {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    log(LiveLog.debugDirRefused("that path exists and is not a directory"))
                    return nil
                }
            } else {
                try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            }
            guard fm.isWritableFile(atPath: root.path) else {
                log(LiveLog.debugDirRefused("that directory is not writable"))
                return nil
            }
            let zone = TimeZone(identifier: "America/Chicago") ?? TimeZone.current
            let name = LiveDebug.runDirectoryName(date: now, timeZone: zone)
            var run = root.appendingPathComponent(name, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: run.path) {
                run = root.appendingPathComponent(name + "-" + String(n), isDirectory: true)
                n += 1
            }
            try fm.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
            return LiveDebugDump(directory: run, log: log)
        } catch {
            log(LiveLog.debugDirRefused("could not create it: " + error.localizedDescription))
            return nil
        }
    }

    /// Symlinks resolved in the part of the path that exists; the rest is appended as typed.
    private static func resolvedPath(_ path: String) -> String {
        let fm = FileManager.default
        var existing = path
        var rest: [String] = []
        while existing != "/", !fm.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            rest.insert(url.lastPathComponent, at: 0)
            existing = url.deletingLastPathComponent().path
        }
        var base = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for piece in rest { base += (base == "/" ? "" : "/") + piece }
        return base
    }

    func write(_ name: String, _ data: Data) {
        let path = directory.appendingPathComponent(name).path
        if !FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) {
            log(LiveLog.debugDumpFailed("could not write " + name))
        }
    }

    func write(_ name: String, text: String) {
        write(name, Data(text.utf8))
    }

    func announce() {
        log(LiveLog.debugDumpWritten(directory.path))
    }
}
