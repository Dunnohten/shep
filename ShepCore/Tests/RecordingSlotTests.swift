import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of ad80789 (R1): a recording owns its output by identity, in a private exclusive working
// directory, never by "the file was absent". Every test runs against the real file system in a fresh temporary directory; nothing
// here removes anything (the system clears the temporary directory).

/// Real-filesystem helpers for the slot tests.
enum SlotFS {
    static func freshDirectory(_ label: String) -> String {
        let path = NSTemporaryDirectory() + "shep-slot-\(label)-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
        // A recording parent must be private to the person (owned, no group or other write), whatever the umask is, and the slot works
        // with the resolved path (the temporary directory is behind a symlink on macOS): return that one.
        XCTAssertEqual(chmod(path, 0o700), 0, path)
        return resolved(path)
    }

    /// `realpath`, or the path itself when it cannot be resolved.
    static func resolved(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// True when anything, a dangling symlink included, is at `path`.
    static func lexists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & 0o170000) == 0o120000
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & 0o170000) == 0o040000
    }

    static func mode(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o777)
    }

    static func linkCount(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_nlink)
    }

    static func write(_ text: String, to path: String) {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: nil), path)
    }

    static func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    static func names(in directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }
}

/// Collects values from several threads.
final class SlotResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var wins: [RecordingSlot] = []
    private var refusals: [RecordingSlotRefusal] = []

    func add(_ result: Result<RecordingSlot, RecordingSlotRefusal>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let slot): wins.append(slot)
        case .failure(let refusal): refusals.append(refusal)
        }
    }

    var winCount: Int { lock.lock(); defer { lock.unlock() }; return wins.count }
    var refusalList: [RecordingSlotRefusal] { lock.lock(); defer { lock.unlock() }; return refusals }
}

final class RecordingSlotClaimTests: XCTestCase {
    func claim(_ path: String, suffix: (() -> String)? = nil) -> Result<RecordingSlot, RecordingSlotRefusal> {
        if let suffix = suffix { return RecordingSlot.claim(finalPath: path, suffix: suffix) }
        return RecordingSlot.claim(finalPath: path)
    }

    func assertTaken(_ result: Result<RecordingSlot, RecordingSlotRefusal>, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let refusal) = result else { return XCTFail("\(what) was claimed", file: file, line: line) }
        XCTAssertEqual(refusal.reason, "the output path is taken", what, file: file, line: line)
    }

    func testARegularFileAtTheFinalPathIsRefusedAndLeftByteIdentical() {
        let dir = SlotFS.freshDirectory("file")
        let final = dir + "/clip.mov"
        SlotFS.write("somebody else's movie", to: final)
        assertTaken(claim(final), "a regular file")
        XCTAssertEqual(SlotFS.read(final), "somebody else's movie")
        XCTAssertEqual(SlotFS.names(in: dir), ["clip.mov"], "a refused claim creates nothing, not even a working directory")
    }

    func testADirectoryAtTheFinalPathIsRefused() {
        let dir = SlotFS.freshDirectory("dir")
        let final = dir + "/out.mov"
        try! FileManager.default.createDirectory(atPath: final, withIntermediateDirectories: false, attributes: nil)
        SlotFS.write("inside", to: final + "/keep.txt")
        assertTaken(claim(final), "a directory")
        XCTAssertTrue(SlotFS.isDirectory(final))
        XCTAssertEqual(SlotFS.read(final + "/keep.txt"), "inside")
        XCTAssertEqual(SlotFS.names(in: dir), ["out.mov"])
    }

    func testASymlinkAtTheFinalPathIsRefusedAndStaysALink() {
        let dir = SlotFS.freshDirectory("link")
        let target = dir + "/real.mov"
        SlotFS.write("real", to: target)
        let final = dir + "/out.mov"
        XCTAssertEqual(symlink(target, final), 0)
        assertTaken(claim(final), "a symlink")
        XCTAssertTrue(SlotFS.isSymlink(final))
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: final), target)
        XCTAssertEqual(SlotFS.read(target), "real")
        XCTAssertEqual(SlotFS.names(in: dir), ["out.mov", "real.mov"])
    }

    func testADanglingSymlinkAtTheFinalPathIsRefusedAndStaysALink() {
        let dir = SlotFS.freshDirectory("dangling")
        let final = dir + "/out.mov"
        let nowhere = dir + "/nowhere.mov"
        XCTAssertEqual(symlink(nowhere, final), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final), "fixture: fileExists follows the link and says false")
        assertTaken(claim(final), "a dangling symlink")
        XCTAssertTrue(SlotFS.lexists(final), "the link is still there")
        XCTAssertTrue(SlotFS.isSymlink(final))
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: final), nowhere)
        XCTAssertFalse(SlotFS.lexists(nowhere), "the claim did not create what the link points at")
        XCTAssertEqual(SlotFS.names(in: dir), ["out.mov"])
    }

    func testAFreeFinalPathGetsAPrivateWorkingDirectoryNextToIt() throws {
        let dir = SlotFS.freshDirectory("free")
        let final = dir + "/out.mov"
        let slot = try claim(final).get()
        XCTAssertFalse(SlotFS.lexists(final), "nothing is at the final path until publish")
        let name = (slot.workDirectoryPath as NSString).lastPathComponent
        XCTAssertEqual((slot.workDirectoryPath as NSString).deletingLastPathComponent, dir)
        let pattern = "^\\.shep-rec-\(getpid())-[0-9a-f]{16}$"
        XCTAssertNotNil(name.range(of: pattern, options: .regularExpression), name)
        XCTAssertTrue(SlotFS.isDirectory(slot.workDirectoryPath))
        XCTAssertFalse(SlotFS.isSymlink(slot.workDirectoryPath))
        XCTAssertEqual(SlotFS.mode(slot.workDirectoryPath) & 0o077, 0, "private: no group or other access")
        XCTAssertEqual(slot.clipPath, slot.workDirectoryPath + "/clip.mov")
        XCTAssertEqual(SlotFS.names(in: slot.workDirectoryPath), [])
    }

    func testTwoClaimsGetDifferentUnguessableDirectoriesAndOnlyOneOwnsAPath() throws {
        let dir = SlotFS.freshDirectory("two")
        let a = try claim(dir + "/a.mov").get()
        let b = try claim(dir + "/b.mov").get()
        XCTAssertNotEqual(a.workDirectoryPath, b.workDirectoryPath)
    }

    func testAWorkingDirectoryNameThatExistsIsRetriedAndLeftAlone() throws {
        let dir = SlotFS.freshDirectory("retry")
        let first = String(repeating: "a", count: 16), second = String(repeating: "b", count: 16)
        let existing = dir + "/.shep-rec-\(getpid())-\(first)"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: false, attributes: nil)
        SlotFS.write("not ours", to: existing + "/clip.mov")
        var names = [first, second]
        let slot = try claim(dir + "/out.mov", suffix: { names.isEmpty ? "cccccccccccccccc" : names.removeFirst() }).get()
        XCTAssertEqual((slot.workDirectoryPath as NSString).lastPathComponent, ".shep-rec-\(getpid())-\(second)")
        XCTAssertEqual(SlotFS.read(existing + "/clip.mov"), "not ours", "mkdir is exclusive: the earlier directory was never adopted")
    }

    func testFiveCollisionsInARowRefuseAndTouchNothing() throws {
        let dir = SlotFS.freshDirectory("collide")
        let same = String(repeating: "d", count: 16)
        let existing = dir + "/.shep-rec-\(getpid())-\(same)"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: false, attributes: nil)
        var calls = 0
        let result = claim(dir + "/out.mov", suffix: { calls += 1; return same })
        guard case .failure = result else { return XCTFail("claimed over a colliding directory") }
        XCTAssertEqual(calls, 5, "up to five names are tried")
        XCTAssertEqual(SlotFS.names(in: dir), [(existing as NSString).lastPathComponent])
    }

    func testARelativeOrEmptyPathIsRefused() {
        for path in ["", "out.mov", "../out.mov", "/", "/tmp/"] {
            guard case .failure = claim(path) else { return XCTFail("claimed '\(path)'") }
        }
    }

    func testTwoThreadsClaimingTheSameFinalPathGetExactlyOneWinner() {
        let dir = SlotFS.freshDirectory("race")
        let final = dir + "/out.mov"
        let box = SlotResultBox()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in box.add(RecordingSlot.claim(finalPath: final)) }
        XCTAssertEqual(box.winCount, 1, "exactly one claim wins")
        XCTAssertEqual(box.refusalList.count, 15)
        XCTAssertTrue(box.refusalList.allSatisfy { $0.reason == "the output path is taken" })
        let dirs = SlotFS.names(in: dir).filter { $0.hasPrefix(".shep-rec-") }
        XCTAssertEqual(dirs.count, 1, "the losers made no working directory")
    }
}

final class RecordingSlotLifecycleTests: XCTestCase {
    func slot(_ label: String) throws -> (slot: RecordingSlot, dir: String, final: String) {
        let dir = SlotFS.freshDirectory(label)
        let final = dir + "/out.mov"
        return (try RecordingSlot.claim(finalPath: final).get(), dir, final)
    }

    func testPublishLinksTheClipAndLeavesExactlyTheFinalFile() throws {
        let s = try slot("publish")
        SlotFS.write("the movie", to: s.slot.clipPath)
        XCTAssertEqual(s.slot.publish(), .published)
        XCTAssertEqual(SlotFS.read(s.final), "the movie")
        XCTAssertEqual(SlotFS.names(in: s.dir), ["out.mov"], "our clip and our working directory are gone")
        XCTAssertEqual(SlotFS.linkCount(s.final), 1)
        XCTAssertFalse(SlotFS.isSymlink(s.final))
    }

    func testSomeoneCreatingTheFinalPathBetweenClaimAndPublishIsNeverOverwritten() throws {
        let s = try slot("publish-race")
        SlotFS.write("our movie", to: s.slot.clipPath)
        s.slot.beforePublish = { SlotFS.write("the other writer's file", to: s.final) }
        let result = s.slot.publish()
        guard case .keptInWorkDirectory(let clipPath, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(clipPath, s.slot.clipPath)
        XCTAssertEqual(SlotFS.read(s.final), "the other writer's file", "their file is untouched")
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "our movie", "our clip is kept where it is")
        XCTAssertTrue(SlotFS.isDirectory(s.slot.workDirectoryPath))
    }

    func testADanglingSymlinkAppearingBeforePublishIsNotFollowedOrReplaced() throws {
        let s = try slot("publish-dangling")
        SlotFS.write("our movie", to: s.slot.clipPath)
        let nowhere = s.dir + "/elsewhere/never.mov"
        s.slot.beforePublish = { XCTAssertEqual(symlink(nowhere, s.final), 0) }
        guard case .keptInWorkDirectory = s.slot.publish() else { return XCTFail("published over a link") }
        XCTAssertTrue(SlotFS.isSymlink(s.final))
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: s.final), nowhere)
        XCTAssertFalse(SlotFS.lexists(s.dir + "/elsewhere"))
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "our movie")
    }

    func testPublishWithoutAClipRemovesNothing() throws {
        let s = try slot("publish-noclip")
        XCTAssertEqual(s.slot.publish(), .noClip)
        XCTAssertFalse(SlotFS.lexists(s.final))
        XCTAssertTrue(SlotFS.isDirectory(s.slot.workDirectoryPath))
    }

    func testPublishRefusesAClipThatIsASymlink() throws {
        let s = try slot("publish-clip-link")
        let outside = SlotFS.freshDirectory("publish-clip-link-outside")
        SlotFS.write("private", to: outside + "/secret.mov")
        XCTAssertEqual(symlink(outside + "/secret.mov", s.slot.clipPath), 0)
        XCTAssertEqual(s.slot.publish(), .noClip)
        XCTAssertFalse(SlotFS.lexists(s.final), "a link out of the working directory is never published")
        XCTAssertEqual(SlotFS.read(outside + "/secret.mov"), "private")
    }

    func testDiscardRemovesOnlyOurClipAndOurWorkingDirectory() throws {
        let dir = SlotFS.freshDirectory("discard")
        SlotFS.write("neighbour", to: dir + "/neighbour.mov")
        let other = dir + "/.shep-rec-1-" + String(repeating: "0", count: 16)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: false, attributes: nil)
        SlotFS.write("their partial clip", to: other + "/clip.mov")
        let mine = try RecordingSlot.claim(finalPath: dir + "/out.mov").get()
        SlotFS.write("partial", to: mine.clipPath)
        XCTAssertEqual(mine.discard(), .removed)
        XCTAssertFalse(SlotFS.lexists(mine.workDirectoryPath))
        XCTAssertFalse(SlotFS.lexists(dir + "/out.mov"), "discard never creates or removes the final path")
        XCTAssertEqual(SlotFS.read(dir + "/neighbour.mov"), "neighbour")
        XCTAssertEqual(SlotFS.read(other + "/clip.mov"), "their partial clip", "another run's working directory is not ours")
    }

    func testDiscardNeverUnlinksAnExistingFinalPath() throws {
        let s = try slot("discard-final")
        SlotFS.write("started, then the other writer arrived", to: s.slot.clipPath)
        SlotFS.write("the other writer's file", to: s.final)
        XCTAssertEqual(s.slot.discard(), .removed)
        XCTAssertEqual(SlotFS.read(s.final), "the other writer's file")
    }

    func testAWorkingDirectoryReplacedByASymlinkIsNotFollowedByDiscard() throws {
        let s = try slot("discard-swap")
        SlotFS.write("our partial", to: s.slot.clipPath)
        let outside = SlotFS.freshDirectory("discard-swap-outside")
        SlotFS.write("outside clip", to: outside + "/clip.mov")
        SlotFS.write("outside other", to: outside + "/keep.txt")
        let moved = s.dir + "/moved-aside"
        s.slot.beforeDiscard = {
            XCTAssertEqual(rename(s.slot.workDirectoryPath, moved), 0)
            XCTAssertEqual(symlink(outside, s.slot.workDirectoryPath), 0)
        }
        XCTAssertEqual(s.slot.discard(), .identityMismatch)
        XCTAssertEqual(SlotFS.read(outside + "/clip.mov"), "outside clip", "nothing outside was removed")
        XCTAssertEqual(SlotFS.read(outside + "/keep.txt"), "outside other")
        XCTAssertTrue(SlotFS.isSymlink(s.slot.workDirectoryPath), "the swapped-in link is left alone")
        XCTAssertEqual(SlotFS.read(moved + "/clip.mov"), "our partial", "and so is what we moved: with no identity, nothing is removed")
    }

    func testAWorkingDirectoryReplacedByAnotherDirectoryIsNotEmptiedByDiscard() throws {
        let s = try slot("discard-swap-dir")
        SlotFS.write("our partial", to: s.slot.clipPath)
        let moved = s.dir + "/moved-aside"
        s.slot.beforeDiscard = {
            XCTAssertEqual(rename(s.slot.workDirectoryPath, moved), 0)
            try! FileManager.default.createDirectory(atPath: s.slot.workDirectoryPath, withIntermediateDirectories: false, attributes: nil)
            SlotFS.write("theirs", to: s.slot.workDirectoryPath + "/clip.mov")
        }
        XCTAssertEqual(s.slot.discard(), .identityMismatch)
        XCTAssertEqual(SlotFS.read(s.slot.workDirectoryPath + "/clip.mov"), "theirs")
    }

    func testPublishDoesNotTouchASwappedWorkingDirectoryEither() throws {
        let s = try slot("publish-swap")
        SlotFS.write("our movie", to: s.slot.clipPath)
        let outside = SlotFS.freshDirectory("publish-swap-outside")
        SlotFS.write("outside clip", to: outside + "/clip.mov")
        s.slot.beforePublish = {
            XCTAssertEqual(rename(s.slot.workDirectoryPath, s.dir + "/moved-aside"), 0)
            XCTAssertEqual(symlink(outside, s.slot.workDirectoryPath), 0)
        }
        XCTAssertEqual(s.slot.publish(), .identityMismatch)
        XCTAssertFalse(SlotFS.lexists(s.final), "a clip reached through a swapped path is never published")
        XCTAssertEqual(SlotFS.read(outside + "/clip.mov"), "outside clip")
    }

    func testASlotThatEndedCannotBeUsedAgain() throws {
        let s = try slot("twice")
        SlotFS.write("m", to: s.slot.clipPath)
        XCTAssertEqual(s.slot.publish(), .published)
        XCTAssertEqual(s.slot.discard(), .alreadyFinished)
        XCTAssertEqual(s.slot.publish(), .alreadyFinished)
        XCTAssertEqual(SlotFS.read(s.final), "m")
    }

    func testAFinishedClaimFreesThePathForANewClaim() throws {
        let s = try slot("reclaim")
        XCTAssertEqual(s.slot.discard(), .removed)
        let again = RecordingSlot.claim(finalPath: s.final)
        guard case .success = again else { return XCTFail("a discarded claim should free the path") }
    }
}

final class ExclusiveFileTests: XCTestCase {
    func testANewFileIsCreatedPrivate() throws {
        let dir = SlotFS.freshDirectory("excl")
        let path = dir + "/status"
        let fd = try ExclusiveFile.create(path: path).get()
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertEqual(SlotFS.mode(path) & 0o077, 0)
    }

    func testAnythingAtThePathIsRefusedAndUntouched() throws {
        let dir = SlotFS.freshDirectory("excl-taken")
        SlotFS.write("keep", to: dir + "/file")
        XCTAssertEqual(symlink(dir + "/file", dir + "/link"), 0)
        XCTAssertEqual(symlink(dir + "/nowhere", dir + "/dangling"), 0)
        try FileManager.default.createDirectory(atPath: dir + "/dir", withIntermediateDirectories: false, attributes: nil)
        for name in ["file", "link", "dangling", "dir"] {
            guard case .failure = ExclusiveFile.create(path: dir + "/" + name) else { return XCTFail(name) }
        }
        XCTAssertEqual(SlotFS.read(dir + "/file"), "keep")
        XCTAssertTrue(SlotFS.isSymlink(dir + "/dangling"))
        XCTAssertFalse(SlotFS.lexists(dir + "/nowhere"), "the dangling link was not followed")
    }

    func testARelativePathIsRefused() {
        guard case .failure = ExclusiveFile.create(path: "status") else { return XCTFail("relative path accepted") }
    }
}
