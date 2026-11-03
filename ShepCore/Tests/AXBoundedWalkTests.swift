import CoreGraphics
import XCTest
@testable import ShepCore

/// A node whose children are made on demand and counted, so a test can see how much work the walker asked for.
final class WalkCounter {
    var made = 0
    var wholeListCalls = 0
    var limitedCalls = 0
    var deepestFetch = -1
}

struct CountingNode: AXNodeSource {
    let counter: WalkCounter
    let depth: Int
    /// Children this node would have if asked for all of them.
    let width: Int
    /// Width of the nodes below the first level.
    let childWidth: Int
    var role: String { depth == 0 ? "AXWindow" : (width > 0 ? "AXGroup" : "AXButton") }
    var subrole: String { "" }
    var title: String { "" }
    var descriptionText: String { "" }
    var help: String { "" }
    var valueText: String? { nil }
    var frame: CGRect? { CGRect(x: 0, y: 0, width: 20, height: 20) }
    var isEnabled: Bool { true }
    var actions: [String] { [] }

    func make(_ n: Int) -> [CountingNode] {
        counter.made += n
        return (0..<n).map { _ in CountingNode(counter: counter, depth: depth + 1, width: depth == 0 ? childWidth : 0, childWidth: 0) }
    }

    func children() -> [CountingNode] {
        counter.wholeListCalls += 1
        counter.deepestFetch = max(counter.deepestFetch, depth)
        return make(width)
    }

    func children(limit: Int) -> [CountingNode] {
        counter.limitedCalls += 1
        counter.deepestFetch = max(counter.deepestFetch, depth)
        return make(min(max(0, limit), width))
    }
}

/// A chain: every node has one child, down to `length` levels.
struct ChainNode: AXNodeSource {
    let counter: WalkCounter
    let depth: Int
    let length: Int
    var role: String { depth == 0 ? "AXWindow" : "AXGroup" }
    var subrole: String { "" }
    var title: String { "" }
    var descriptionText: String { "" }
    var help: String { "" }
    var valueText: String? { nil }
    var frame: CGRect? { CGRect(x: 0, y: 0, width: 20, height: 20) }
    var isEnabled: Bool { true }
    var actions: [String] { [] }
    func children() -> [ChainNode] {
        counter.wholeListCalls += 1
        counter.deepestFetch = max(counter.deepestFetch, depth)
        return depth + 1 < length ? [ChainNode(counter: counter, depth: depth + 1, length: length)] : []
    }
    func children(limit: Int) -> [ChainNode] {
        counter.limitedCalls += 1
        counter.deepestFetch = max(counter.deepestFetch, depth)
        return limit > 0 ? children() : []
    }
}

final class AXBoundedWalkTests: XCTestCase {
    func walk<N: AXNodeSource>(_ root: N, limits: AXWalkLimits, clock: @escaping () -> TimeInterval = { 0 }) -> AXWalkResult<N> {
        AXTreeWalker.walk(root: root, rootPath: "0", windowTitle: "W", windowSubrole: "AXStandardWindow", budget: AXWalkBudget(limits: limits, clock: clock))
    }

    func testAWindowWithAHundredThousandChildrenCostsAtMostTheBudget() {
        let counter = WalkCounter()
        let root = CountingNode(counter: counter, depth: 0, width: 100_000, childWidth: 0)
        let result = walk(root, limits: .labelScan)
        XCTAssertLessThanOrEqual(counter.made, AXWalkLimits.labelScan.maxChildrenPerNode + 1, "children made")
        XCTAssertLessThanOrEqual(result.nodes.count, AXWalkLimits.labelScan.maxNodes)
        XCTAssertEqual(counter.wholeListCalls, 0, "the whole list is never asked for")
        XCTAssertTrue(result.truncated, "a cut list is a partial read")
    }

    func testTheNodeBudgetBoundsWhatIsFetchedEvenWithoutAPerNodeCap() {
        let counter = WalkCounter()
        let root = CountingNode(counter: counter, depth: 0, width: 100_000, childWidth: 0)
        let limits = AXWalkLimits(maxDepth: 30, maxNodes: 50, timeBudget: 2, maxChildrenPerNode: 100_000)
        let result = walk(root, limits: limits)
        XCTAssertLessThanOrEqual(counter.made, 51)
        XCTAssertLessThanOrEqual(result.nodes.count, 50)
        XCTAssertTrue(result.truncated)
    }

    func testManyWideNodesTogetherStayWithinTheBudget() {
        let counter = WalkCounter()
        let root = CountingNode(counter: counter, depth: 0, width: 200, childWidth: 100_000)
        let limits = AXWalkLimits(maxDepth: 30, maxNodes: 1500, timeBudget: 2, maxChildrenPerNode: 300)
        let result = walk(root, limits: limits)
        XCTAssertLessThanOrEqual(result.nodes.count, 1500)
        XCTAssertLessThanOrEqual(counter.made, 1500 + 400 + 1, "made \(counter.made)")
        XCTAssertTrue(result.truncated)
    }

    func testNothingIsFetchedFromANodeAtTheDepthCap() {
        let counter = WalkCounter()
        let limits = AXWalkLimits(maxDepth: 5, maxNodes: 1500, timeBudget: 2)
        let result = walk(ChainNode(counter: counter, depth: 0, length: 40), limits: limits)
        XCTAssertEqual(counter.deepestFetch, 4, "the node at depth 5 is never asked for its children")
        XCTAssertEqual(result.nodes.count, 6)
        XCTAssertTrue(result.depthCut, "it is still reported as cut")
        XCTAssertFalse(result.truncated)
    }

    func testAShortChainIsNotReportedCut() {
        let counter = WalkCounter()
        let result = walk(ChainNode(counter: counter, depth: 0, length: 3), limits: AXWalkLimits(maxDepth: 5, maxNodes: 100, timeBudget: 2))
        XCTAssertFalse(result.depthCut)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.nodes.count, 3)
    }

    func testTheDeadlineIsCheckedBeforeEveryFetch() {
        let counter = WalkCounter()
        var now: TimeInterval = 0
        let root = CountingNode(counter: counter, depth: 0, width: 1000, childWidth: 1000)
        // Each look at the clock costs half a second: the 2 s budget is gone after a few nodes.
        let result = walk(root, limits: .labelScan, clock: { now += 0.5; return now })
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(counter.limitedCalls, 6, "fetches after the deadline: \(counter.limitedCalls)")
        XCTAssertLessThan(result.nodes.count, 400)
    }

    func testTheDefaultLimitedFetchCutsTheWholeList() {
        let node = FakeAX(role: "AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 50, height: 50),
                          kids: (0..<10).map { FakeAX(role: "AXButton", title: "b\($0)", frame: CGRect(x: 0, y: 0, width: 5, height: 5)) })
        XCTAssertEqual(node.children(limit: 3).count, 3)
        XCTAssertEqual(node.children(limit: 0).count, 0)
        XCTAssertEqual(node.children(limit: -4).count, 0)
        XCTAssertEqual(node.children(limit: 99).count, 10)
    }

    func testTheLabelScanAndStandardLimitsKeepTheirOldCaps() {
        XCTAssertEqual(AXWalkLimits.standard, AXWalkLimits(maxDepth: 8, maxNodes: 400, timeBudget: 2.0))
        XCTAssertEqual(AXWalkLimits.labelScan.maxDepth, 30)
        XCTAssertEqual(AXWalkLimits.labelScan.maxNodes, 1500)
        XCTAssertEqual(AXWalkLimits.labelScan.maxChildrenPerNode, 300)
    }
}
