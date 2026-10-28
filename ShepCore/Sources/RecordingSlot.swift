import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Written for Shep.

/// Why a claim or an exclusive create was refused. `reason` is one short sentence, for a `live: record refused:` line.
public struct RecordingSlotRefusal: Error, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public static let taken = RecordingSlotRefusal(reason: "the output path is taken")
}

public enum RecordingPublishResult: Equatable, Sendable {
    /// The clip is at the final path (published with link(), then our own clip name and working directory were removed).
    case published
    /// Published, but our working directory could not be removed; the text says where it is.
    case publishedLeavingWorkDirectory(String)
    /// Something is at the final path (or the link failed): nothing was overwritten or removed, our clip stays at `clipPath`.
    case keptInWorkDirectory(clipPath: String, why: String)
    /// The working directory is no longer the one this slot made: nothing was touched.
    case identityMismatch
    /// `clip.mov` is missing or is not a regular file: nothing was touched.
    case noClip
    /// `clip.mov` is not the file first seen (another regular file was renamed over it, or it has a second name): nothing was
    /// published, removed or changed; the text says where it was left.
    case clipReplaced(String)
    case alreadyFinished
    /// A discard was requested before the clip was linked: nothing was linked or removed (the caller discards).
    case discardRequested
}

/// What `requestDiscard()` found.
public enum RecordingDiscardRequest: Equatable, Sendable {
    /// Latched: this slot will never publish; the caller removes the clip with `discard()`.
    case latched
    /// The clip had already been linked to the final path before the request.
    case alreadyPublished
}

public enum RecordingDiscardResult: Equatable, Sendable {
    case removed
    /// The working directory is no longer the one this slot made: nothing was removed.
    case identityMismatch
    /// `clip.mov` is not the file first seen: it is preserved, the directory is kept, and the text says so
    /// (`the clip was replaced by another file; left in <workdir>`).
    case clipReplaced(String)
    /// Something of ours could not be removed (the text says what and where).
    case leftBehind(String)
    case alreadyFinished
}

/// The clip's own (st_dev, st_ino), as seen the first time through the held directory descriptor.
public struct RecordingClipIdentity: Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// A private exclusive recording slot. A recorder owns its output by IDENTITY, not because "the file was absent":
///
/// - `claim(finalPath:)` first judges the parent folder (`RecordingParentTrust`: resolved with realpath, owned by us, not group/other
///   writable, ancestors owned by us or root and not writable by others unless sticky) and refuses `the output folder is not private to
///   you (...)` otherwise. It refuses `the output path is taken` when anything at all is at the final path, a dangling symlink included.
///   Otherwise it makes a private working directory next to it (`mkdirat`, mode 0700, name `.shep-rec-<pid>-<16 hex>`; EEXIST
///   retries with a new name, up to 5 times), opens it with `O_DIRECTORY | O_NOFOLLOW` and remembers its (st_dev, st_ino) and the
///   descriptor. The recorder writes ONLY to `clipPath` (`<resolved parent>/<workdir>/clip.mov`).
/// - ScreenCaptureKit opens that PATH, not the descriptor, so the descriptor cannot make the write atomic. The trust check above is what
///   keeps other users out of the path; `pathIsBound()` (the path still leads to the held directory and to the clip first seen) is run
///   before the recorder starts, after the first clip is seen, periodically, and before publishing, and is the detection for the rest.
/// - `observeClip()` records the clip's own identity the first time it is seen THROUGH the directory descriptor (`fstatat` with
///   `AT_SYMLINK_NOFOLLOW`: a regular file, owned by us, one name) and pins that inode with a read-only descriptor so it cannot be recycled.
///   After that, a different file at `clip.mov` (a regular file renamed over it, a second hard link) is not ours.
/// - `publish()` links the clip to the final path with `linkat` only from the identity-checked clip (EEXIST, a dangling symlink included,
///   keeps the clip in the working directory), then removes only our own `clip.mov` (`unlinkat` on the held directory descriptor) and our
///   working directory, which must be empty and still the one we hold.
/// - `discard()` does the same checked removal of our clip and directory, and nothing else. A clip that is not the one first seen is
///   PRESERVED with its directory.
/// - Nothing here ever unlinks the final path, nothing removes recursively, and nothing follows a symlink below the parent directory.
///   The parent is held by descriptor from the claim on.
///
/// Residual races, named: between the identity check and the `unlinkat`/`linkat` that follows it (names are looked up again), and
/// between a path check and ScreenCaptureKit's open. A process running as the same user is out of scope.
/// Claims are exclusive within a process (a registry of parent-directory identity plus name); between processes the race is decided at
/// `publish()`, where `linkat` fails with EEXIST. A working directory left behind by a crash is not removed automatically.
public final class RecordingSlot: @unchecked Sendable {
    public static let clipName = "clip.mov"
    public static let directoryPrefix = ".shep-rec-"
    public static let maxAttempts = 5

    public let finalPath: String
    public let workDirectoryPath: String
    public var clipPath: String { workDirectoryPath + "/" + RecordingSlot.clipName }

    /// Test seams: run right before the slot looks at the file system in `publish()` / `discard()`.
    public var beforePublish: (() -> Void)?
    public var beforeDiscard: (() -> Void)?

    private let lock = NSLock()
    private var parentFD: Int32
    private var workFD: Int32
    /// A read-only descriptor on the clip first seen; it keeps that inode alive, so its number cannot be reused by a replacement.
    private var clipFD: Int32 = -1
    private var recordedClip: RecordingClipIdentity?
    private let finalName: String
    private let workName: String
    private let workDevice: dev_t
    private let workInode: ino_t
    private let registryKey: String
    private var finished = false
    /// A discard was requested: `publish()` never links after this. Under `lock`.
    private var discardRequested = false
    /// The clip has been linked to the final path (set under `lock` right after the `linkat` that made it). Under `lock`.
    private var published = false

    private static let registryLock = NSLock()
    private static var held = Set<String>()

    private init(finalPath: String, workDirectoryPath: String, parentFD: Int32, workFD: Int32, finalName: String, workName: String,
                 workDevice: dev_t, workInode: ino_t, registryKey: String) {
        self.finalPath = finalPath; self.workDirectoryPath = workDirectoryPath; self.parentFD = parentFD; self.workFD = workFD
        self.finalName = finalName; self.workName = workName; self.workDevice = workDevice; self.workInode = workInode
        self.registryKey = registryKey
    }

    deinit {
        if clipFD >= 0 { close(clipFD) }
        if workFD >= 0 { close(workFD) }
        if parentFD >= 0 { close(parentFD) }
        if !finished { RecordingSlot.release(registryKey) }
    }

    // MARK: claim

    public static func randomSuffix() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt64.random(in: 0...UInt64.max, using: &generator)
        let text = String(value, radix: 16)
        return String(repeating: "0", count: 16 - text.count) + text
    }

    public static func claim(finalPath: String, suffix: () -> String = { RecordingSlot.randomSuffix() },
                             aclReader: RecordingACLReading = RecordingRealACLReader()) -> Result<RecordingSlot, RecordingSlotRefusal> {
        guard finalPath.hasPrefix("/"), !finalPath.contains("\u{0}"), let slash = finalPath.lastIndex(of: "/") else {
            return .failure(RecordingSlotRefusal(reason: "the output path is not an absolute file path"))
        }
        let name = String(finalPath[finalPath.index(after: slash)...])
        var requestedParent = String(finalPath[finalPath.startIndex..<slash])
        if requestedParent.isEmpty { requestedParent = "/" }
        guard !name.isEmpty, name != ".", name != ".." else {
            return .failure(RecordingSlotRefusal(reason: "the output path is not an absolute file path"))
        }
        // The trust boundary: the parent is resolved, judged, and from here on only the RESOLVED path is used (opened, and handed to the recorder).
        let parent: String
        switch RecordingParentTrust.checkReal(parent: requestedParent, acl: aclReader) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let resolved): parent = resolved
        }
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard pfd >= 0 else {
            return .failure(RecordingSlotRefusal(reason: "the output directory cannot be opened: \(errnoText())"))
        }
        var parentStat = stat()
        guard fstat(pfd, &parentStat) == 0 else {
            close(pfd)
            return .failure(RecordingSlotRefusal(reason: "the output directory cannot be inspected: \(errnoText())"))
        }
        // The descriptor must be the folder that was judged (a swap between the check and the open is refused), and still private.
        var judged = stat()
        guard lstat(parent, &judged) == 0, judged.st_dev == parentStat.st_dev, judged.st_ino == parentStat.st_ino,
              parentStat.st_uid == geteuid(), (parentStat.st_mode & 0o022) == 0 else {
            close(pfd)
            return .failure(RecordingSlotRefusal(reason: "the output folder is not private to you (it changed while it was opened)"))
        }
        let key = "\(parentStat.st_dev):\(parentStat.st_ino)/\(name)"
        guard acquire(key) else {
            close(pfd)
            return .failure(.taken)
        }
        func fail(_ reason: String) -> Result<RecordingSlot, RecordingSlotRefusal> {
            close(pfd)
            release(key)
            return .failure(RecordingSlotRefusal(reason: reason))
        }
        // Anything at the final path, whatever it is and wherever it points, is somebody else's.
        var existing = stat()
        if fstatat(pfd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            close(pfd)
            release(key)
            return .failure(.taken)
        }
        if errno != ENOENT { return fail("the output path cannot be inspected: \(errnoText())") }

        var workName = ""
        var made = false
        for _ in 0..<maxAttempts {
            let candidate = directoryPrefix + "\(getpid())-" + suffix()
            if mkdirat(pfd, candidate, 0o700) == 0 { workName = candidate; made = true; break }
            if errno == EEXIST { continue }
            return fail("could not create a private working directory: \(errnoText())")
        }
        guard made else { return fail("could not create a private working directory: every name was taken") }
        let wfd = openat(pfd, workName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard wfd >= 0 else { return fail("could not open the private working directory \(workName): \(errnoText())") }
        var workStat = stat()
        guard fstat(wfd, &workStat) == 0, isDirectory(workStat), workStat.st_uid == geteuid() else {
            close(wfd)
            return fail("the private working directory \(workName) is not ours")
        }
        // The fresh directory can inherit an ACL from the parent: judge it like the folders above it. If it lets another user in, remove
        // OUR directory (identity re-checked through the parent descriptor; AT_REMOVEDIR only removes an empty directory) and refuse.
        let workPath = parent + (parent == "/" ? "" : "/") + workName
        if let problem = RecordingACLRule.problem(path: workPath, effectiveUID: UInt32(geteuid()), reader: aclReader) {
            var now = stat()
            if fstatat(pfd, workName, &now, AT_SYMLINK_NOFOLLOW) == 0, isDirectory(now), now.st_dev == workStat.st_dev, now.st_ino == workStat.st_ino {
                _ = unlinkat(pfd, workName, AT_REMOVEDIR)
            }
            close(wfd)
            return fail("the output folder is not private to you (the working directory: \(problem))")
        }
        let slot = RecordingSlot(finalPath: finalPath, workDirectoryPath: workPath, parentFD: pfd, workFD: wfd,
                                 finalName: name, workName: workName, workDevice: workStat.st_dev, workInode: workStat.st_ino, registryKey: key)
        return .success(slot)
    }

    // MARK: clip identity

    /// What the held directory shows at `clip.mov`.
    private enum ClipLook {
        case absent
        /// A regular file, owned by us, with one name, and (if an identity was recorded) the one first seen.
        case ours(RecordingClipIdentity)
        /// Something that is not a regular file (a link, a directory, a device).
        case notRegular
        /// A regular file that is not ours to treat as the clip: another owner, a second name, or not the one first seen.
        case foreign(String)
    }

    private static func identity(of st: stat) -> RecordingClipIdentity {
        RecordingClipIdentity(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino))
    }

    /// Looks at `clip.mov` through the held directory descriptor; the first acceptable sight records the identity and pins the inode.
    /// Call with the lock held.
    private func lookAtClip() -> ClipLook {
        var st = stat()
        if fstatat(workFD, RecordingSlot.clipName, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? .absent : .foreign("it cannot be inspected: \(RecordingSlot.errnoText())")
        }
        guard RecordingSlot.isRegular(st) else { return .notRegular }
        guard st.st_uid == geteuid() else { return .foreign("it is owned by someone else") }
        guard st.st_nlink == 1 else { return .foreign("it has more than one name") }
        let seen = RecordingSlot.identity(of: st)
        if let recorded = recordedClip {
            return recorded == seen ? .ours(seen) : .foreign("it is not the file first seen")
        }
        // First sight: hold the very inode (no following, no blocking), and confirm that what was opened is what was looked at.
        let fd = openat(workFD, RecordingSlot.clipName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .foreign("it cannot be opened: \(RecordingSlot.errnoText())") }
        var opened = stat()
        guard fstat(fd, &opened) == 0, RecordingSlot.isRegular(opened), RecordingSlot.identity(of: opened) == seen, opened.st_nlink == 1 else {
            close(fd)
            return .foreign("it changed while it was opened")
        }
        clipFD = fd
        recordedClip = seen
        return .ours(seen)
    }

    /// The clip's identity as first recorded; nil until `observeClip()` has seen it.
    public var clipIdentity: RecordingClipIdentity? {
        lock.lock(); defer { lock.unlock() }
        return recordedClip
    }

    /// Looks at `clip.mov` through the held directory descriptor. `.success(nil)`: not there yet (no error). `.success(identity)`: a regular
    /// file with one name, owned by us; the first such sight is recorded and pinned, and later calls must see the same file.
    /// `.failure`: something else is there, or the recorded clip was replaced or removed.
    public func observeClip() -> Result<RecordingClipIdentity?, RecordingSlotRefusal> {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return .failure(RecordingSlotRefusal(reason: "the recording slot has ended")) }
        switch lookAtClip() {
        case .absent:
            if recordedClip != nil { return .failure(RecordingSlotRefusal(reason: "the clip is no longer in the private folder")) }
            return .success(nil)
        case .ours(let seen):
            return .success(seen)
        case .notRegular:
            return .failure(RecordingSlotRefusal(reason: "the clip was replaced by something that is not a regular file"))
        case .foreign(let why):
            return .failure(RecordingSlotRefusal(reason: "the clip was replaced by another file (\(why))"))
        }
    }

    /// The size of the clip first seen (read from the pinned inode, not from a name), or nil when no clip has been seen.
    public func clipSize() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        if clipFD < 0 { _ = lookAtClip() }
        guard clipFD >= 0 else { return nil }
        var st = stat()
        guard fstat(clipFD, &st) == 0 else { return nil }
        return Int(st.st_size)
    }

    /// The pathname the recorder will open still leads to what this slot holds: the working directory name is a directory (not a link)
    /// with the held device and inode, and `clip.mov` seen through the path is the same file as through the descriptor (and, once
    /// recorded, the one first seen). False once the slot has ended. Run it before the recorder starts, after the first clip is seen,
    /// periodically, and before publishing.
    public func pathIsBound() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, workFD >= 0 else { return false }
        return pathIsBoundLocked()
    }

    private func pathIsBoundLocked() -> Bool {
        var heldStat = stat()
        guard fstat(workFD, &heldStat) == 0, RecordingSlot.isDirectory(heldStat), heldStat.st_dev == workDevice, heldStat.st_ino == workInode else { return false }
        guard workDirectoryIsOurs() else { return false }
        var byPath = stat()
        guard lstat(workDirectoryPath, &byPath) == 0, RecordingSlot.isDirectory(byPath), byPath.st_dev == workDevice, byPath.st_ino == workInode else { return false }
        var viaDescriptor = stat()
        var viaPath = stat()
        let descriptorSees = fstatat(workFD, RecordingSlot.clipName, &viaDescriptor, AT_SYMLINK_NOFOLLOW) == 0
        let pathSees = lstat(clipPath, &viaPath) == 0
        if !descriptorSees && !pathSees { return recordedClip == nil }
        guard descriptorSees, pathSees, RecordingSlot.isRegular(viaDescriptor), RecordingSlot.isRegular(viaPath) else { return false }
        let seen = RecordingSlot.identity(of: viaDescriptor)
        guard RecordingSlot.identity(of: viaPath) == seen else { return false }
        if let recorded = recordedClip { return recorded == seen }
        return true
    }

    // MARK: publish

    public func publish() -> RecordingPublishResult {
        beforePublish?()
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return .alreadyFinished }
        guard workDirectoryIsOurs() else { return .identityMismatch }
        let clip: RecordingClipIdentity
        switch lookAtClip() {
        case .absent:
            return .noClip
        case .notRegular:
            if recordedClip == nil { return .noClip }
            let text = replacedText()
            end()
            return .clipReplaced(text)
        case .foreign:
            let text = replacedText()
            end()
            return .clipReplaced(text)
        case .ours(let seen):
            clip = seen
        }
        guard pathIsBoundLocked() else { return .identityMismatch }
        // The last check before the link, under the same lock `requestDiscard()` takes: a discard that was requested while the keep was
        // finalising wins. Nothing is linked, removed or ended here; the caller discards.
        if discardRequested { return .discardRequested }
        if linkat(workFD, RecordingSlot.clipName, parentFD, finalName, 0) != 0 {
            let why = errno == EEXIST ? RecordingSlotRefusal.taken.reason : RecordingSlot.errnoText()
            end()
            return .keptInWorkDirectory(clipPath: clipPath, why: why)
        }
        published = true
        var linked = stat()
        let isOurs = fstatat(parentFD, finalName, &linked, AT_SYMLINK_NOFOLLOW) == 0 && RecordingSlot.isRegular(linked)
            && RecordingSlot.identity(of: linked) == clip
        guard isOurs else {
            // The name is not our clip any more: touch nothing.
            end()
            return .keptInWorkDirectory(clipPath: clipPath, why: "the published file could not be verified")
        }
        // The final file now has two names. Remove ours (through the held descriptor, and only while it is still the file we linked), then our directory.
        var ours = stat()
        guard fstatat(workFD, RecordingSlot.clipName, &ours, AT_SYMLINK_NOFOLLOW) == 0, RecordingSlot.isRegular(ours),
              RecordingSlot.identity(of: ours) == clip else {
            let leftover = "the clip name in \(workDirectoryPath) is no longer the file I published, so I left it"
            end()
            return .publishedLeavingWorkDirectory(leftover)
        }
        if unlinkat(workFD, RecordingSlot.clipName, 0) != 0 {
            let leftover = "could not remove \(clipPath): \(RecordingSlot.errnoText())"
            end()
            return .publishedLeavingWorkDirectory(leftover)
        }
        let leftover = removeWorkDirectory()
        end()
        if let leftover = leftover { return .publishedLeavingWorkDirectory(leftover) }
        return .published
    }

    // MARK: discard

    /// Latches the intent to discard, under the slot's lock, the same lock `publish()` holds from its last check through the `linkat`.
    /// Either this call comes first (`.latched`: `publish()` then links nothing and returns `.discardRequested`), or the link was
    /// already made (`.alreadyPublished`: the clip is at the final path and stays). A slot that was discarded or ended before any link
    /// is `.latched` too: it will never publish. The latch never goes back.
    public func requestDiscard() -> RecordingDiscardRequest {
        lock.lock(); defer { lock.unlock() }
        if published { return .alreadyPublished }
        discardRequested = true
        return .latched
    }

    /// True once `requestDiscard()` latched before any publish.
    public var discardWasRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return discardRequested
    }

    public func discard() -> RecordingDiscardResult {
        beforeDiscard?()
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return .alreadyFinished }
        guard workDirectoryIsOurs() else { return .identityMismatch }
        switch lookAtClip() {
        case .absent:
            break
        case .notRegular:
            let text = recordedClip == nil ? "\(clipPath) is not a regular file, so I left it" : replacedText()
            let replaced = recordedClip != nil
            end()
            return replaced ? .clipReplaced(text) : .leftBehind(text)
        case .foreign:
            let text = replacedText()
            end()
            return .clipReplaced(text)
        case .ours:
            if unlinkat(workFD, RecordingSlot.clipName, 0) != 0 {
                let why = "could not remove \(clipPath): \(RecordingSlot.errnoText())"
                end()
                return .leftBehind(why)
            }
        }
        let leftover = removeWorkDirectory()
        end()
        if let leftover = leftover { return .leftBehind(leftover) }
        return .removed
    }

    // MARK: identity

    private func replacedText() -> String {
        "the clip was replaced by another file; left in \(workDirectoryPath)"
    }

    /// The name still leads to the directory this slot made: a directory (not a link) with the remembered device and inode.
    private func workDirectoryIsOurs() -> Bool {
        var st = stat()
        guard fstatat(parentFD, workName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return RecordingSlot.isDirectory(st) && st.st_dev == workDevice && st.st_ino == workInode
    }

    /// Removes our working directory name after re-checking its identity. `AT_REMOVEDIR` only removes an EMPTY directory, so a
    /// directory that holds anything else is left as it is (nothing is ever removed recursively). nil on success, else what was left.
    private func removeWorkDirectory() -> String? {
        guard workDirectoryIsOurs() else { return "the working directory \(workDirectoryPath) is no longer the one I made, so I left it" }
        if unlinkat(parentFD, workName, AT_REMOVEDIR) != 0 {
            if errno == ENOTEMPTY || errno == EEXIST {
                return "the working directory \(workDirectoryPath) is not empty, so I left it"
            }
            return "could not remove the working directory \(workDirectoryPath): \(RecordingSlot.errnoText())"
        }
        return nil
    }

    /// Terminal: closes the descriptors and frees the path for a new claim. Call with the lock held.
    private func end() {
        finished = true
        if clipFD >= 0 { close(clipFD); clipFD = -1 }
        if workFD >= 0 { close(workFD); workFD = -1 }
        if parentFD >= 0 { close(parentFD); parentFD = -1 }
        RecordingSlot.release(registryKey)
    }

    // MARK: helpers

    private static func acquire(_ key: String) -> Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return held.insert(key).inserted
    }

    private static func release(_ key: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        held.remove(key)
    }

    static func isDirectory(_ st: stat) -> Bool { (st.st_mode & 0o170000) == 0o040000 }
    static func isRegular(_ st: stat) -> Bool { (st.st_mode & 0o170000) == 0o100000 }

    static func errnoText() -> String { String(cString: strerror(errno)) }
}

/// `O_CREAT | O_EXCL | O_NOFOLLOW`, mode 0600: creates a file only if nothing, a dangling symlink included, is at the path.
/// The one exclusive-create primitive (the live status file uses it).
public enum ExclusiveFile {
    /// The open descriptor (write only, append), or the refusal. The caller closes it.
    public static func create(path: String) -> Result<Int32, RecordingSlotRefusal> {
        guard path.hasPrefix("/"), !path.contains("\u{0}"), !path.hasSuffix("/") else {
            return .failure(RecordingSlotRefusal(reason: "the path is not an absolute file path"))
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND, 0o600)
        if fd >= 0 { return .success(fd) }
        if errno == EEXIST { return .failure(RecordingSlotRefusal(reason: "the file already exists")) }
        return .failure(RecordingSlotRefusal(reason: "could not create the file: \(RecordingSlot.errnoText())"))
    }
}
