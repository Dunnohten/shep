import CoreGraphics
import XCTest
@testable import ShepCore

// Audit of the code review's three P1s against HEAD 5463814 (the review's table: P1-1 vision-only click identity,
// P1-2 CLI identity fail-open, P1-3 covered document content). Each class starts with the review's literal counterexample and
// names the older test that already encodes it, then adds what the audit found missing.

// MARK: P1-1

/// Literal counterexample: approved "Gear", then "Delete account" at the same rectangle in the same window; role, action and
/// geometry still pass. Already encoded by `ClickIdentityTests.testSameRectangleDifferentLabelRefuses` (and the runner tests in
/// `ClickIdentityRunnerTests`); the tests below repeat it with the review's exact values and add the lookup-failure, per-field,
/// card-to-click and listed-control cases.
final class ReviewP11AuditTests: XCTestCase {
    let windowFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    let boxFrame = CGRect(x: 300, y: 300, width: 80, height: 24)
    var point: CGPoint { CGPoint(x: boxFrame.midX, y: boxFrame.midY) }
    var approvedWindow: ApprovedWindow { ApprovedWindow(pid: 42, number: 7, frame: windowFrame, title: "Doc") }

    func identity(_ label: String = "Gear", role: String = "AXButton", subrole: String = "", enabled: Bool = true,
                  frame: CGRect? = nil) -> HitIdentity {
        HitIdentity.resolved(role: role, subrole: subrole, title: label, enabled: enabled, frame: frame ?? boxFrame)
    }

    func visionAction(_ id: HitIdentity?) -> ProposedAction {
        var vision = Control(index: 2, role: "AXButton", title: "Gear", window: "Doc", frame: boxFrame, pathID: "v1")
        vision.fromVision = true
        return ProposedAction(control: vision, kind: .clickPoint, bundleID: "com.example", hitIdentity: id)
    }

    var listed: Control {
        Control(index: 1, role: "AXButton", title: "Save", window: "Doc", frame: boxFrame, actions: ["AXPress"], pathID: "0/1")
    }

    /// Nothing listed at the spot; the hit test answers with an element carrying `id`, same rectangle, same window.
    func scene(live id: HitIdentity?) -> LiveClickScene {
        LiveClickScene(frontPID: 42, focusedWindowIsApproved: true, windowNumber: 7, windowFrame: windowFrame, windowTitle: "Doc",
                       hitPID: 42, hitInApprovedWindow: true, expected: nil,
                       hit: LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: boxFrame, identity: id))
    }

    func check(_ action: ProposedAction, _ s: LiveClickScene) -> String? {
        ClickGuard.check(window: approvedWindow, action: action, point: point, reader: FakeSceneReader(s))
    }

    func testTheReviewsCounterexampleGearBecomesDeleteAccountAtTheSameRectangle() {
        let approved = identity("Gear")
        let live = identity("Delete account")
        XCTAssertEqual(approved.role, live.role)
        XCTAssertEqual(approved.frame, live.frame)
        XCTAssertEqual(check(visionAction(approved), scene(live: live)), ClickGuard.different)
        XCTAssertNil(check(visionAction(approved), scene(live: approved)), "the unchanged control is still clicked")
    }

    func testAFailedSceneLookupRefusesEveryKindOfClick() {
        let good = scene(live: identity("Gear"))
        var onlyFront = LiveClickScene(); onlyFront.frontPID = 42
        var noHit = good; noHit.hit = nil
        var noHitPID = good; noHitPID.hitPID = nil
        var noWindowNumber = good; noWindowNumber.windowNumber = nil
        var noFrame = good; noFrame.windowFrame = nil
        var listedNoHit = good
        listedNoHit.expected = LiveExpectedElement(control: listed, live: LiveTarget(role: "AXButton", title: "Save"), frame: boxFrame)
        listedNoHit.hit = nil
        let scenes: [LiveClickScene] = [LiveClickScene(), onlyFront, noHit, noHitPID, noWindowNumber, noFrame, listedNoHit]
        let actions: [ProposedAction] = [
            visionAction(identity("Gear")),
            ProposedAction(control: listed, kind: .clickPoint, bundleID: "com.example", hitIdentity: identity("Save")),
            ProposedAction(control: listed, kind: .clickPoint, bundleID: "com.example"),
        ]
        for (i, action) in actions.enumerated() {
            for (j, s) in scenes.enumerated() {
                XCTAssertNotNil(check(action, s), "action \(i), scene \(j): a lookup that failed must not let a click through")
            }
        }
    }

    func testEveryFieldOfTheApprovedIdentityIsComparedWithTheLiveElement() {
        let approved = visionAction(identity("Gear"))
        let changes: [(String, HitIdentity)] = [
            ("label", identity("Delete account")),
            ("role", identity(role: "AXCheckBox")),
            ("subrole", identity(subrole: "AXToggle")),
            ("enabled flag", identity(enabled: false)),
            ("frame", identity(frame: boxFrame.offsetBy(dx: 20, dy: 0))),
            ("label source", HitIdentity.resolved(role: "AXButton", help: "Gear", frame: boxFrame)),
            ("secure flag", identity(role: "AXSecureTextField")),
            ("unnamed", identity("")),
        ]
        for (what, live) in changes {
            XCTAssertNotNil(check(approved, scene(live: live)), "a different \(what) must refuse")
        }
    }

    func testALabelThatChangesBetweenTheCardAndTheClickRefuses() async {
        let executor = ActionRunnerTests.FakeExecutor()
        executor.identity = identity("Gear")
        let asker = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: executor, approve: asker.callback()).run(visionAction(nil))
        XCTAssertEqual(out, .done("Click the button \"Gear\" (found on screen)"))
        guard let cardAction = asker.asked.first?.action else { return XCTFail("no card was shown") }
        XCTAssertEqual(cardAction.hitIdentity, identity("Gear"), "the card's action carries what was under the spot")
        XCTAssertNil(check(cardAction.asClick(), scene(live: identity("Gear"))))
        XCTAssertEqual(check(cardAction.asClick(), scene(live: identity("Delete account"))), ClickGuard.different,
                       "between the card and the click the label changed")
        XCTAssertNil(check(cardAction.asClick(), scene(live: identity("Gear"))), "and the refusal is not sticky")
    }

    func testAListedControlClickedByPointNeedsAnIdentityBeforeTheCard() async {
        let executor = ActionRunnerTests.FakeExecutor()
        executor.identity = nil
        let asker = ActionRunnerTests.Asker(true)
        let out = await ActionRunner(executor: executor, approve: asker.callback())
            .run(ProposedAction(control: listed, kind: .clickPoint, bundleID: "com.example"))
        XCTAssertEqual(out, .refused(ClickGuard.cannotIdentifyMessage))
        XCTAssertEqual(asker.asked.count, 0)
        XCTAssertEqual(executor.clickCalls, 0)
    }

    func testAListedClickWhoseApprovedIdentityIsUnnamedRefuses() {
        var s = scene(live: identity(""))
        s.expected = LiveExpectedElement(control: listed, live: LiveTarget(role: "AXButton", title: "Save"), frame: boxFrame)
        s.hit?.isExpected = true
        let action = ProposedAction(control: listed, kind: .clickPoint, bundleID: "com.example", hitIdentity: identity(""))
        XCTAssertEqual(check(action, s), ClickGuard.cannotIdentifyMessage)
    }
}

// MARK: P1-2

/// Literal counterexample: a supplied PNG with `SHEP_WINDOW_OWNER=com.apple.mail` reached a provider, and a lost pid, AX denial,
/// failed read or empty bundle id left `cli.fix-screen-once`. Already encoded by `CLITargetTests`
/// (`testMailOwnerWithASuppliedPNGNeverReachesTheProvider`, `testUnresolvedPidEmptyBundleAndUnparsablePidAreRefused`,
/// `testOwnerAndPidThatDisagreeAreRefused`, `testAccessibilityDeniedWithANamedTargetIsRefused`,
/// `testAFailedWindowReadWithANamedTargetIsRefusedAndNeverFallsBack`), which watched the vision provider only. Here the spies also
/// watch the picker, and one more door is closed: a window capture whose pid was lost (the owner and pid variables never reached
/// the process) arrives with its frame and title and no owner at all.
final class ReviewP12AuditTests: XCTestCase {
    typealias Lookup = CLITargetTests.FakeLookup
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let frame = "100,50,400,300"

    func lookup(accessibility: Bool = true) -> Lookup {
        let l = Lookup()
        l.accessibilityAllowed = accessibility
        l.bundles = [50: "com.apple.mail", 60: "com.example.notes", 61: "", 62: "com.apple.terminal"]
        l.running = ["com.apple.mail": [50], "com.example.notes": [60], "com.apple.terminal": [62]]
        return l
    }

    struct Spies {
        var outcome: CLIFixScreen.Outcome
        var provider: FakeProvider
        var picker: FakePicker
        var inputsBuilt: Int
    }

    func run(_ env: [String: String], accessibility: Bool = true, readFails: Bool = false) async -> Spies {
        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "A window.", controls: []))
        let picker = FakePicker(result: PickResult(marks: [1]))
        let pipeline = FixScreenPipeline(provider: provider, picker: picker)
        var built = 0
        let outcome = await CLIFixScreen.run(environment: env, lookup: lookup(accessibility: accessibility), pipeline: pipeline) { resolved in
            built += 1
            if readFails { return nil }
            return VisionInput(png: Data([1]), geometry: self.geometry, axControls: [], bundleID: resolved.bundleID, windowTitle: "image",
                               request: "save")
        }
        return Spies(outcome: outcome, provider: provider, picker: picker, inputsBuilt: built)
    }

    func assertRefusedWithNothingSent(_ s: Spies, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(s.outcome.refusal, why, file: file, line: line)
        XCTAssertNil(s.outcome.result, why, file: file, line: line)
        XCTAssertEqual(s.provider.calls.count, 0, "\(why): the provider was asked to analyze", file: file, line: line)
        XCTAssertEqual(s.picker.jobs.count, 0, "\(why): the picker was asked to pick", file: file, line: line)
    }

    func testEveryRefusalMakesZeroAnalyzeAndZeroPickCalls() async {
        let cases: [(String, [String: String], Bool, Bool)] = [
            ("Mail named by owner with a supplied PNG", ["SHEP_WINDOW_OWNER": "com.apple.mail"], true, false),
            ("Mail named by owner in other case", ["SHEP_WINDOW_OWNER": "COM.APPLE.MAIL"], true, false),
            ("Mail named by pid", ["SHEP_AX_PID": "50"], true, false),
            ("owner says an allowed app, pid is Mail", ["SHEP_WINDOW_OWNER": "com.example.notes", "SHEP_AX_PID": "50"], true, false),
            ("owner says Mail, pid is an allowed app", ["SHEP_WINDOW_OWNER": "com.apple.mail", "SHEP_AX_PID": "60"], true, false),
            ("owner and pid disagree, both allowed", ["SHEP_WINDOW_OWNER": "com.example.other", "SHEP_AX_PID": "60"], true, false),
            ("Accessibility denied, pid", ["SHEP_AX_PID": "60"], false, false),
            ("Accessibility denied, owner", ["SHEP_WINDOW_OWNER": "com.example.notes"], false, false),
            ("stale pid", ["SHEP_AX_PID": "999"], true, false),
            ("empty bundle id", ["SHEP_AX_PID": "61"], true, false),
            ("pid not a number", ["SHEP_AX_PID": "12abc"], true, false),
            ("pid negative", ["SHEP_AX_PID": "-4"], true, false),
            ("pid zero", ["SHEP_AX_PID": "0"], true, false),
            ("pid overflows", ["SHEP_AX_PID": "99999999999"], true, false),
            ("owner not running", ["SHEP_WINDOW_OWNER": "com.example.ghost"], true, false),
            ("command runner by pid", ["SHEP_AX_PID": "62"], true, false),
            ("window read fails", ["SHEP_WINDOW_OWNER": "com.example.notes"], true, true),
            ("window read fails, pid", ["SHEP_AX_PID": "60"], true, true),
            ("a window capture that lost its pid: frame and title, no owner", ["SHEP_WINDOW_FRAME": "100,50,400,300", "SHEP_WINDOW_TITLE": "Inbox"], true, false),
        ]
        for (why, env, accessibility, readFails) in cases {
            let s = await run(env, accessibility: accessibility, readFails: readFails)
            assertRefusedWithNothingSent(s, why)
        }
    }

    func testAWindowFrameAloneStillDescribesABarePNG() async {
        let s = await run(["SHEP_WINDOW_FRAME": frame])
        XCTAssertNil(s.outcome.refusal, "a frame says where the pixels sit, not whose they are")
        XCTAssertEqual(s.provider.calls.count, 1)
        XCTAssertEqual(s.provider.calls.first?.bundleID, CLITarget.unattestedBundleID)
        XCTAssertNotNil(s.outcome.notice)
    }

    func testAnAttestedAppWithAFrameAndTitleStillWorks() async {
        let s = await run(["SHEP_AX_PID": "60", "SHEP_WINDOW_FRAME": frame, "SHEP_WINDOW_TITLE": "Notes"])
        XCTAssertNil(s.outcome.refusal)
        XCTAssertEqual(s.provider.calls.count, 1)
        XCTAssertEqual(s.provider.calls.first?.bundleID, "com.example.notes")
    }

    func testTheRefusalSaysWhatToSet() {
        let d = CLITarget.resolve(environment: ["SHEP_WINDOW_FRAME": frame, "SHEP_WINDOW_TITLE": "Inbox"], lookup: lookup())
        guard case .refused(let why) = d else { return XCTFail("\(d)") }
        XCTAssertTrue(why.contains("SHEP_AX_PID"), why)
        XCTAssertTrue(why.contains("SHEP_WINDOW_OWNER"), why)
    }
}

// MARK: P1-3

/// Literal counterexample: a covered document's text field contributes its value to the model's context although the
/// screenshot does not show it, and unrelated windows' content is read before being dropped. Already encoded by
/// `AXWindowPrivacyTests` (`testUnrelatedAndCoveredWindowsGetZeroGetterCalls`, `testACoveredDocumentFieldValueNeverReachesThePromptOrTheProvider`,
/// `testTheValueOfAFieldInAnotherWindowIsNeverReadOrKept`). Those cover a document BEHIND the target; here an ordinary
/// window IN FRONT of the target (the case a person means by "covered") and every output a value could leave through.
final class ReviewP13AuditTests: XCTestCase {
    static let secret = "COVERED-DOCUMENT-SECRET-4471"
    let log = AXCallLog()
    let targetFrame = CGRect(x: 100, y: 100, width: 600, height: 400)

    func window(_ name: String, subrole: String = "AXStandardWindow", frame: CGRect, kids: [SpyAX]) -> SpyAX {
        SpyAX(window: name, log: log, _role: "AXWindow", _subrole: subrole, _title: name, _frame: frame, kids: kids)
    }

    /// z 0: an ordinary document window in front of the target (overlapping it) with a text field holding the secret and a
    /// button; z 1: a sheet over the target (the one allowed extra read); z 2: the target; z 3: another window behind.
    func read() -> AXReadResult<SpyAX> {
        let inFront = window("Front", frame: CGRect(x: 150, y: 150, width: 300, height: 200), kids: [
            SpyAX(window: "Front", log: log, _role: "AXTextField", _title: "Account number", _value: Self.secret,
                  _frame: CGRect(x: 160, y: 160, width: 200, height: 24), tag: "-field"),
            SpyAX(window: "Front", log: log, _role: "AXButton", _title: "Transfer", _frame: CGRect(x: 160, y: 200, width: 80, height: 24)),
        ])
        let sheet = window("Sheet", subrole: "AXSheet", frame: CGRect(x: 200, y: 120, width: 300, height: 100), kids: [
            SpyAX(window: "Sheet", log: log, _role: "AXButton", _title: "Keep", _frame: CGRect(x: 210, y: 130, width: 60, height: 24)),
            SpyAX(window: "Sheet", log: log, _role: "AXTextField", _title: "Reason", _value: "SHEET-VALUE", _frame: CGRect(x: 210, y: 160, width: 200, height: 24), tag: "-sheetfield"),
        ])
        let target = window("Target", frame: targetFrame, kids: [
            SpyAX(window: "Target", log: log, _role: "AXButton", _title: "Save", _frame: CGRect(x: 120, y: 400, width: 60, height: 24)),
        ])
        let behind = window("Behind", frame: CGRect(x: 120, y: 120, width: 300, height: 200), kids: [
            SpyAX(window: "Behind", log: log, _role: "AXTextArea", _title: "Body", _value: Self.secret, _frame: CGRect(x: 130, y: 130, width: 200, height: 100), tag: "-area"),
        ])
        func info(_ w: SpyAX, z: Int, modal: Bool = false) -> AXWindowInfo {
            AXWindowInfo(title: w._title, subrole: w._subrole, frame: w._frame, isMain: w._title == "Target", isFocused: false, modalFlag: modal, zOrder: z)
        }
        let specs: [(SpyAX, AXWindowInfo)] = [(inFront, info(inFront, z: 0)), (sheet, info(sheet, z: 1)), (target, info(target, z: 2)), (behind, info(behind, z: 3))]
        let candidates = specs.map { pair in AXWindowCandidate(root: pair.0, readInfo: { _ in pair.1 }) }
        guard let r = AXTreeReader.read(candidates: candidates, targetFrame: targetFrame, targetTitle: "Target", clock: { 0 }) else {
            XCTFail("no result"); fatalError("no result")
        }
        return r
    }

    func testOnlyTheTargetAndTheModalInFrontAreEverTouched() {
        _ = read()
        let touched = ["Front", "Sheet", "Target", "Behind"].filter { log.total($0) > 0 }
        XCTAssertEqual(touched, ["Sheet", "Target"], "the modal in front is the only extra window read")
        XCTAssertEqual(log.total("Front"), 0, "an ordinary window in front of the target gets no getter call at all")
        XCTAssertEqual(log.total("Behind"), 0)
        XCTAssertEqual(log.count("Front", "value-field"), 0)
        XCTAssertEqual(log.count("Sheet", "value-sheetfield"), 0, "not even the modal's text field value is read")
    }

    func testNoOutputCarriesAnUnrelatedWindowsValueOrControls() async {
        let r = read()
        XCTAssertFalse(r.controls.contains { $0.window == "Front" || $0.window == "Behind" })
        let all = ControlFilter.prepare(r.controls, limit: 60)
        let serialized = ControlFilter.serialize(all)
        let lines = all.map(\.line).joined(separator: "\n")
        let report = AXReadReport.render(windows: r.windows, nodesVisited: r.nodesVisited, kept: all, truncated: r.truncated, modalInFront: r.modalInFront)
        for (name, text) in [("serialize", serialized), ("lines", lines), ("report", report)] {
            XCTAssertFalse(text.contains(Self.secret), name)
            XCTAssertFalse(text.contains("Account number"), name)
            XCTAssertFalse(text.contains("Transfer"), name)
            XCTAssertFalse(text.contains("SHEET-VALUE"), name)
        }

        let image = PreparedImage(jpeg: Data([1]), size: CGSize(width: 100, height: 50), originalSize: CGSize(width: 200, height: 100))
        let naming = GlimmerNaming.prompt(NamingJob(image: image, candidates: [], axControls: all), problem: nil)
        XCTAssertFalse(naming.contains(Self.secret))
        XCTAssertFalse(naming.contains("Account number"))
        let picking = GlimmerPicking.prompt(PickJob(image: image, candidates: all.enumerated().map { PickCandidate(mark: $0 + 1, control: $1) },
                                                    request: "save", windowTitle: "Target"), problem: nil)
        XCTAssertFalse(picking.contains(Self.secret))
        XCTAssertFalse(picking.contains("Transfer"))

        let provider = FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []))
        let picker = FakePicker(result: PickResult(marks: [1]))
        let geometry = CaptureGeometry(windowFrame: targetFrame, imageSize: CGSize(width: 600, height: 400), scale: 1)
        _ = await FixScreenPipeline(provider: provider, picker: picker).run(
            VisionInput(png: Data([1]), geometry: geometry, axControls: r.controls, bundleID: "com.example.app", windowTitle: "Target", request: "save"))
        let handed = provider.calls.flatMap { $0.axControls }
        XCTAssertFalse(handed.isEmpty)
        XCTAssertFalse(handed.contains { c in c.window == "Front" || c.window == "Behind" || (c.value ?? "").contains(Self.secret) })
        for job in picker.jobs {
            XCTAssertFalse(job.candidates.contains { $0.control.window == "Front" || $0.control.window == "Behind" })
        }
    }
}
