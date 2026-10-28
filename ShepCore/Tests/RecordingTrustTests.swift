import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of 456a156, finding A (R1 residual): a held directory descriptor does not bind the pathname the
// recorder opens, and a clip is not owned by identity. Pure tests inject lstat-like results; the rest run against the real file system in
// fresh temporary directories. Nothing here removes anything (the system clears the temporary directory).

private func dirStat(_ uid: UInt32, _ permissions: UInt32) -> RecordingPathStat {
    RecordingPathStat(uid: uid, mode: 0o040000 | permissions)
}

private func table(_ entries: [String: RecordingPathStat]) -> (String) -> RecordingPathStat? {
    return { entries[$0] }
}

final class RecordingParentTrustPureTests: XCTestCase {
    let me: UInt32 = 501
    let chain = ["/", "/Users", "/Users/me", "/Users/me/evidence"]

    func trusted() -> [String: RecordingPathStat] {
        ["/": dirStat(0, 0o755), "/Users": dirStat(0, 0o755), "/Users/me": dirStat(me, 0o755), "/Users/me/evidence": dirStat(me, 0o700)]
    }

    func evaluate(_ entries: [String: RecordingPathStat]) -> RecordingSlotRefusal? {
        RecordingParentTrust.evaluate(resolvedParent: "/Users/me/evidence", effectiveUID: me, lstat: table(entries))
    }

    func assertRefused(_ entries: [String: RecordingPathStat], contains word: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let refusal = evaluate(entries) else { return XCTFail("accepted", file: file, line: line) }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason, file: file, line: line)
        XCTAssertTrue(refusal.reason.hasSuffix(")"), refusal.reason, file: file, line: line)
        XCTAssertTrue(refusal.reason.contains(word), refusal.reason, file: file, line: line)
        XCTAssertFalse(refusal.reason.contains("/Users/me"), "no path in the message: " + refusal.reason, file: file, line: line)
    }

    func testAPrivateParentOwnedByUsWithTrustedAncestorsIsAccepted() {
        XCTAssertNil(evaluate(trusted()))
        var open755 = trusted(); open755["/Users/me/evidence"] = dirStat(me, 0o755)
        XCTAssertNil(evaluate(open755), "0755 owned by us is private enough: only others cannot write")
    }

    func testAWorldWritableParentIsRefused() {
        var e = trusted(); e["/Users/me/evidence"] = dirStat(me, 0o777)
        assertRefused(e, contains: "writable")
    }

    func testAGroupWritableParentIsRefused() {
        var e = trusted(); e["/Users/me/evidence"] = dirStat(me, 0o770)
        assertRefused(e, contains: "writable")
        e["/Users/me/evidence"] = dirStat(me, 0o720)
        assertRefused(e, contains: "writable")
    }

    func testAStickyBitOnTheParentItselfDoesNotMakeAWritableParentAcceptable() {
        var e = trusted(); e["/Users/me/evidence"] = dirStat(me, 0o1777)
        assertRefused(e, contains: "writable")
    }

    func testAParentOwnedBySomeoneElseIsRefusedEvenWhenPrivate() {
        var e = trusted(); e["/Users/me/evidence"] = dirStat(me + 1, 0o700)
        assertRefused(e, contains: "owned")
        e["/Users/me/evidence"] = dirStat(0, 0o700)
        assertRefused(e, contains: "owned")
    }

    func testAParentThatIsNotARealDirectoryIsRefused() {
        var e = trusted()
        e["/Users/me/evidence"] = RecordingPathStat(uid: me, mode: 0o120000 | 0o777)
        assertRefused(e, contains: "directory")
        e["/Users/me/evidence"] = RecordingPathStat(uid: me, mode: 0o100000 | 0o600)
        assertRefused(e, contains: "directory")
        e.removeValue(forKey: "/Users/me/evidence")
        assertRefused(e, contains: "inspected")
    }

    func testAnAncestorWritableByOthersWithoutTheStickyBitIsRefusedAndNamed() {
        for permissions: UInt32 in [0o777, 0o775, 0o757, 0o722] {
            var e = trusted(); e["/Users/me"] = dirStat(me, permissions)
            assertRefused(e, contains: "me")
            guard let refusal = evaluate(e) else { return XCTFail() }
            XCTAssertTrue(refusal.reason.contains("ancestor"), refusal.reason)
        }
    }

    func testAnAncestorOwnedBySomeoneElseThanUsOrRootIsRefused() {
        var e = trusted(); e["/Users"] = dirStat(777, 0o755)
        assertRefused(e, contains: "owned")
    }

    func testAnAncestorOwnedByRootOrByUsIsAccepted() {
        var e = trusted(); e["/Users"] = dirStat(me, 0o755)
        XCTAssertNil(evaluate(e))
        e["/Users"] = dirStat(0, 0o755)
        XCTAssertNil(evaluate(e))
    }

    func testAStickyWorldWritableAncestorIsAccepted() {
        var e = trusted()
        e["/Users"] = dirStat(0, 0o1777)    // like /tmp or /private/var/folders
        XCTAssertNil(evaluate(e))
        e["/Users"] = dirStat(me, 0o1777)
        XCTAssertNil(evaluate(e))
    }

    func testAStickyAncestorOwnedByAStrangerIsStillRefused() {
        var e = trusted(); e["/Users"] = dirStat(777, 0o1777)
        assertRefused(e, contains: "owned")
    }

    func testAnAncestorThatIsASymlinkOrMissingIsRefused() {
        var e = trusted(); e["/Users/me"] = RecordingPathStat(uid: me, mode: 0o120000 | 0o755)
        assertRefused(e, contains: "directory")
        e = trusted(); e.removeValue(forKey: "/Users")
        assertRefused(e, contains: "inspected")
    }

    func testTheRootItselfIsAnAncestorToo() {
        var e = trusted(); e["/"] = dirStat(0, 0o777)
        assertRefused(e, contains: "/")
        var e2 = trusted(); e2["/"] = dirStat(me + 9, 0o755)
        assertRefused(e2, contains: "owned")
    }

    func testAParentDirectlyUnderRootIsChecked() {
        let e: [String: RecordingPathStat] = ["/": dirStat(0, 0o755), "/evidence": dirStat(me, 0o700)]
        XCTAssertNil(RecordingParentTrust.evaluate(resolvedParent: "/evidence", effectiveUID: me, lstat: table(e)))
        XCTAssertNil(RecordingParentTrust.evaluate(resolvedParent: "/", effectiveUID: 0, lstat: table(["/": dirStat(0, 0o755)])),
                     "the root as the parent: owned by root, which is the effective uid here")
    }

    func testCheckResolvesFirstAndThenJudgesTheResolvedPath() {
        // /link -> /Users/me/evidence (trusted) is accepted and reports the resolved path; /bad -> a world-writable directory is refused.
        var e = trusted(); e["/Users/open"] = dirStat(me, 0o777)
        let resolve: (String) -> String? = { path in
            switch path {
            case "/link": return "/Users/me/evidence"
            case "/bad": return "/Users/open"
            default: return nil
            }
        }
        let good = RecordingParentTrust.check(parent: "/link", effectiveUID: me, resolve: resolve, lstat: table(e))
        XCTAssertEqual(try? good.get(), "/Users/me/evidence")
        guard case .failure(let refusal) = RecordingParentTrust.check(parent: "/bad", effectiveUID: me, resolve: resolve, lstat: table(e)) else {
            return XCTFail("a link into an unsafe directory was accepted")
        }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason)
        guard case .failure(let missing) = RecordingParentTrust.check(parent: "/nowhere", effectiveUID: me, resolve: resolve, lstat: table(e)) else {
            return XCTFail("an unresolvable parent was accepted")
        }
        XCTAssertFalse(missing.reason.isEmpty)
    }
}

final class RecordingParentTrustRealTests: XCTestCase {
    func make(_ label: String, mode: mode_t) -> String {
        let path = SlotFS.freshDirectory(label)
        XCTAssertEqual(chmod(path, mode), 0, path)
        return path
    }

    func assertClaimRefused(_ parent: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: parent + "/out.mov") else {
            return XCTFail("claimed in an unsafe parent", file: file, line: line)
        }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason, file: file, line: line)
        XCTAssertEqual(SlotFS.names(in: parent), [], "a refused claim creates nothing", file: file, line: line)
    }

    func testAWorldWritableParentIsRefusedByClaimAndLeftEmpty() {
        assertClaimRefused(make("trust-world", mode: 0o777))
    }

    func testAGroupWritableParentIsRefusedByClaim() {
        assertClaimRefused(make("trust-group", mode: 0o770))
        assertClaimRefused(make("trust-group2", mode: 0o775))
    }

    func testAPrivateOrPubliclyReadableParentOwnedByUsIsAccepted() throws {
        for mode: mode_t in [0o700, 0o755] {
            let parent = make("trust-ok-\(mode)", mode: mode)
            let slot = try RecordingSlot.claim(finalPath: parent + "/out.mov").get()
            XCTAssertEqual((slot.workDirectoryPath as NSString).deletingLastPathComponent, parent)
        }
    }

    func testAParentNotOwnedByTheEffectiveUidIsRefused() {
        let parent = make("trust-owner", mode: 0o700)
        let other = UInt32(geteuid()) &+ 1
        guard case .failure(let refusal) = RecordingParentTrust.check(parent: parent, effectiveUID: other, resolve: RecordingParentTrust.realResolve,
                                                                      lstat: RecordingParentTrust.realLstat) else {
            return XCTFail("a directory owned by another uid was accepted")
        }
        XCTAssertTrue(refusal.reason.contains("owned"), refusal.reason)
        XCTAssertFalse(refusal.reason.contains(parent), "no path in the message")
    }

    func testASymlinkedParentIsResolvedAndTheTargetIsWhatIsChecked() throws {
        let holder = make("trust-link-holder", mode: 0o700)
        let privateTarget = make("trust-link-private", mode: 0o700)
        let openTarget = make("trust-link-open", mode: 0o777)
        XCTAssertEqual(symlink(privateTarget, holder + "/good"), 0)
        XCTAssertEqual(symlink(openTarget, holder + "/bad"), 0)
        let slot = try RecordingSlot.claim(finalPath: holder + "/good/out.mov").get()
        XCTAssertEqual((slot.workDirectoryPath as NSString).deletingLastPathComponent, privateTarget,
                       "the recorder is handed the resolved path, never one that goes through the link")
        XCTAssertEqual(SlotFS.names(in: openTarget), [])
        assertClaimRefused(holder + "/bad")
    }

    func testAStickyWorldWritableAncestorIsAcceptedAndANonStickyOneIsNot() throws {
        let sticky = make("trust-sticky", mode: 0o1777)
        let child = sticky + "/private"
        XCTAssertEqual(mkdir(child, 0o700), 0)
        let slot = try RecordingSlot.claim(finalPath: child + "/out.mov").get()
        XCTAssertEqual((slot.workDirectoryPath as NSString).deletingLastPathComponent, child)
        let loose = make("trust-loose", mode: 0o777)
        let inner = loose + "/private"
        XCTAssertEqual(mkdir(inner, 0o700), 0)
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: inner + "/out.mov") else { return XCTFail("a writable, non-sticky ancestor was accepted") }
        XCTAssertTrue(refusal.reason.contains("ancestor"), refusal.reason)
        XCTAssertEqual(SlotFS.names(in: inner), [])
    }

    func testTheRealTemporaryDirectoryChainIsAcceptable() {
        let parent = make("trust-chain", mode: 0o700)
        XCTAssertNil(RecordingParentTrust.evaluate(resolvedParent: parent, effectiveUID: UInt32(geteuid()), lstat: RecordingParentTrust.realLstat))
    }
}

final class RecordingClipIdentityTests: XCTestCase {
    func slot(_ label: String) throws -> (slot: RecordingSlot, dir: String, final: String) {
        let dir = SlotFS.freshDirectory(label)
        let final = dir + "/out.mov"
        return (try RecordingSlot.claim(finalPath: final).get(), dir, final)
    }

    func testObservingBeforeTheClipExistsReturnsNilWithoutError() throws {
        let s = try slot("obs-none")
        guard case .success(let identity) = s.slot.observeClip() else { return XCTFail("an absent clip is not an error") }
        XCTAssertNil(identity)
        XCTAssertNil(s.slot.clipIdentity)
        XCTAssertTrue(s.slot.pathIsBound(), "no clip yet is fine")
    }

    func testTheFirstSightOfARegularClipRecordsItsOwnDeviceAndInode() throws {
        let s = try slot("obs-first")
        SlotFS.write("frames", to: s.slot.clipPath)
        var st = stat()
        XCTAssertEqual(lstat(s.slot.clipPath, &st), 0)
        guard case .success(let identity) = s.slot.observeClip(), let seen = identity else { return XCTFail("not observed") }
        XCTAssertEqual(seen.device, UInt64(truncatingIfNeeded: st.st_dev))
        XCTAssertEqual(seen.inode, UInt64(truncatingIfNeeded: st.st_ino))
        XCTAssertEqual(s.slot.clipIdentity, seen)
        guard case .success(let again) = s.slot.observeClip() else { return XCTFail() }
        XCTAssertEqual(again, seen, "later looks agree")
        XCTAssertTrue(s.slot.pathIsBound())
        XCTAssertEqual(s.slot.clipSize(), 6)
    }

    func testASymlinkOrADirectoryCalledClipIsNotObservedAsOurs() throws {
        let a = try slot("obs-link")
        let outside = SlotFS.freshDirectory("obs-link-outside")
        SlotFS.write("theirs", to: outside + "/x.mov")
        XCTAssertEqual(symlink(outside + "/x.mov", a.slot.clipPath), 0)
        guard case .failure = a.slot.observeClip() else { return XCTFail("a symlink was taken as the clip") }
        XCTAssertNil(a.slot.clipIdentity)
        let b = try slot("obs-dir")
        XCTAssertEqual(mkdir(b.slot.clipPath, 0o700), 0)
        guard case .failure = b.slot.observeClip() else { return XCTFail("a directory was taken as the clip") }
    }

    func testAHardLinkedClipIsForeign() throws {
        let s = try slot("obs-nlink")
        SlotFS.write("frames", to: s.slot.clipPath)
        XCTAssertEqual(link(s.slot.clipPath, s.dir + "/second-name"), 0)
        XCTAssertEqual(SlotFS.linkCount(s.slot.clipPath), 2)
        guard case .failure = s.slot.observeClip() else { return XCTFail("a file with two names was accepted") }
        XCTAssertNil(s.slot.clipIdentity)
        let result = s.slot.publish()
        guard case .clipReplaced = result else { return XCTFail("\(result)") }
        XCTAssertFalse(SlotFS.lexists(s.final), "a hard-linked file is never published")
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "frames")
        XCTAssertEqual(SlotFS.read(s.dir + "/second-name"), "frames")
    }

    func testAHardLinkAddedAfterTheFirstSightIsPreservedByDiscard() throws {
        let s = try slot("obs-nlink-later")
        SlotFS.write("frames", to: s.slot.clipPath)
        guard case .success = s.slot.observeClip() else { return XCTFail() }
        XCTAssertEqual(link(s.slot.clipPath, s.dir + "/second-name"), 0)
        let result = s.slot.discard()
        guard case .clipReplaced(let text) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(text.contains("left in " + s.slot.workDirectoryPath), text)
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "frames")
        XCTAssertEqual(SlotFS.read(s.dir + "/second-name"), "frames")
        XCTAssertTrue(SlotFS.isDirectory(s.slot.workDirectoryPath), "the directory is not removed")
    }

    func testARegularFileRenamedOverTheClipIsPreservedByDiscard() throws {
        let s = try slot("rename-over-discard")
        SlotFS.write("our frames", to: s.slot.clipPath)
        guard case .success(let identity) = s.slot.observeClip(), identity != nil else { return XCTFail() }
        SlotFS.write("somebody else's file", to: s.dir + "/foreign.mov")
        XCTAssertEqual(rename(s.dir + "/foreign.mov", s.slot.clipPath), 0)
        guard case .failure = s.slot.observeClip() else { return XCTFail("the replacement was accepted as ours") }
        XCTAssertFalse(s.slot.pathIsBound(), "the clip is no longer the one first seen")
        let result = s.slot.discard()
        guard case .clipReplaced(let text) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(text, "the clip was replaced by another file; left in " + s.slot.workDirectoryPath)
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "somebody else's file", "unlinked nothing")
        XCTAssertTrue(SlotFS.isDirectory(s.slot.workDirectoryPath))
        XCTAssertFalse(SlotFS.lexists(s.final))
    }

    func testARegularFileRenamedOverTheClipIsNeverPublished() throws {
        let s = try slot("rename-over-publish")
        SlotFS.write("our frames", to: s.slot.clipPath)
        guard case .success = s.slot.observeClip() else { return XCTFail() }
        SlotFS.write("somebody else's file", to: s.dir + "/foreign.mov")
        XCTAssertEqual(rename(s.dir + "/foreign.mov", s.slot.clipPath), 0)
        let result = s.slot.publish()
        guard case .clipReplaced = result else { return XCTFail("\(result)") }
        XCTAssertFalse(SlotFS.lexists(s.final), "nothing is published from a file that is not the one first seen")
        XCTAssertEqual(SlotFS.read(s.slot.clipPath), "somebody else's file")
    }

    func testTheReplacementCanTakeTheFreedInodeNumberAndStillIsNotOurs() throws {
        // The first-seen clip is pinned by the slot, so its inode cannot be recycled for the replacement.
        let s = try slot("rename-over-recycle")
        SlotFS.write("our frames", to: s.slot.clipPath)
        guard case .success(let first) = s.slot.observeClip(), let seen = first else { return XCTFail() }
        for index in 0..<20 {
            SlotFS.write("filler \(index)", to: s.dir + "/f\(index)")
            XCTAssertEqual(rename(s.dir + "/f\(index)", s.slot.clipPath), 0)
            var st = stat()
            XCTAssertEqual(lstat(s.slot.clipPath, &st), 0)
            XCTAssertNotEqual(UInt64(truncatingIfNeeded: st.st_ino), seen.inode, "the pinned inode was recycled")
        }
        guard case .failure = s.slot.observeClip() else { return XCTFail("a replacement was accepted") }
    }

    func testAnUnchangedClipIsPublishedAndDiscardedAfterObserving() throws {
        let p = try slot("obs-publish")
        SlotFS.write("the movie", to: p.slot.clipPath)
        guard case .success = p.slot.observeClip() else { return XCTFail() }
        XCTAssertEqual(p.slot.publish(), .published)
        XCTAssertEqual(SlotFS.read(p.final), "the movie")
        XCTAssertEqual(SlotFS.names(in: p.dir), ["out.mov"])
        let d = try slot("obs-discard")
        SlotFS.write("partial", to: d.slot.clipPath)
        guard case .success = d.slot.observeClip() else { return XCTFail() }
        XCTAssertEqual(d.slot.discard(), .removed)
        XCTAssertEqual(SlotFS.names(in: d.dir), [])
    }

    func testAWorkingDirectoryThatGainedAForeignFileIsNotRemovedRecursively() throws {
        let s = try slot("foreign-inside")
        SlotFS.write("partial", to: s.slot.clipPath)
        SlotFS.write("not ours", to: s.slot.workDirectoryPath + "/extra.txt")
        let result = s.slot.discard()
        guard case .leftBehind(let why) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(SlotFS.read(s.slot.workDirectoryPath + "/extra.txt"), "not ours")
        XCTAssertFalse(SlotFS.lexists(s.slot.clipPath), "our own verified clip is removed")
    }
}

final class RecordingPathBindingTests: XCTestCase {
    func slot(_ label: String) throws -> (slot: RecordingSlot, dir: String, final: String) {
        let dir = SlotFS.freshDirectory(label)
        let final = dir + "/out.mov"
        return (try RecordingSlot.claim(finalPath: final).get(), dir, final)
    }

    /// What ScreenCaptureKit does: opens the pathname (not a descriptor) exclusively and writes.
    func recorderWrites(_ path: String, _ text: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return true
    }

    func swapForSymlink(_ s: (slot: RecordingSlot, dir: String, final: String), to target: String) {
        XCTAssertEqual(rename(s.slot.workDirectoryPath, s.dir + "/moved-aside"), 0)
        XCTAssertEqual(symlink(target, s.slot.workDirectoryPath), 0)
    }

    func testAFreshSlotIsBoundAndStaysBoundWhileTheClipGrows() throws {
        let s = try slot("bound")
        XCTAssertTrue(s.slot.pathIsBound())
        XCTAssertTrue(recorderWrites(s.slot.clipPath, "frames"))
        guard case .success = s.slot.observeClip() else { return XCTFail() }
        XCTAssertTrue(s.slot.pathIsBound())
    }

    func testRenamePlusSymlinkBeforeStartIsRefusedByTheStartGateBeforeAnyWrite() throws {
        let s = try slot("swap-before")
        let attacker = SlotFS.freshDirectory("swap-before-attacker")
        swapForSymlink(s, to: attacker)
        XCTAssertFalse(s.slot.pathIsBound(), "the name now leads to another directory")
        // The recorder's start gate: it writes only if the path is bound. Here it must not.
        var wrote = false
        if s.slot.pathIsBound() { wrote = recorderWrites(s.slot.clipPath, "pixels") }
        XCTAssertFalse(wrote)
        XCTAssertEqual(SlotFS.names(in: attacker), [], "no pixels landed in the attacker's directory")
        XCTAssertEqual(SlotFS.names(in: s.dir + "/moved-aside"), [], "nor in the moved private directory")
        XCTAssertEqual(s.slot.discard(), .identityMismatch)
        XCTAssertEqual(SlotFS.names(in: attacker), [])
        XCTAssertTrue(SlotFS.isSymlink(s.slot.workDirectoryPath), "the link is left alone")
        XCTAssertFalse(SlotFS.lexists(s.final))
    }

    func testRenamePlusSymlinkAfterStartIsDetectedAtTheNextCheckAndDiscardTouchesNothingForeign() throws {
        let s = try slot("swap-after")
        XCTAssertTrue(s.slot.pathIsBound(), "the start gate passed")
        let attacker = SlotFS.freshDirectory("swap-after-attacker")
        SlotFS.write("attacker's own file", to: attacker + "/keep.txt")
        swapForSymlink(s, to: attacker)
        XCTAssertTrue(recorderWrites(s.slot.clipPath, "pixels"), "the attacker case: the path-based open goes through the link")
        XCTAssertFalse(s.slot.pathIsBound(), "the next periodic check sees the swap")
        let result = s.slot.discard()
        XCTAssertEqual(result, .identityMismatch)
        XCTAssertEqual(SlotFS.read(attacker + "/clip.mov"), "pixels", "discard removed nothing in the link's target")
        XCTAssertEqual(SlotFS.read(attacker + "/keep.txt"), "attacker's own file")
        XCTAssertTrue(SlotFS.isSymlink(s.slot.workDirectoryPath))
        XCTAssertTrue(SlotFS.isDirectory(s.dir + "/moved-aside"), "the private directory we moved is not removed either")
    }

    func testPublishAfterTheSwapIsRefusedAndPublishesNothing() throws {
        let s = try slot("swap-publish")
        XCTAssertTrue(recorderWrites(s.slot.clipPath, "pixels"))
        guard case .success = s.slot.observeClip() else { return XCTFail() }
        let attacker = SlotFS.freshDirectory("swap-publish-attacker")
        SlotFS.write("planted", to: attacker + "/clip.mov")
        swapForSymlink(s, to: attacker)
        XCTAssertFalse(s.slot.pathIsBound())
        XCTAssertEqual(s.slot.publish(), .identityMismatch)
        XCTAssertFalse(SlotFS.lexists(s.final))
        XCTAssertEqual(SlotFS.read(attacker + "/clip.mov"), "planted")
    }

    func testAnotherDirectoryAtTheSameNameIsNotBoundEither() throws {
        let s = try slot("swap-dir")
        XCTAssertEqual(rename(s.slot.workDirectoryPath, s.dir + "/moved-aside"), 0)
        XCTAssertEqual(mkdir(s.slot.workDirectoryPath, 0o700), 0)
        XCTAssertFalse(s.slot.pathIsBound(), "a directory, but not the held one")
    }

    func testTheClipPathBeingASymlinkIsNotBound() throws {
        let s = try slot("clip-link")
        let outside = SlotFS.freshDirectory("clip-link-outside")
        XCTAssertEqual(symlink(outside + "/target.mov", s.slot.clipPath), 0)
        XCTAssertFalse(s.slot.pathIsBound())
        XCTAssertFalse(SlotFS.lexists(outside + "/target.mov"), "nothing was created through the link")
    }

    func testASlotThatEndedIsNoLongerBound() throws {
        let s = try slot("ended")
        XCTAssertEqual(s.slot.discard(), .removed)
        XCTAssertFalse(s.slot.pathIsBound())
    }
}
