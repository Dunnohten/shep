import CoreGraphics
import XCTest
@testable import ShepCore

/// Counts the getter calls each window's nodes receive, so a test can prove which windows were never read.
final class AXCallLog {
    private(set) var counts: [String: [String: Int]] = [:]
    func hit(_ window: String, _ getter: String) { counts[window, default: [:]][getter, default: 0] += 1 }
    func count(_ window: String, _ getter: String) -> Int { counts[window]?[getter] ?? 0 }
    /// value + title + description + help + children + actions + role + subrole + frame + enabled: every call on any node of the window.
    func total(_ window: String) -> Int { (counts[window] ?? [:]).values.reduce(0, +) }
    func content(_ window: String) -> Int {
        ["value", "title", "description", "help", "children"].reduce(0) { $0 + count(window, $1) }
    }
}

/// A node whose getters report to an AXCallLog under its window's name.
struct SpyAX: AXNodeSource {
    var window: String
    var log: AXCallLog
    var _role: String
    var _subrole = ""
    var _title = ""
    var _description = ""
    var _help = ""
    var _value: String? = nil
    var _frame: CGRect? = nil
    var kids: [SpyAX] = []
    var tag = ""

    var role: String { log.hit(window, "role"); return _role }
    var subrole: String { log.hit(window, "subrole"); return _subrole }
    var title: String { log.hit(window, "title"); return _title }
    var descriptionText: String { log.hit(window, "description"); return _description }
    var help: String { log.hit(window, "help"); return _help }
    var valueText: String? { log.hit(window, "value" + tag); return _value }
    var frame: CGRect? { log.hit(window, "frame"); return _frame }
    var isEnabled: Bool { log.hit(window, "enabled"); return true }
    var actions: [String] { log.hit(window, "actions"); return _role == "AXButton" ? ["AXPress"] : [] }
    func children() -> [SpyAX] { log.hit(window, "children"); return kids }
}

/// P1-3: which windows are read is decided from minimal metadata; content getters run only for the target and for modal
/// windows in front of it that overlap it.
final class AXWindowPrivacyTests: XCTestCase {
    static let secret = "SECRET-QUARTERLY-NUMBERS"
    let log = AXCallLog()
    let targetFrame = CGRect(x: 100, y: 100, width: 600, height: 400)

    func window(_ name: String, subrole: String = "AXStandardWindow", frame: CGRect, kids: [SpyAX]) -> SpyAX {
        SpyAX(window: name, log: log, _role: "AXWindow", _subrole: subrole, _title: name, _frame: frame, kids: kids)
    }
    func button(_ window: String, _ title: String, at frame: CGRect) -> SpyAX {
        SpyAX(window: window, log: log, _role: "AXButton", _title: title, _frame: frame)
    }
    func textArea(_ window: String, value: String, at frame: CGRect) -> SpyAX {
        SpyAX(window: window, log: log, _role: "AXTextArea", _title: "Notes", _value: value, _frame: frame, tag: "-textarea")
    }

    struct Spec {
        var name: String
        var root: SpyAX
        var info: AXWindowInfo
    }

    /// target (z 1), a sheet over it (z 0), a covered document (z 2) and a window far away (z 3).
    func fixture(sheetZ: Int = 0, sheetFrame: CGRect = CGRect(x: 200, y: 200, width: 300, height: 150)) -> [Spec] {
        let target = window("Target", frame: targetFrame, kids: [button("Target", "Save", at: CGRect(x: 120, y: 110, width: 60, height: 24))])
        let sheet = window("Sheet", subrole: "AXSheet", frame: sheetFrame, kids: [
            SpyAX(window: "Sheet", log: log, _role: "AXStaticText", _value: "Discard changes?", _frame: CGRect(x: 210, y: 210, width: 200, height: 20)),
            SpyAX(window: "Sheet", log: log, _role: "AXTextField", _title: "Name", _value: "SHEET-FIELD-TEXT", _frame: CGRect(x: 210, y: 240, width: 200, height: 20), tag: "-field"),
            button("Sheet", "Discard", at: CGRect(x: 210, y: 300, width: 80, height: 24)),
        ])
        let doc = window("Doc", frame: CGRect(x: 150, y: 150, width: 300, height: 200), kids: [textArea("Doc", value: Self.secret, at: CGRect(x: 160, y: 160, width: 250, height: 100))])
        let far = window("Far", frame: CGRect(x: 3000, y: 3000, width: 300, height: 200), kids: [textArea("Far", value: "FAR-SECRET", at: CGRect(x: 3010, y: 3010, width: 100, height: 40))])
        func info(_ w: SpyAX, z: Int, modal: Bool = false) -> AXWindowInfo {
            AXWindowInfo(title: w._title, subrole: w._subrole, frame: w._frame, isMain: w._title == "Target", isFocused: false, modalFlag: modal, zOrder: z)
        }
        return [Spec(name: "Sheet", root: sheet, info: info(sheet, z: sheetZ)),
                Spec(name: "Target", root: target, info: info(target, z: 1)),
                Spec(name: "Doc", root: doc, info: info(doc, z: 2)),
                Spec(name: "Far", root: far, info: info(far, z: 3))]
    }

    func read(_ specs: [Spec]) -> AXReadResult<SpyAX> {
        let candidates = specs.map { s in AXWindowCandidate(root: s.root, readInfo: { _ in s.info }) }
        guard let r = AXTreeReader.read(candidates: candidates, targetFrame: targetFrame, targetTitle: "Target", clock: { 0 }) else {
            XCTFail("no result"); fatalError("no result")
        }
        return r
    }

    func testUnrelatedAndCoveredWindowsGetZeroGetterCalls() {
        _ = read(fixture())
        XCTAssertEqual(log.total("Doc"), 0, "a document window behind the target is never touched")
        XCTAssertEqual(log.total("Far"), 0, "a window nowhere near the target is never touched")
    }

    func testTheTargetIsRead() {
        let r = read(fixture())
        XCTAssertGreaterThan(log.count("Target", "children"), 0)
        XCTAssertTrue(r.controls.contains { $0.label == "Save" })
        XCTAssertEqual(r.windows[1].isTarget, true)
    }

    func testAModalInFrontOfTheTargetThatOverlapsItIsRead() {
        let r = read(fixture())
        XCTAssertGreaterThan(log.count("Sheet", "children"), 0)
        let discard = r.controls.first { $0.label == "Discard" }
        XCTAssertEqual(discard?.windowSubrole, "AXSheet")
        XCTAssertTrue(r.modalInFront)
    }

    func testAModalBehindTheTargetIsNotRead() {
        _ = read(fixture(sheetZ: 5))
        XCTAssertEqual(log.total("Sheet"), 0, "behind the target (higher z-order number) is not in front of it")
    }

    func testAModalThatDoesNotOverlapTheTargetIsNotRead() {
        _ = read(fixture(sheetFrame: CGRect(x: 2000, y: 2000, width: 300, height: 150)))
        XCTAssertEqual(log.total("Sheet"), 0)
    }

    func testAModalFlagOnAStandardWindowCounts() {
        var specs = fixture()
        specs[0].info.subrole = "AXStandardWindow"; specs[0].info.modalFlag = true
        _ = read(specs)
        XCTAssertGreaterThan(log.count("Sheet", "children"), 0)
    }

    func testTheValueOfAFieldInAnotherWindowIsNeverReadOrKept() {
        let r = read(fixture())
        XCTAssertEqual(log.count("Sheet", "value-field"), 0, "the sheet's text field value getter was not called")
        let field = r.controls.first { $0.role == "AXTextField" }
        XCTAssertNotNil(field)
        XCTAssertNil(field?.value)
        XCTAssertFalse(field?.inTargetWindow ?? true)
        // The words a sheet shows (a static text) still name that static text.
        XCTAssertTrue(r.controls.contains { $0.label == "Discard changes?" })
        XCTAssertTrue(r.controls.filter { $0.window == "Target" }.allSatisfy { $0.inTargetWindow })
    }

    func testACoveredDocumentFieldValueNeverReachesThePromptOrTheProvider() async {
        let r = read(fixture())
        let all = ControlFilter.prepare(r.controls, limit: 60)
        let text = ControlFilter.serialize(all)
        XCTAssertFalse(text.contains(Self.secret))
        XCTAssertFalse(text.contains("SHEET-FIELD-TEXT"))
        XCTAssertFalse(text.contains("FAR-SECRET"))
        XCTAssertFalse(all.map(\.line).joined().contains(Self.secret))

        let job = NamingJob(image: PreparedImage(jpeg: Data([1]), size: CGSize(width: 100, height: 50), originalSize: CGSize(width: 200, height: 100)),
                            candidates: [], axControls: all)
        let prompt = GlimmerNaming.prompt(job, problem: nil)
        XCTAssertFalse(prompt.contains(Self.secret))
        XCTAssertFalse(prompt.contains("SHEET-FIELD-TEXT"))

        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let geometry = CaptureGeometry(windowFrame: targetFrame, imageSize: CGSize(width: 600, height: 400), scale: 1)
        _ = await FixScreenPipeline(provider: provider).run(VisionInput(png: Data([1]), geometry: geometry, axControls: r.controls,
                                                                         bundleID: "com.example.app", windowTitle: "Target"))
        let handed = provider.calls.flatMap { $0.axControls }
        XCTAssertFalse(handed.isEmpty)
        XCTAssertFalse(handed.contains { ($0.value ?? "").contains(Self.secret) || $0.label.contains(Self.secret) })
    }

    func testAFieldValueFromAnotherWindowIsDroppedEvenIfAControlCarriesIt() {
        var field = Control(index: 1, role: "AXTextField", title: "Name", window: "Other", value: "CARRIED-VALUE", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        field.inTargetWindow = false
        XCTAssertFalse(ControlFilter.serialize([field]).contains("CARRIED-VALUE"))
        XCTAssertFalse(field.line.contains("CARRIED-VALUE"))
        field.inTargetWindow = true
        XCTAssertTrue(ControlFilter.serialize([field]).contains("CARRIED-VALUE"), "the target window's field keeps its value, as before")
        field.role = "AXSecureTextField"
        XCTAssertFalse(ControlFilter.serialize([field]).contains("CARRIED-VALUE"), "the secure-field rule still holds")
    }

    func testTheOldEntryPointAlsoSkipsUnrelatedWindows() {
        let specs = fixture()
        let entries = specs.map { AXWindowEntry(info: $0.info, root: $0.root) }
        _ = AXTreeReader.read(windows: entries, targetFrame: targetFrame, targetTitle: "Target", clock: { 0 })
        XCTAssertEqual(log.total("Doc"), 0)
        XCTAssertEqual(log.total("Far"), 0)
    }
}

/// P2-2: the shared deadline starts before the windows are listed and is checked between windows and between property reads.
final class AXEnumerationDeadlineTests: XCTestCase {
    final class Clock { var now: TimeInterval = 0 }

    /// 18 windows whose metadata is slow: each property read costs `perProperty` seconds on the injected clock.
    func candidates(clock: Clock, perProperty: TimeInterval, reads: Reads) -> [AXWindowCandidate<FakeAX>] {
        (0..<18).map { i in
            AXWindowCandidate(root: FakeAX(role: "AXWindow", title: "W\(i)", frame: CGRect(x: 100, y: 100, width: 500, height: 400)), readInfo: { expired in
                reads.started.append(i)
                for _ in 0..<5 {
                    if expired() { return nil }
                    clock.now += perProperty
                    reads.properties += 1
                }
                return AXWindowInfo(title: "W\(i)", subrole: "AXStandardWindow", frame: CGRect(x: 100, y: 100, width: 500, height: 400), isMain: i == 0)
            })
        }
    }
    final class Reads { var started: [Int] = []; var properties = 0 }

    func testEnumerationStopsAtTheSharedDeadline() {
        let clock = Clock(), reads = Reads()
        let cands = candidates(clock: clock, perProperty: 0.25, reads: reads)
        let r = AXTreeReader.read(candidates: cands, targetFrame: nil, targetTitle: nil, clock: { clock.now })
        XCTAssertNotNil(r, "the windows read before the deadline are still usable")
        XCTAssertLessThan(reads.properties, 18 * 5)
        XCTAssertLessThanOrEqual(reads.properties, 10, "2 s at 0.25 s a read")
        XCTAssertLessThan(reads.started.max() ?? 99, 5, "no later window was even started")
        XCTAssertLessThanOrEqual(clock.now, 2.5)
        XCTAssertEqual(r?.windows.count, 18, "unexamined windows are listed as such")
        XCTAssertEqual(r?.windows.filter { !$0.examined }.count ?? 0, 17)
    }

    func testAnAlreadyExpiredDeadlineReadsNothing() {
        let reads = Reads()
        var ticks = 0
        let r = AXTreeReader.read(candidates: candidates(clock: Clock(), perProperty: 0, reads: reads), targetFrame: nil, targetTitle: nil,
                                  clock: { defer { ticks += 1 }; return ticks == 0 ? 0 : 100 })
        XCTAssertNil(r)
        XCTAssertEqual(reads.properties, 0)
        XCTAssertTrue(reads.started.isEmpty, "not even the first window")
    }

    func testAFastAdapterReadsEveryWindow() {
        let clock = Clock(), reads = Reads()
        let r = AXTreeReader.read(candidates: candidates(clock: clock, perProperty: 0, reads: reads), targetFrame: nil, targetTitle: nil, clock: { clock.now })
        XCTAssertEqual(reads.properties, 90)
        XCTAssertEqual(r?.windows.filter { $0.examined }.count, 18)
    }

    func testTheWalkSharesTheSameDeadline() {
        let clock = Clock(), reads = Reads()
        // Enumeration eats 1.25 s of the 2 s; the walk then has only what is left.
        let cands = Array(candidates(clock: clock, perProperty: 0.25, reads: reads).prefix(1))
        let r = AXTreeReader.read(candidates: cands, targetFrame: nil, targetTitle: nil, clock: { clock.now })
        XCTAssertNotNil(r)
        XCTAssertEqual(clock.now, 1.25, accuracy: 0.001)
    }
}
