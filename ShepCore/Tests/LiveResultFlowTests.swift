import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of d8213e1 (the suspended provider): the coordinator's whole post-await sequence runs through
// `LiveResultFlow.afterProvider`. The provider is a closure the test suspends on a continuation; the test latches "left" while it is
// suspended, resumes it, and asserts that nothing was kept, dumped or offered. The same scenario against the OLD order (pre-4c64b5a:
// keep the answer, write the trace, only then look at the gate) shows what the old code did, which is why this test exists.
// This strengthens the gate-only checks in LiveRunGateTests, which could not tell the two orders apart.

final class FlowLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// The coordinator as it was before 4c64b5a: the answer is kept and the trace is written BEFORE the gate is looked at.
enum LegacyResultOrder {
    @MainActor
    static func afterProvider<R>(gate: LiveRunGate, produce: () async -> R, keep: (R) -> Void, dump: (R) -> Void, offer: (R) async -> Void) async {
        let result = await produce()
        keep(result)
        dump(result)
        if gate.isLeft { return }
        await offer(result)
    }
}

final class LiveResultFlowTests: XCTestCase {
    typealias Flow = @MainActor (LiveRunGate, () async -> String, (String) -> Void, (String) -> Void, (String) async -> Void) async -> Void

    /// The scenario: the provider suspends, the target leaves meanwhile, the provider answers. Returns what happened, in order.
    @MainActor
    private func leftWhileSuspended(_ flow: @escaping Flow) async -> [String] {
        let gate = LiveRunGate()
        let provider = Suspender()
        let log = FlowLog()
        let task = Task { @MainActor in
            await flow(gate, { log.add("provider-called"); await provider.suspend(); log.add("provider-answered"); return "answer" },
                       { _ in log.add("kept") }, { _ in log.add("dumped") }, { _ in log.add("offered") })
        }
        let parked = await provider.waitUntilParked()
        XCTAssertTrue(parked, "the provider must be suspended before the target leaves")
        XCTAssertEqual(log.events, ["provider-called"])
        gate.latchLeft()
        provider.resume()
        await task.value
        return log.events
    }

    @MainActor
    func testATargetThatLeavesWhileTheProviderIsSuspendedGetsNothingKeptDumpedOrOffered() async {
        let events = await leftWhileSuspended { gate, produce, keep, dump, offer in
            await LiveResultFlow.afterProvider(gate: gate, produce: produce, keep: keep, dump: dump, offer: offer)
        }
        XCTAssertEqual(events, ["provider-called", "provider-answered"], "after the answer: no keep, no trace dump, no card")
    }

    @MainActor
    func testTheSameScenarioOnTheOldOrderKeptTheAnswerAndWroteTheDump() async {
        let events = await leftWhileSuspended { gate, produce, keep, dump, offer in
            await LegacyResultOrder.afterProvider(gate: gate, produce: produce, keep: keep, dump: dump, offer: offer)
        }
        XCTAssertEqual(events, ["provider-called", "provider-answered", "kept", "dumped"],
                       "the old order wrote the trace for a result that arrived after the target left: the test above fails on it")
    }

    @MainActor
    func testWithoutADepartureTheResultIsKeptDumpedThenOffered() async {
        let gate = LiveRunGate()
        let log = FlowLog()
        await LiveResultFlow.afterProvider(gate: gate, produce: { "answer" }, keep: { _ in log.add("kept") }, dump: { _ in log.add("dumped") },
                                           offer: { _ in log.add("offered") })
        XCTAssertEqual(log.events, ["kept", "dumped", "offered"])
    }

    @MainActor
    func testADepartureBeforeTheProviderIsCalledStillDropsTheResult() async {
        let gate = LiveRunGate()
        gate.latchLeft()
        let log = FlowLog()
        await LiveResultFlow.afterProvider(gate: gate, produce: { "answer" }, keep: { _ in log.add("kept") }, dump: { _ in log.add("dumped") },
                                           offer: { _ in log.add("offered") })
        XCTAssertEqual(log.events, [])
    }

    @MainActor
    func testADepartureDuringTheOfferIsTheOffersToHandle() async {
        // The flow looks at the gate once, right after the await; what the offer does afterwards (the card, the walk) has its own checks.
        let gate = LiveRunGate()
        let log = FlowLog()
        await LiveResultFlow.afterProvider(gate: gate, produce: { "answer" }, keep: { _ in log.add("kept") }, dump: { _ in log.add("dumped") },
                                           offer: { _ in gate.latchLeft(); log.add("offered") })
        XCTAssertEqual(log.events, ["kept", "dumped", "offered"])
    }
}
