import XCTest
@testable import ShepCore

/// Code review F3: each focus candidate (the system-wide focused element, then the front app's own) is queried, its owner checked,
/// its window resolved and that window's owner checked; any failure moves on to the next candidate.
final class FocusedWindowResolverTests: XCTestCase {
    private let front: Int32 = 400

    /// Elements are names. `focused` answers per candidate, `owners` gives a pid (missing: the read failed),
    /// `windows` maps an element to its AXWindow; names starting with "win" are windows themselves.
    private struct FakeReader: FocusedElementReading {
        var focused: [FocusCandidate: String] = [:]
        var owners: [String: Int32] = [:]
        var windows: [String: String] = [:]
        func focusedElement(from candidate: FocusCandidate) -> String? { focused[candidate] }
        func ownerPID(of element: String) -> Int32? { owners[element] }
        func isWindow(_ element: String) -> Bool { element.hasPrefix("win") }
        func window(of element: String) -> String? { windows[element] }
    }

    private func resolve(_ r: FakeReader) -> FocusedWindowResolution<String> {
        FocusedWindowResolver.resolve(frontPID: front, reader: r)
    }

    func testTheSystemElementWinsWhenItIsValid() {
        let r = FakeReader(focused: [.system: "field", .app: "other"], owners: ["field": front, "winA": front, "other": front],
                           windows: ["field": "winA", "other": "winB"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .system)
        XCTAssertEqual(res.failures, [])
    }

    func testAForeignSystemElementFallsBackToTheAppElement() {
        let r = FakeReader(focused: [.system: "foreign", .app: "field"], owners: ["foreign": 999, "field": front, "winA": front],
                           windows: ["foreign": "winX", "field": "winA"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .app)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .foreignOwner)])
    }

    func testAFailedPidReadFallsBackToTheAppElement() {
        let r = FakeReader(focused: [.system: "mute", .app: "field"], owners: ["field": front, "winA": front],
                           windows: ["mute": "winX", "field": "winA"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .app)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .ownerUnavailable)])
    }

    func testASystemElementWithNoWindowFallsBackToTheAppElement() {
        let r = FakeReader(focused: [.system: "orphan", .app: "field"], owners: ["orphan": front, "field": front, "winA": front],
                           windows: ["field": "winA"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .app)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .windowUnavailable)])
    }

    func testAWindowOwnedByAnotherPidIsRejectedAndTheAppElementTried() {
        let r = FakeReader(focused: [.system: "field", .app: "field2"],
                           owners: ["field": front, "winForeign": 999, "field2": front, "winA": front],
                           windows: ["field": "winForeign", "field2": "winA"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .app)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .windowForeignOwner)])
    }

    func testAWindowWhoseOwnerCannotBeReadIsRejected() {
        let r = FakeReader(focused: [.app: "field"], owners: ["field": front], windows: ["field": "winA"])
        let res = resolve(r)
        XCTAssertNil(res.window)
        XCTAssertNil(res.candidate)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .focusedElementUnavailable), FocusAttemptFailure(.app, .windowForeignOwner)])
    }

    func testAMissingSystemElementFallsBackToTheAppElement() {
        let r = FakeReader(focused: [.app: "field"], owners: ["field": front, "winA": front], windows: ["field": "winA"])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .app)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .focusedElementUnavailable)])
    }

    func testAFocusedWindowIsItsOwnWindow() {
        let r = FakeReader(focused: [.system: "winA"], owners: ["winA": front])
        let res = resolve(r)
        XCTAssertEqual(res.window, "winA")
        XCTAssertEqual(res.candidate, .system)
    }

    func testEveryCandidateFailingGivesNoWindowAndBothReasons() {
        let r = FakeReader(focused: [.system: "foreign", .app: "orphan"], owners: ["foreign": 999, "orphan": front])
        let res = resolve(r)
        XCTAssertNil(res.window)
        XCTAssertNil(res.candidate)
        XCTAssertEqual(res.failures, [FocusAttemptFailure(.system, .foreignOwner), FocusAttemptFailure(.app, .windowUnavailable)])
    }

    func testTheForeignWindowIsNeverReturnedEvenWhenItIsTheOnlyAnswer() {
        let r = FakeReader(focused: [.system: "field"], owners: ["field": front, "winForeign": 999], windows: ["field": "winForeign"])
        XCTAssertNil(resolve(r).window)
    }

    func testTheCandidatesAreTriedSystemFirst() {
        XCTAssertEqual(FocusCandidate.allCases, [.system, .app])
    }
}
