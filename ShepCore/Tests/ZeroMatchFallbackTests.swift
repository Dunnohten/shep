import CoreGraphics
import XCTest
@testable import ShepCore

/// Code review F1: a screenshot-only pick whose spot has nothing nameable, for a request that shares no word with any listed
/// control. Before, the listed fallback was empty and the walk ended in a bare "I can't identify what is under that spot".
/// Now the walk offers the ranking's best listed controls (each with its own card; ClickGuard still checks every click), and
/// when nothing is ranked it asks the person to say it another way.
final class ZeroMatchFallbackTests: XCTestCase {
    /// No listed control in Run1Above shares a word or a synonym with this request.
    static let request = "poke the little creature"

    private func run(axControls: [Control] = Run1Above.controls(), request: String = ZeroMatchFallbackTests.request) async -> FixScreenResult {
        let found = [LocatedControl(name: "little creature", role: "", box: Run1Above.pickBox, score: 0.5)]
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A torrent window.", controls: found, targetBox: Run1Above.pickBox))
        let input = VisionInput(png: Data([1]), geometry: Run1Above.geometry, axControls: axControls, bundleID: Run1Above.bundle,
                                windowTitle: "Transmission", request: request)
        return await FixScreenPipeline(provider: provider, picker: FakePicker(result: PickResult(marks: [])), preparer: FakePreparer(result: nil)).run(input)
    }

    private func refusal(_ r: FixScreenResult) -> ProposalFallbackStep? {
        guard let p = r.proposals.first else { return nil }
        return ProposalFallback.step(after: .refused(ClickGuard.unidentified), of: p, fallback: r.fallbackProposals, ranked: r.fallbackRanked)
    }

    func testTheRequestReallySharesNoWordWithAListedControl() {
        let listed = Run1Above.controls()
        let ranked = ProposalRanker.rank(listed, request: Self.request, bundleID: Run1Above.bundle, window: Run1Above.window)
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertTrue(ranked.allSatisfy { $0.matchScore == 0 })
    }

    func testTheScreenshotPickStandsAndCarriesARankedFallback() async {
        let r = await run()
        XCTAssertEqual(r.proposals.count, 1)
        XCTAssertEqual(r.proposals.first?.action.control.fromVision, true)
        XCTAssertFalse(r.fallbackProposals.isEmpty, "zero word matches still leave the ranking's listed controls")
        XCTAssertLessThanOrEqual(r.fallbackProposals.count, FixScreenPipeline.maxProposals)
        XCTAssertTrue(r.fallbackProposals.allSatisfy { !$0.action.control.fromVision }, "listed controls only")
        XCTAssertTrue(r.fallbackRanked)
        XCTAssertEqual(r.trace.fallbackCount, r.fallbackProposals.count)
    }

    func testTheRankedFallbackIsTheRankingsOwnOrderAndPolicyChecked() async {
        let r = await run()
        let ranked = ProposalRanker.rank(Run1Above.controls(), request: Self.request, bundleID: Run1Above.bundle, window: Run1Above.window)
        let expected = ranked.map(\.control.index).prefix(FixScreenPipeline.maxProposals)
        XCTAssertEqual(r.fallbackProposals.map(\.action.control.index), Array(expected))
        for p in r.fallbackProposals {
            if case .refused = p.requirement { XCTFail("a refused control is never offered") }
            XCTAssertTrue(p.action.control.enabled)
        }
    }

    func testAnUnidentifiedSpotOffersTheChooserWithItsOwnIntro() async {
        let r = await run()
        guard case .offer(let listed, let intro)? = refusal(r) else { return XCTFail("expected the ranked chooser, got \(String(describing: refusal(r)))") }
        XCTAssertEqual(listed, r.fallbackProposals)
        XCTAssertEqual(intro, ProposalFallback.chooserIntro)
    }

    func testWithNothingRankedTheWalkAsksToRephrase() async {
        let r = await run(axControls: [])
        XCTAssertEqual(r.proposals.first?.action.control.fromVision, true)
        XCTAssertTrue(r.fallbackProposals.isEmpty)
        XCTAssertEqual(refusal(r), .rephrase(ProposalFallback.rephrasePrompt))
    }

    func testAWordMatchedFallbackHasNoChooserIntro() async {
        // Run1Above's "set the turtle limit": "limit" matches the checkbox, so the fallback is word-matched, as before.
        let found = [LocatedControl(name: "turtle", role: "", box: Run1Above.pickBox, score: 0.5)]
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: found, targetBox: Run1Above.pickBox))
        let r = await FixScreenPipeline(provider: provider, picker: FakePicker(result: PickResult(marks: [])), preparer: FakePreparer(result: nil))
            .run(Run1Above.input(request: "set the turtle limit"))
        XCTAssertFalse(r.fallbackRanked)
        guard case .offer(let listed, let intro)? = refusal(r) else { return XCTFail("expected the word-matched fallback") }
        XCTAssertEqual(listed.map(\.action.control.index), [16])
        XCTAssertNil(intro)
    }

    func testOtherOutcomesAndListedProposalsGoOnAsBefore() async {
        let r = await run()
        guard let p = r.proposals.first, let listed = r.fallbackProposals.first else { return XCTFail("fixture") }
        XCTAssertNil(ProposalFallback.step(after: .declined, of: p, fallback: r.fallbackProposals, ranked: true))
        XCTAssertNil(ProposalFallback.step(after: .refused("Shep never presses that."), of: p, fallback: r.fallbackProposals, ranked: true))
        XCTAssertNil(ProposalFallback.step(after: .refused(ClickGuard.unidentified), of: listed, fallback: r.fallbackProposals, ranked: true),
                     "a listed control is not replaced")
    }

    func testTheWordsAreFixedPlainAndCarryNoRequestText() {
        XCTAssertEqual(ProposalFallback.rephrasePrompt, "I couldn't tell which control you mean. Can you say it another way, e.g. its label?")
        XCTAssertEqual(ProposalFallback.chooserIntro, "I couldn't tell which control you mean from the screenshot. Here are the closest ones I can name; approve the one you want.")
        XCTAssertEqual(LiveLog.fallbackToRanked, "[shep] live: fallback: nothing nameable under the spot found on the screenshot; no listed word match, offering the ranked control(s) the app lists")
        XCTAssertEqual(LiveLog.fallbackRephrase, "[shep] live: fallback: nothing nameable under the spot found on the screenshot and nothing listed to offer; asked to rephrase")
    }
}
