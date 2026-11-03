import CoreGraphics
import XCTest
@testable import ShepCore

final class LabelCropCapTests: XCTestCase {
    func testALargeCropIsScaledDownToTheLongestSideCap() {
        let a = LabelCrop.fittedSize(width: 1000, height: 500)!
        XCTAssertEqual([a.width, a.height], [256, 128])
        let b = LabelCrop.fittedSize(width: 300, height: 900)!
        XCTAssertEqual([b.width, b.height], [85, 256])
        let c = LabelCrop.fittedSize(width: 4000, height: 4)!
        XCTAssertEqual([c.width, c.height], [256, 1], "a thin crop keeps at least one pixel")
    }

    func testASmallCropIsNeverEnlarged() {
        let a = LabelCrop.fittedSize(width: 100, height: 50)!
        XCTAssertEqual([a.width, a.height], [100, 50])
        let b = LabelCrop.fittedSize(width: 256, height: 256)!
        XCTAssertEqual([b.width, b.height], [256, 256])
    }

    func testAnEmptyCropHasNoSize() {
        XCTAssertNil(LabelCrop.fittedSize(width: 0, height: 10))
        XCTAssertNil(LabelCrop.fittedSize(width: 10, height: -1))
    }

    func testTheByteBudgetKeepsCropsUntilOneDoesNotFitAndThenDropsTheRest() {
        var budget = LabelCrop.ByteBudget(limit: 1000)
        XCTAssertTrue(budget.admit(bytes: 400))
        XCTAssertTrue(budget.admit(bytes: 600))
        XCTAssertEqual(budget.used, 1000)
        XCTAssertFalse(budget.admit(bytes: 1))
        XCTAssertFalse(budget.admit(bytes: 0))
        XCTAssertTrue(budget.closed)
        var other = LabelCrop.ByteBudget(limit: 1000)
        XCTAssertTrue(other.admit(bytes: 900))
        XCTAssertFalse(other.admit(bytes: 200), "does not fit")
        XCTAssertFalse(other.admit(bytes: 10), "and nothing after it is sent either")
    }

    func testTheRequestCapIsOnePointFiveMegabytes() {
        XCTAssertEqual(LabelCrop.maxTotalBytes, 1_500_000)
        XCTAssertEqual(LabelCrop.maxPixelSide, 256)
    }

    func testPNGSizeIsReadFromTheHeader() {
        let size = LabelCrop.pngSize(fakePNG(width: 120, height: 80, extra: 10))
        XCTAssertEqual(size?.width, 120)
        XCTAssertEqual(size?.height, 80)
        XCTAssertNil(LabelCrop.pngSize(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNil(LabelCrop.pngSize(Data(repeating: 0, count: 40)))
    }

    func input(_ id: Int, png: Data?) -> LabelModelInput {
        LabelModelInput(id: id, role: "AXButton", subrole: "", kind: "button", nearbyText: [], help: "", identifier: "", currentName: "",
                        x: 0, y: 0, width: 20, height: 20, imagePNG: png)
    }

    func imageIDs(_ inputs: [LabelModelInput], config: LabelModelConfig = .glimmer()) throws -> [Int] {
        let r = try LabelPrompt.request(LabelJob(inputs: inputs), config: config, apiKey: config.kind == .meta ? "key-0123456789" : nil)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        let parts = try XCTUnwrap(((body["messages"] as? [[String: Any]])?[1]["content"]) as? [[String: Any]])
        return parts.compactMap { part in
            guard let text = part["text"] as? String, text.hasPrefix("Image of control ") else { return nil }
            return Int(text.dropFirst("Image of control ".count).dropLast())
        }
    }

    func testOnlyCropsWithinThePixelCapAreSent() throws {
        let ids = try imageIDs([input(1, png: fakePNG(width: 256, height: 100)), input(2, png: fakePNG(width: 257, height: 10)),
                                input(3, png: fakePNG(width: 10, height: 900)), input(4, png: Data([1, 2, 3])), input(5, png: nil)])
        XCTAssertEqual(ids, [1])
    }

    func testCropsBeyondTheByteCapAreDropped() throws {
        let big = fakePNG(width: 200, height: 200, extra: 700_000)
        let ids = try imageIDs([input(1, png: big), input(2, png: big), input(3, png: big), input(4, png: fakePNG(width: 10, height: 10))])
        XCTAssertEqual(ids, [1, 2], "two fit in 1.5 MB; the third and everything after it is left out")
        let body = try LabelPrompt.request(LabelJob(inputs: [input(1, png: big), input(2, png: big), input(3, png: big)]), config: .glimmer()).body
        XCTAssertLessThan(body.count, 2_300_000)
    }

    func testOneCropOverTheByteCapIsDroppedAlone() throws {
        XCTAssertEqual(try imageIDs([input(1, png: fakePNG(width: 100, height: 100, extra: 1_600_000))]), [])
    }

    func testTheSameCapsApplyToTheCloudRequest() throws {
        let big = fakePNG(width: 200, height: 200, extra: 700_000)
        XCTAssertEqual(try imageIDs([input(1, png: big), input(2, png: big), input(3, png: big)], config: .spark()), [1, 2])
    }
}

final class LabelFocusedWindowTests: XCTestCase {
    func info(_ title: String, main: Bool = false, focused: Bool = false, subrole: String = "AXStandardWindow", frame: CGRect? = nil) -> AXWindowInfo {
        AXWindowInfo(title: title, subrole: subrole, frame: frame, isMain: main, isFocused: focused)
    }

    func testWithoutAHintTheMainWindowIsChosen() {
        let ws = [info("A", main: true), info("B", focused: true)]
        XCTAssertEqual(WindowSelector.select(ws, targetFrame: nil, targetTitle: nil)?.target, 0)
    }

    func testPreferringFocusPicksTheFocusedWindowOverTheMainOne() {
        let ws = [info("A", main: true), info("B", focused: true)]
        XCTAssertEqual(WindowSelector.select(ws, targetFrame: nil, targetTitle: nil, preferFocused: true)?.target, 1)
    }

    func testAFocusedDialogIsNotMistakenForTheWindow() {
        let ws = [info("A", main: true), info("Sheet", focused: true, subrole: "AXSheet")]
        XCTAssertEqual(WindowSelector.select(ws, targetFrame: nil, targetTitle: nil, preferFocused: true)?.target, 0)
    }

    func testTheFramesOfTheDocksWindowStillWinOverBoth() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 300)
        let b = CGRect(x: 400, y: 0, width: 300, height: 300)
        let ws = [info("A", main: true, frame: a), info("B", focused: true, frame: b)]
        XCTAssertEqual(WindowSelector.select(ws, targetFrame: a, targetTitle: nil, preferFocused: true)?.target, 0)
        XCTAssertEqual(WindowSelector.select(ws, targetFrame: b, targetTitle: nil, preferFocused: false)?.target, 1)
    }

    func testTheScanReadsTheFocusedWindowsControls() {
        func window(_ name: String) -> LabelTestNode {
            LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: name, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                          kids: [LabelTestNode(role: "AXButton", frame: CGRect(x: 10, y: 10, width: 30, height: 24), isEnabled: true, actions: ["AXPress"], identifier: "in-\(name)")])
        }
        let entries = [AXWindowEntry(info: info("Main", main: true, frame: CGRect(x: 0, y: 0, width: 400, height: 300)), root: window("Main")),
                       AXWindowEntry(info: info("Focused", focused: true, frame: CGRect(x: 0, y: 0, width: 400, height: 300)), root: window("Focused"))]
        let plain = AXTreeReader.read(windows: entries, targetFrame: nil, targetTitle: nil, limits: .labelScan, clock: { 0 })!
        let focused = AXTreeReader.read(windows: entries, targetFrame: nil, targetTitle: nil, limits: .labelScan, clock: { 0 }, preferFocused: true)!
        XCTAssertEqual(plain.target, 0)
        XCTAssertEqual(focused.target, 1)
        XCTAssertEqual(focused.controls.first { $0.role == "AXButton" }?.identifier, "in-Focused")
    }

    func testFocusOrderIsTheDocksOrder() {
        XCTAssertEqual(FocusTargetPolicy.order(voiceOverRunning: true), [.voiceover, .keyboard, .mouse])
        XCTAssertEqual(FocusTargetPolicy.order(voiceOverRunning: false), [.keyboard, .mouse])
    }
}
