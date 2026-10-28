import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of 6e06e30, finding C: the trust rule judged the output folder and its ancestors by owner and mode
// bits only. A macOS ACL can let ANOTHER user add, delete or rename entries (or change the mode) while the BSD mode stays 0700/0755.
// The rule: an ALLOW entry carrying add_file / add_subdirectory / delete_child / delete / write data / append / write security / change
// owner is acceptable only for the current effective user; anything else (another user, a group, an unresolvable principal) refuses.
// Deny entries and allow entries with benign rights (read, list, search, attributes, read security, sync) pass. The pure tests inject
// the ACL reader; the real tests (macOS only) set an ACL with /bin/chmod on a temporary directory they made and remove only that one.

private struct ACLTestReader: RecordingACLReading {
    var byPath: [String: RecordingACLRead] = [:]
    var workDirectory: RecordingACLRead = .none

    func read(path: String) -> RecordingACLRead {
        if let answer = byPath[path] { return answer }
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last.hasPrefix(RecordingSlot.directoryPrefix) { return workDirectory }
        return .none
    }
}

private func aclDir(_ uid: UInt32, _ permissions: UInt32) -> RecordingPathStat {
    RecordingPathStat(uid: uid, mode: 0o040000 | permissions)
}

private func allow(_ principal: RecordingACLPrincipal, _ rights: RecordingACLRights) -> RecordingACLEntry {
    RecordingACLEntry(allow: true, principal: principal, rights: rights)
}

private func deny(_ principal: RecordingACLPrincipal, _ rights: RecordingACLRights) -> RecordingACLEntry {
    RecordingACLEntry(allow: false, principal: principal, rights: rights)
}

final class RecordingACLPureTests: XCTestCase {
    let me: UInt32 = 501
    let stranger: UInt32 = 502
    let leaf = "/Users/me/evidence"

    func modes() -> [String: RecordingPathStat] {
        ["/": aclDir(0, 0o755), "/Users": aclDir(0, 0o755), "/Users/me": aclDir(me, 0o755), "/Users/me/evidence": aclDir(me, 0o700)]
    }

    private func evaluate(_ reader: ACLTestReader) -> RecordingSlotRefusal? {
        let table = modes()
        return RecordingParentTrust.evaluate(resolvedParent: leaf, effectiveUID: me, lstat: { table[$0] }, acl: reader)
    }

    private func assertRefused(_ reader: ACLTestReader, contains word: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let refusal = evaluate(reader) else { return XCTFail("accepted", file: file, line: line) }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason, file: file, line: line)
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason, file: file, line: line)
        XCTAssertTrue(refusal.reason.contains(word), refusal.reason, file: file, line: line)
        XCTAssertFalse(refusal.reason.contains("/Users/me"), "no path in the message: " + refusal.reason, file: file, line: line)
    }

    private func leafACL(_ read: RecordingACLRead) -> ACLTestReader {
        ACLTestReader(byPath: [leaf: read])
    }

    // MARK: every mutating right, for a foreign user and for a group

    func testEveryMutatingRightForAnotherUserRefusesTheFolder() {
        let rights: [(String, RecordingACLRights)] = [
            ("add_file", .addFile), ("add_subdirectory", .addSubdirectory), ("delete_child", .deleteChild), ("delete", .delete),
            ("write data", .writeData), ("append", .append), ("write security", .writeSecurity), ("change owner", .changeOwner),
        ]
        for (label, right) in rights {
            let reader = leafACL(.entries([allow(.user(stranger), right)]))
            guard let refusal = evaluate(reader) else { XCTFail("\(label) for another user was accepted"); continue }
            XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), "\(label): " + refusal.reason)
            XCTAssertTrue(refusal.reason.contains("evidence"), "names the component: " + refusal.reason)
        }
    }

    func testEveryMutatingRightForAGroupRefusesTheFolder() {
        for right in [RecordingACLRights.addFile, .addSubdirectory, .deleteChild, .delete, .writeData, .append, .writeSecurity, .changeOwner] {
            XCTAssertNotNil(evaluate(leafACL(.entries([allow(.group(12), right)]))), "group:everyone with \(right.rawValue)")
            XCTAssertNotNil(evaluate(leafACL(.entries([allow(.group(80), right)]))), "group:admin with \(right.rawValue)")
        }
    }

    func testAMutatingRightAmongBenignOnesStillRefuses() {
        let rights: RecordingACLRights = [.readData, .execute, .readAttributes, .readSecurity, .synchronize, .deleteChild]
        assertRefused(leafACL(.entries([allow(.group(12), rights)])), contains: "evidence")
    }

    func testAMutatingRightOnALaterEntryRefuses() {
        let reader = leafACL(.entries([allow(.user(me), .readData), deny(.user(stranger), .deleteChild), allow(.user(stranger), .addFile)]))
        assertRefused(reader, contains: "evidence")
    }

    func testAnUnresolvableQualifierWithAMutatingRightRefuses() {
        assertRefused(leafACL(.entries([allow(.unresolvable, .addFile)])), contains: "evidence")
    }

    func testAnUnreadableACLRefusesAndNamesTheComponent() {
        guard let refusal = evaluate(leafACL(.unreadable)) else { return XCTFail("an unreadable ACL was accepted") }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason)
        XCTAssertTrue(refusal.reason.contains("ACL"), refusal.reason)
        XCTAssertTrue(refusal.reason.contains("evidence"), refusal.reason)
        XCTAssertFalse(refusal.reason.contains("/Users/me"), refusal.reason)
    }

    // MARK: accepted

    func testNoACLIsAccepted() {
        XCTAssertNil(evaluate(leafACL(.none)))
        XCTAssertNil(evaluate(leafACL(.entries([]))))
    }

    func testEveryMutatingRightForTheCurrentUserIsAccepted() {
        let rights: RecordingACLRights = [.addFile, .addSubdirectory, .deleteChild, .delete, .writeData, .append, .writeSecurity, .changeOwner]
        XCTAssertNil(evaluate(leafACL(.entries([allow(.user(me), rights)]))))
    }

    func testAUserWhoseUidOnlyDiffersByOneIsNotTheCurrentUser() {
        XCTAssertNotNil(evaluate(leafACL(.entries([allow(.user(me + 1), .addFile)]))))
        XCTAssertNotNil(evaluate(leafACL(.entries([allow(.group(me), .addFile)]))), "a GROUP whose number equals my uid is not me")
    }

    func testDenyOnlyACLsAreAccepted() {
        let everything: RecordingACLRights = [.addFile, .addSubdirectory, .deleteChild, .delete, .writeData, .append, .writeSecurity, .changeOwner]
        XCTAssertNil(evaluate(leafACL(.entries([deny(.group(12), everything), deny(.user(stranger), everything), deny(.unresolvable, .delete)]))))
    }

    func testTheHomeFolderACLGroupEveryoneDenyDeleteIsAccepted() {
        XCTAssertNil(evaluate(leafACL(.entries([deny(.group(12), .delete)]))))
    }

    func testBenignRightsOnlyAreAcceptedForAnyone() {
        let benign: RecordingACLRights = [.readData, .listDirectory, .search, .execute, .readAttributes, .readExtAttributes, .readSecurity, .synchronize]
        XCTAssertNil(evaluate(leafACL(.entries([allow(.group(12), benign), allow(.user(stranger), benign), allow(.unresolvable, benign)]))))
        XCTAssertNil(evaluate(leafACL(.entries([allow(.group(12), [])]))), "an entry with only inherit flags carries no rights")
    }

    // MARK: ancestors

    func testAPermissiveACLOnAnAncestorRefusesAndNamesTheAncestor() {
        for ancestor in ["/", "/Users", "/Users/me"] {
            let reader = ACLTestReader(byPath: [ancestor: .entries([allow(.group(12), [.addFile, .addSubdirectory, .deleteChild])])])
            guard let refusal = evaluate(reader) else { XCTFail("an ACL on \(ancestor) was accepted"); continue }
            XCTAssertTrue(refusal.reason.contains("ancestor"), refusal.reason)
            XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
            XCTAssertFalse(refusal.reason.contains("/Users/me"), refusal.reason)
        }
        let named = ACLTestReader(byPath: ["/Users/me": .entries([allow(.user(stranger), .deleteChild)])])
        XCTAssertTrue(evaluate(named)?.reason.contains("ancestor me") ?? false)
    }

    func testAnUnreadableACLOnAnAncestorRefuses() {
        let refusal = evaluate(ACLTestReader(byPath: ["/Users": .unreadable]))
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.reason.contains("ancestor Users") ?? false, refusal?.reason ?? "")
    }

    func testTheHomeFolderACLOnAnAncestorIsAccepted() {
        XCTAssertNil(evaluate(ACLTestReader(byPath: ["/Users/me": .entries([deny(.group(12), .delete)])])))
    }

    func testEveryComponentOfTheChainIsAskedExactlyOnce() {
        final class Recorder: RecordingACLReading {
            var asked: [String] = []
            func read(path: String) -> RecordingACLRead { asked.append(path); return .none }
        }
        let recorder = Recorder()
        let table = modes()
        XCTAssertNil(RecordingParentTrust.evaluate(resolvedParent: leaf, effectiveUID: me, lstat: { table[$0] }, acl: recorder))
        XCTAssertEqual(Set(recorder.asked), Set(["/", "/Users", "/Users/me", leaf]))
        XCTAssertEqual(recorder.asked.count, 4)
    }

    func testCheckPassesTheReaderThrough() {
        let table = modes()
        let reader = leafACL(.entries([allow(.group(12), .addFile)]))
        let result = RecordingParentTrust.check(parent: leaf, effectiveUID: me, resolve: { $0 }, lstat: { table[$0] }, acl: reader)
        guard case .failure(let refusal) = result else { return XCTFail("check ignored the ACL reader") }
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
    }
}

final class RecordingACLClaimTests: XCTestCase {
    func parent(_ label: String) -> String { SlotFS.freshDirectory(label) }

    func testAPermissiveACLOnTheFreshWorkDirectoryIsRefusedAndOnlyOurDirectoryIsRemoved() throws {
        let dir = parent("acl-work")
        // something that is not ours sits in the parent: it must be left exactly as it is
        XCTAssertTrue(FileManager.default.createFile(atPath: dir + "/precious.txt", contents: Data("keep".utf8)))
        XCTAssertEqual(mkdir(dir + "/someone-elses-folder", 0o700), 0)
        let reader = ACLTestReader(workDirectory: .entries([allow(.group(12), [.addFile, .addSubdirectory, .deleteChild])]))
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: dir + "/out.mov", aclReader: reader) else {
            return XCTFail("a work directory with a permissive inherited ACL was claimed")
        }
        XCTAssertTrue(refusal.reason.hasPrefix("the output folder is not private to you ("), refusal.reason)
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
        XCTAssertFalse(refusal.reason.contains(dir), "no path in the message")
        XCTAssertEqual(SlotFS.names(in: dir).sorted(), ["precious.txt", "someone-elses-folder"], "our work directory is gone, nothing else is touched")
        XCTAssertEqual(try String(contentsOfFile: dir + "/precious.txt", encoding: .utf8), "keep")
        // the claim was released: a later claim with a clean reader works
        let slot = try RecordingSlot.claim(finalPath: dir + "/out.mov", aclReader: ACLTestReader()).get()
        XCTAssertEqual((slot.workDirectoryPath as NSString).deletingLastPathComponent, dir)
    }

    func testAnUnreadableACLOnTheWorkDirectoryIsRefusedToo() {
        let dir = parent("acl-work-unreadable")
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: dir + "/out.mov", aclReader: ACLTestReader(workDirectory: .unreadable)) else {
            return XCTFail("an unreadable ACL on the work directory was accepted")
        }
        XCTAssertTrue(refusal.reason.contains("ACL"), refusal.reason)
        XCTAssertEqual(SlotFS.names(in: dir), [])
    }

    func testABenignOrDenyOnlyACLOnTheWorkDirectoryIsAccepted() throws {
        let dir = parent("acl-work-benign")
        let reader = ACLTestReader(workDirectory: .entries([deny(.group(12), .delete), allow(.group(12), [.readData, .search])]))
        let slot = try RecordingSlot.claim(finalPath: dir + "/out.mov", aclReader: reader).get()
        XCTAssertTrue(SlotFS.isDirectory(slot.workDirectoryPath))
    }

    func testAPermissiveACLOnAnAncestorIsRefusedByClaimAndNothingIsCreated() {
        let outer = parent("acl-anc-outer")
        let inner = outer + "/inner"
        XCTAssertEqual(mkdir(inner, 0o700), 0)
        let reader = ACLTestReader(byPath: [outer: .entries([allow(.user(UInt32(geteuid()) &+ 1), .deleteChild)])])
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: inner + "/out.mov", aclReader: reader) else {
            return XCTFail("a permissive ACL on an ancestor was accepted")
        }
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
        XCTAssertEqual(SlotFS.names(in: inner), [])
    }

    func testAPermissiveACLOnTheOutputFolderItselfIsRefusedByClaimAndNothingIsCreated() {
        let dir = parent("acl-parent")
        let reader = ACLTestReader(byPath: [dir: .entries([allow(.group(12), .addFile)])])
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: dir + "/out.mov", aclReader: reader) else {
            return XCTFail("a permissive ACL on the output folder was accepted")
        }
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
        XCTAssertEqual(SlotFS.names(in: dir), [])
    }
}

#if os(macOS)
/// The real thing: a real ACL set with /bin/chmod on a directory this test creates under NSTemporaryDirectory() and removes again.
final class RecordingACLRealTests: XCTestCase {
    private var made: [String] = []

    override func tearDown() {
        // Only the directories this test made; rmdir refuses anything that is not empty.
        for path in made.reversed() {
            _ = runChmod(["-N", path])
            _ = rmdir(path)
        }
        made = []
        super.tearDown()
    }

    @discardableResult
    private func runChmod(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func freshDirectory() -> String {
        let path = SlotFS.resolved(NSTemporaryDirectory()) + "/shep-acl-\(UUID().uuidString)"
        XCTAssertEqual(mkdir(path, 0o700), 0, path)
        made.append(path)
        XCTAssertEqual(chmod(path, 0o755), 0, path)
        return path
    }

    private func evaluate(_ path: String) -> RecordingSlotRefusal? {
        RecordingParentTrust.evaluate(resolvedParent: path, effectiveUID: UInt32(geteuid()), lstat: RecordingParentTrust.realLstat,
                                      acl: RecordingRealACLReader())
    }

    func testAPlainDirectoryHasNoACL() {
        let path = freshDirectory()
        guard case .none = RecordingRealACLReader().read(path: path) else { return XCTFail("a fresh directory reported an ACL") }
        XCTAssertNil(evaluate(path))
    }

    func testGroupEveryoneAllowAddFileIsReportedRefusedAndAcceptedAgainAfterChmodN() {
        let path = freshDirectory()
        XCTAssertEqual(runChmod(["+a", "group:everyone allow add_file,add_subdirectory,delete_child", path]), 0)
        guard case .entries(let entries) = RecordingRealACLReader().read(path: path) else { return XCTFail("the real reader did not report the ACL") }
        let grant = entries.first { $0.allow && $0.rights.contains(.addFile) && $0.rights.contains(.addSubdirectory) && $0.rights.contains(.deleteChild) }
        XCTAssertNotNil(grant, "an allow entry with add_file, add_subdirectory and delete_child")
        if let grant = grant, case .group = grant.principal {} else { XCTFail("group:everyone resolves to a group") }
        let refusal = evaluate(path)
        XCTAssertNotNil(refusal, "the trust check accepted a folder an ACL opens to everyone")
        XCTAssertTrue(refusal?.reason.contains("an ACL lets another user change it") ?? false, refusal?.reason ?? "")
        XCTAssertFalse(refusal?.reason.contains(path) ?? true, "no path in the message")
        XCTAssertEqual(runChmod(["-N", path]), 0)
        XCTAssertNil(evaluate(path), "after chmod -N the folder is accepted")
    }

    func testTheBenignHomeFolderACLGroupEveryoneDenyDeleteStaysAccepted() {
        let path = freshDirectory()
        XCTAssertEqual(runChmod(["+a", "group:everyone deny delete", path]), 0)
        guard case .entries(let entries) = readACL(path) else { return XCTFail("the real reader did not report the deny ACL") }
        XCTAssertTrue(entries.contains { !$0.allow && $0.rights.contains(.delete) })
        XCTAssertNil(evaluate(path))
    }

    func testAnACLGrantedToTheCurrentUserIsAccepted() {
        let path = freshDirectory()
        let name = NSUserName()
        XCTAssertEqual(runChmod(["+a", "user:\(name) allow add_file,delete_child", path]), 0)
        guard case .entries = readACL(path) else { return XCTFail("the real reader did not report the ACL") }
        XCTAssertNil(evaluate(path))
    }

    func testClaimRefusesARealPermissiveACLAndLeavesTheFolderEmpty() {
        let path = freshDirectory()
        XCTAssertEqual(runChmod(["+a", "group:everyone allow add_file,add_subdirectory,delete_child", path]), 0)
        guard case .failure(let refusal) = RecordingSlot.claim(finalPath: path + "/out.mov") else { return XCTFail("claimed in a folder an ACL opens up") }
        XCTAssertTrue(refusal.reason.contains("an ACL lets another user change it"), refusal.reason)
        XCTAssertEqual(SlotFS.names(in: path), [])
    }

    private func readACL(_ path: String) -> RecordingACLRead { RecordingRealACLReader().read(path: path) }
}
#endif
