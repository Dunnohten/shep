import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Written for Shep.

/// What `lstat` says about one path component: the owner and the mode (type bits included). Injected in unit tests.
public struct RecordingPathStat: Equatable, Sendable {
    public var uid: UInt32
    public var mode: UInt32

    public init(uid: UInt32, mode: UInt32) {
        self.uid = uid
        self.mode = mode
    }

    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isSticky: Bool { (mode & 0o1000) != 0 }
    /// Writable by the group or by others.
    public var isWritableByOthers: Bool { (mode & 0o022) != 0 }
}

/// The trust boundary for the folder a recording is made in.
///
/// ScreenCaptureKit takes a path, not a descriptor, so a held directory descriptor cannot make the recorder's write atomic with it:
/// whoever can rename the private working directory (or an ancestor) and put a symlink at the old name redirects the pixels. What
/// excludes other users is the permissions of the folders the path goes through, so they are checked before anything is claimed:
///
/// - the output folder is resolved with `realpath` first, and the RESOLVED path is what is judged and what the recorder is given;
/// - the folder itself must be a real directory, owned by the effective uid, with neither the group-write nor the other-write bit
///   (`mode & 022 == 0`); a sticky bit does not help here;
/// - every ancestor up to `/` must be a real directory owned by the effective uid or by root, and either not group/other-writable or
///   sticky (`/tmp`, `/private/var/folders/..`: in a sticky directory another user cannot rename an entry they do not own).
///
/// - an extended ACL (macOS) can let ANOTHER user add, delete or rename entries, or change the mode, while the mode bits read 0700/0755:
///   every judged folder (the output folder, every ancestor, and the fresh work directory in `RecordingSlot.claim`) also passes
///   `RecordingACLRule`: an ALLOW entry with add_file / add_subdirectory / delete_child / delete / write data / append / write security /
///   change owner is acceptable only for the effective user; any other principal, an unresolvable one, or an unreadable ACL refuses.
///   Deny entries and benign allow entries (read, list, search, attributes, read security, sync) pass, so the home folder's
///   `group:everyone deny delete` does not refuse.
///
/// Out of scope, said plainly: a process running as the SAME user can do anything the person can (rename, replace, signal), and a sticky
/// parent does not stop a same-user rename. The per-clip identity checks in `RecordingSlot` detect and preserve, they do not prevent.
/// A refusal names only the failing component, never a path.
public enum RecordingParentTrust {
    private static func refusal(_ which: String) -> RecordingSlotRefusal {
        RecordingSlotRefusal(reason: "the output folder is not private to you (\(which))")
    }

    private static func componentName(_ path: String) -> String {
        if path == "/" { return "/" }
        if let slash = path.lastIndex(of: "/") { return String(path[path.index(after: slash)...]) }
        return path
    }

    /// nil when the (already resolved) folder is trusted, else the refusal. Pure: `lstat` answers for each path from `/` down.
    /// `acl` defaults to "no ACLs" only so mode-bit tests stay small; every real entry point passes the real reader.
    public static func evaluate(resolvedParent: String, effectiveUID: UInt32, lstat: (String) -> RecordingPathStat?,
                                acl: RecordingACLReading = RecordingNoACLReader()) -> RecordingSlotRefusal? {
        var chain: [String] = ["/"]
        var current = ""
        for part in resolvedParent.split(separator: "/") {
            current += "/" + String(part)
            chain.append(current)
        }
        guard let parentPath = chain.last else { return refusal("no folder") }

        guard let parent = lstat(parentPath) else { return refusal("the folder could not be inspected") }
        guard parent.isDirectory else { return refusal("not a real directory") }
        guard parent.uid == effectiveUID else { return refusal("not owned by you") }
        guard !parent.isWritableByOthers else { return refusal("writable by group or others") }
        if let problem = RecordingACLRule.problem(path: parentPath, effectiveUID: effectiveUID, reader: acl) {
            return refusal("\(componentName(parentPath)): \(problem)")
        }

        // The ancestors, nearest first.
        for path in chain.dropLast().reversed() {
            let name = componentName(path)
            guard let entry = lstat(path) else { return refusal("ancestor \(name) could not be inspected") }
            guard entry.isDirectory else { return refusal("ancestor \(name) is not a real directory") }
            guard entry.uid == effectiveUID || entry.uid == 0 else { return refusal("ancestor \(name) is not owned by you or root") }
            if entry.isWritableByOthers && !entry.isSticky { return refusal("ancestor \(name) is writable by others and not sticky") }
            if let problem = RecordingACLRule.problem(path: path, effectiveUID: effectiveUID, reader: acl) {
                return refusal("ancestor \(name): \(problem)")
            }
        }
        return nil
    }

    /// Resolves `parent` (links followed) and judges the result. The resolved path is returned on success: use it, not `parent`.
    public static func check(parent: String, effectiveUID: UInt32, resolve: (String) -> String?,
                             lstat: (String) -> RecordingPathStat?, acl: RecordingACLReading = RecordingNoACLReader()) -> Result<String, RecordingSlotRefusal> {
        guard let resolved = resolve(parent), resolved.hasPrefix("/") else {
            return .failure(RecordingSlotRefusal(reason: "the output directory cannot be opened"))
        }
        if let refused = evaluate(resolvedParent: resolved, effectiveUID: effectiveUID, lstat: lstat, acl: acl) { return .failure(refused) }
        return .success(resolved)
    }

    /// The real file system and the real effective uid.
    public static func checkReal(parent: String, acl: RecordingACLReading = RecordingRealACLReader()) -> Result<String, RecordingSlotRefusal> {
        check(parent: parent, effectiveUID: UInt32(geteuid()), resolve: realResolve, lstat: realLstat, acl: acl)
    }

    public static func realResolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func realLstat(_ path: String) -> RecordingPathStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return RecordingPathStat(uid: UInt32(st.st_uid), mode: UInt32(st.st_mode))
    }
}
