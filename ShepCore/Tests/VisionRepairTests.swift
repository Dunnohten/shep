import CoreGraphics
import XCTest
// Provenance: written on 2026-10-26 at about 11:44 AM CT (after the 11:00 AM CT start of the hackathon) on the author's earlier
// working branch for this same hackathon, reviewed at 11:52 AM CT, and carried into this repository.
@testable import ShepCore

/// Meta hackathon: screenshot -> SAM regions -> screen points -> Muse names -> merge with the AX list -> numbered speech.
final class VisionRepairTests: XCTestCase {
    /// A stand-in for SAM + Muse that records what it was asked.
    final class StubVision: MetaVisioning, @unchecked Sendable {
        var regions: [String: [SAMRegion]]
        var labels: [Int: MuseLabel]
        var failSegment: Set<String> = []
        var failNames = false
        var segmentCalls: [String] = []
        var nameCalls = 0
        init(regions: [String: [SAMRegion]] = [:], labels: [Int: MuseLabel] = [:]) { self.regions = regions; self.labels = labels }
        func segment(png: Data, imageSize: CGSize, concept: String) async throws -> [SAMRegion] {
            segmentCalls.append(concept)
            if failSegment.contains(concept) { throw MetaError.http(503, "busy") }
            return regions[concept] ?? []
        }
        func name(png: Data, candidates: [VisionCandidate], request: String?) async throws -> [Int: MuseLabel] {
            nameCalls += 1
            if failNames { throw MetaError.malformed("garbage") }
            return labels
        }
    }

    /// A 400x300 pt window at (100, 50), captured on Retina: an 800x600 px PNG.
    let retina = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    func region(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ concept: String = "button", score: Double = 0.9) -> SAMRegion {
        SAMRegion(box: CGRect(x: x, y: y, width: w, height: h), score: score, concept: concept)
    }
    func ax(_ i: Int, _ title: String, frame: CGRect? = nil) -> Control {
        Control(index: i, role: "AXButton", title: title, window: "Inbox", value: nil, frame: frame)
    }

    // MARK: scale mapping

    func testRetinaPixelsMapToScreenPointsFromTheWindowOrigin() {
        let r = retina.screenRect(forPixels: CGRect(x: 200, y: 100, width: 80, height: 40))
        XCTAssertEqual(r, CGRect(x: 200, y: 100, width: 40, height: 20))   // 100 + 200/2, 50 + 100/2
        XCTAssertEqual(retina.scaleX, 2); XCTAssertEqual(retina.scaleY, 2)
    }

    func testNonRetinaAndMissingSizes() {
        let oneX = CaptureGeometry(windowFrame: CGRect(x: 0, y: 25, width: 400, height: 300), imageSize: CGSize(width: 400, height: 300), scale: 2)
        XCTAssertEqual(oneX.scaleX, 1, "the measured image size wins over the display's backing scale")
        XCTAssertEqual(oneX.screenRect(forPixels: CGRect(x: 10, y: 10, width: 20, height: 20)), CGRect(x: 10, y: 35, width: 20, height: 20))
        let unknown = CaptureGeometry(windowFrame: CGRect(x: 0, y: 0, width: 0, height: 0), imageSize: .zero, scale: 2)
        XCTAssertEqual(unknown.scaleX, 2)
        let bogus = CaptureGeometry(windowFrame: .zero, imageSize: .zero, scale: 0)
        XCTAssertEqual(bogus.scaleX, 1, "never divides by zero")
    }

    // MARK: IoU and de-dup

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(VisionRepair.iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(VisionRepair.iou(a, CGRect(x: 5, y: 0, width: 10, height: 10)), 50.0 / 150.0, accuracy: 1e-9)
        XCTAssertEqual(VisionRepair.iou(a, CGRect(x: 20, y: 20, width: 5, height: 5)), 0)
        XCTAssertEqual(VisionRepair.iou(a, CGRect(x: 10, y: 0, width: 5, height: 5)), 0, "touching edges don't overlap")
    }

    func testFoundControlsThatOverlapAnAXControlAreDropped() {
        // The AX "Send" button sits at screen (200,100,40,20) = pixels (200,100,80,40).
        let axList = [ax(1, "Send", frame: CGRect(x: 200, y: 100, width: 40, height: 20))]
        let c = VisionRepair.candidates(from: [region(204, 102, 80, 40), region(600, 100, 60, 60, "icon")], geometry: retina, ax: axList)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].concept, "icon")
        XCTAssertEqual(c[0].screenFrame, CGRect(x: 400, y: 100, width: 30, height: 30))
        XCTAssertEqual(c[0].center, CGPoint(x: 415, y: 115))
    }

    func testOverlappingRegionsFromTwoConceptsBecomeOneControlTheBestScoreWins() {
        let c = VisionRepair.candidates(from: [region(100, 100, 50, 50, "icon", score: 0.6), region(102, 101, 50, 50, "button", score: 0.95)],
                                        geometry: retina, ax: [])
        XCTAssertEqual(c.map(\.concept), ["button"])
    }

    func testReadingOrderTopToBottomThenLeftToRight() {
        let c = VisionRepair.candidates(from: [region(500, 300, 40, 40), region(100, 10, 40, 40), region(300, 14, 40, 40)], geometry: retina, ax: [])
        XCTAssertEqual(c.map { Int($0.pixelBox.minX) }, [100, 300, 500])
        XCTAssertEqual(c.map(\.id), [1, 2, 3])
    }

    func testTheNumberOfFoundControlsIsCapped() {
        let many = (0..<40).map { region(Double($0 % 8) * 90, Double($0 / 8) * 90, 60, 60, score: Double($0) / 40) }
        XCTAssertEqual(VisionRepair.candidates(from: many, geometry: retina, ax: []).count, VisionRepair.maxVisionControls)
    }

    // MARK: merge order and names

    func testMergeListsAppControlsFirstThenFoundOnesRenumbered() {
        let axList = [ax(7, "Reply"), ax(9, "Archive")]
        let found = VisionRepair.visionItems([VisionCandidate(id: 1, pixelBox: .zero, screenFrame: CGRect(x: 1, y: 2, width: 3, height: 4), concept: "icon", score: 1)],
                                             labels: [1: MuseLabel(id: 1, name: "Flag", role: "button")], window: "Inbox")
        let m = VisionRepair.merge(ax: axList, vision: found)
        XCTAssertEqual(m.map(\.index), [1, 2, 3])
        XCTAssertEqual(m.map(\.label), ["Reply", "Archive", "Flag"])
        XCTAssertEqual(m.map(\.fromVision), [false, false, true])
        XCTAssertEqual(m[2].frame, CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(m[2].role, "AXButton")
    }

    func testWithoutAXFramesAFoundControlWithTheSameNameIsADuplicate() {
        let found = [Control(index: 1, role: "AXButton", title: "reply", window: "", value: nil, frame: .zero, fromVision: true),
                     Control(index: 2, role: "AXButton", title: "Flag", window: "", value: nil, frame: .zero, fromVision: true)]
        XCTAssertEqual(VisionRepair.merge(ax: [ax(1, "Reply")], vision: found).map(\.label), ["Reply", "Flag"])
    }

    func testMissingOrUselessNamesBecomeUnlabeledConcept() {
        let c = [VisionCandidate(id: 1, pixelBox: .zero, screenFrame: .zero, concept: "icon", score: 1),
                 VisionCandidate(id: 2, pixelBox: .zero, screenFrame: .zero, concept: "text field", score: 1)]
        let items = VisionRepair.visionItems(c, labels: [1: MuseLabel(id: 1, name: "Unlabeled")], window: "")
        XCTAssertEqual(items.map(\.label), ["unlabeled icon", "unlabeled text field"])
        XCTAssertEqual(items[1].role, "AXTextField")
    }

    // MARK: the pipeline

    func testPipelineEndToEndWithStubbedModels() async {
        let stub = StubVision(regions: ["button": [region(600, 100, 60, 60)], "icon": [region(100, 400, 40, 40, "icon")]],
                              labels: [1: MuseLabel(id: 1, name: "Settings", role: "button"), 2: MuseLabel(id: 2, name: "Attach file")])
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [ax(4, "Send")], bundleID: "com.example.chat", window: "Inbox",
                                       request: "what's here", vision: stub, sendAllowed: true, concepts: ["button", "icon"])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.items.map(\.label), ["Send", "Settings", "Attach file"])
        XCTAssertEqual(r.visionCount, 2)
        XCTAssertEqual(stub.segmentCalls, ["button", "icon"])
        XCTAssertEqual(stub.nameCalls, 1)
    }

    func testFoundControlsShepNeverPressesAreLeftOut() async {
        let stub = StubVision(regions: ["button": [region(10, 10, 60, 30), region(300, 10, 60, 30)]],
                              labels: [1: MuseLabel(id: 1, name: "Buy now"), 2: MuseLabel(id: 2, name: "Zoom in")])
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [], bundleID: "com.example.shop", window: "",
                                       request: nil, vision: stub, sendAllowed: true, concepts: ["button"])
        XCTAssertEqual(r.items.map(\.label), ["Zoom in"])
        XCTAssertTrue(r.notes.contains { $0.contains("left out 1") })
    }

    func testMalformedMuseOutputStillListsTheControlsAsUnlabeled() async {
        let stub = StubVision(regions: ["icon": [region(10, 10, 40, 40, "icon")]])
        stub.failNames = true
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [], bundleID: "x", window: "", request: nil,
                                       vision: stub, sendAllowed: true, concepts: ["icon"])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.items.map(\.label), ["unlabeled icon"])
    }

    func testEmptyResultsKeepTheAXListAndCallNoNamer() async {
        let stub = StubVision()
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [ax(3, "OK")], bundleID: "x", window: "", request: nil,
                                       vision: stub, sendAllowed: true, concepts: ["button"])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.items.map(\.label), ["OK"])
        XCTAssertEqual(r.items.first?.index, 1)
        XCTAssertEqual(stub.nameCalls, 0)
    }

    func testEverySAMCallFailingIsAFailureWithTheAXListUnchanged() async {
        let stub = StubVision(); stub.failSegment = ["button", "icon"]
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [ax(1, "OK")], bundleID: "x", window: "", request: nil,
                                       vision: stub, sendAllowed: true, concepts: ["button", "icon"])
        guard case .failed = r.status else { return XCTFail("\(r.status)") }
        XCTAssertEqual(r.items.map(\.label), ["OK"])
    }

    func testNoKeyMeansNoVision() async {
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [ax(1, "OK")], bundleID: "x", window: "", request: nil,
                                       vision: nil, sendAllowed: true)
        guard case .failed = r.status else { return XCTFail("\(r.status)") }
    }

    // MARK: privacy

    func testScreenshotsAreNotSentUntilTheOwnerOptsIn() async {
        let suite = "VisionRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MetaVisionSettings.sendScreenshots(defaults), "default must be off")
        let stub = StubVision(regions: ["button": [region(10, 10, 40, 40)]])
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [], bundleID: "x", window: "", request: nil,
                                       vision: stub, sendAllowed: MetaVisionSettings.sendScreenshots(defaults))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertTrue(stub.segmentCalls.isEmpty, "nothing may be sent while the setting is off")
        XCTAssertEqual(stub.nameCalls, 0)
        MetaVisionSettings.setSendScreenshots(true, defaults)
        XCTAssertTrue(MetaVisionSettings.sendScreenshots(defaults))
    }

    func testSwitchingOffMidRepairStopsTheNextUpload() async {
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let stub = StubVision(regions: ["button": [region(10, 10, 40, 40)]])
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [], bundleID: "x", window: "", request: nil, vision: stub,
                                       allowed: { defer { flag.on = false }; return flag.on }, concepts: ["button", "icon"])
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(stub.segmentCalls, [], "the check before the first upload passed, then the owner switched it off")
    }

    func testMessagingMoneyPasswordAndCommandAppsAreNeverCaptured() async {
        for id in ["com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram", "com.hnc.Discord", "com.apple.MobileSMS", "com.apple.mail",
                   "com.1password.1password", "com.apple.Terminal", "com.apple.keychainaccess", ""] {
            XCTAssertFalse(MetaVisionSettings.mayCapture(bundleID: id), id)
        }
        XCTAssertTrue(MetaVisionSettings.mayCapture(bundleID: "com.apple.Maps"))
        let stub = StubVision(regions: ["button": [region(10, 10, 40, 40)]])
        let r = await VisionRepair.run(png: Data([1]), geometry: retina, ax: [], bundleID: "com.tinyspeck.slackmacgap", window: "",
                                       request: nil, vision: stub, sendAllowed: true, concepts: ["button"])
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertTrue(stub.segmentCalls.isEmpty)
    }

    func testReadingOrderIsDeterministicWithMixedHeights() {
        // Centres 10, 18, 26: a pairwise "within tolerance" sort could chain them; rows are built from the row's first one.
        let f = [CGRect(x: 300, y: 0, width: 20, height: 20), CGRect(x: 100, y: 8, width: 20, height: 20),
                 CGRect(x: 0, y: 16, width: 20, height: 20), CGRect(x: 50, y: 200, width: 20, height: 20)]
        let a = VisionRepair.readingOrder(f)
        XCTAssertEqual(a, VisionRepair.readingOrder(f))
        XCTAssertEqual(a, [1, 0, 2, 3], "row 1: centres 10 and 18 (by x); row 2: 26; row 3: 210")
    }

    func testTheStoredKeyNameIsPinned() {
        XCTAssertEqual(MetaVisionSettings.sendScreenshotsKey, "shep.meta.sendScreenshots")
    }

    // MARK: speech

    func testSpokenListAndSummary() {
        let items = [ax(1, "Send"), Control(index: 2, role: "AXButton", title: "Settings", window: "", value: nil, frame: .zero, fromVision: true)]
        XCTAssertEqual(VisionRepair.spokenList(items), "1: Send, button. 2: Settings, button, found on screen.")
        XCTAssertEqual(VisionRepair.spokenList(items, limit: 1), "1: Send, button. And 1 more.")
        XCTAssertEqual(VisionRepair.spokenList([]), "I can't find any controls I can use in this window.")
        XCTAssertEqual(VisionRepair.summary(items, appName: "Chat"), "Chat has 2 controls I can use, 1 of them found on the screen; say “press” and a number.")
        XCTAssertEqual(VisionRepair.summary([], appName: "Chat"), "I can't find any controls I can use in Chat.")
    }
}

/// Meta hackathon: a click on a control found by vision ALWAYS waits for approval (ported to Shep's ApprovalPolicy).
final class VisionApprovalGateTests: XCTestCase {
    let vision = Control(index: 1, role: "AXButton", title: "Zoom in", window: "Map",
                         frame: CGRect(x: 10, y: 10, width: 20, height: 20), fromVision: true)
    let axButton = Control(index: 1, role: "AXButton", title: "Zoom in", window: "Map", actions: ["AXPress"])

    func testCoordinateClickNeverRunsWithoutAsking() {
        for target in [vision, axButton] {
            let a = ProposedAction(control: target, kind: .clickPoint, bundleID: "com.apple.Maps")
            guard case .required = ApprovalPolicy.requirement(for: a) else { return XCTFail("click must ask") }
        }
        let axPress = ProposedAction(control: vision, kind: .axPress, bundleID: "com.apple.Maps")
        guard case .required = ApprovalPolicy.requirement(for: axPress) else { return XCTFail("vision-only must ask") }
    }

    func testOrdinaryAXPressesAskToo() {
        let a = ProposedAction(control: axButton, kind: .axPress, bundleID: "com.apple.Maps")
        guard case .required = ApprovalPolicy.requirement(for: a) else { return XCTFail("an AXPress must ask") }
    }

    func testRefusalWordsApplyToFoundControlsToo() {
        let pay = Control(index: 1, role: "AXButton", title: "Pay now", window: "", frame: .zero, fromVision: true)
        XCTAssertNotNil(ControlPolicy.refusal(pay, bundleID: "com.example.shop"))
    }

    func testTheApprovalCardSaysItUsesThePointer() {
        let a = ProposedAction(control: vision, kind: .clickPoint, bundleID: "com.apple.Maps")
        XCTAssertTrue(a.summary.contains("Click the button \"Zoom in\""))
        guard case .required(let why) = ApprovalPolicy.requirement(for: a) else { return XCTFail("must ask") }
        XCTAssertTrue(why.contains("mouse"))   // the screenshot-only reason now comes first: it says why it is a mouse click
        XCTAssertTrue(ApprovalRequest(action: a, reason: why).cardText.contains("With the mouse: seen only on screen."))
        XCTAssertTrue(vision.line.hasSuffix("(found on screen)"))
    }
}
