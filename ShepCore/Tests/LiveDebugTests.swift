import CoreGraphics
import XCTest
@testable import ShepCore

/// Part C: `--live-debug-dir <dir>` (SHEP_LIVE_DEBUG_DIR), an opt-in dump of what a live run saw and decided. Only the pure parts
/// are tested here: the launch option, the directory policy, the folder name and the text of the files.
final class LiveDebugLaunchTests: XCTestCase {
    func parse(_ args: [String], _ env: [String: String] = [:]) -> LaunchOptions { LaunchOptions.parse(arguments: args, environment: env) }

    func testNothingIsSetByDefault() {
        let o = parse(["Shep"])
        XCTAssertNil(o.liveDebugDir)
        XCTAssertNil(o.liveDebugIgnoredLine)
        XCTAssertNil(parse(["Shep", "--live-request", "go"]).liveDebugDir, "a live request alone writes nothing")
    }

    func testFlagWithSeparateValueAndEqualsForm() {
        XCTAssertEqual(parse(["--live-request", "go", "--live-debug-dir", "/tmp/dbg"]).liveDebugDir, "/tmp/dbg")
        XCTAssertEqual(parse(["--live-request=go", "--live-debug-dir=/tmp/dbg2"]).liveDebugDir, "/tmp/dbg2")
    }

    func testEnvironmentFormAndFlagWins() {
        XCTAssertEqual(parse([], ["SHEP_LIVE_REQUEST": "go", "SHEP_LIVE_DEBUG_DIR": "/tmp/env"]).liveDebugDir, "/tmp/env")
        XCTAssertEqual(parse(["--live-debug-dir", "/tmp/flag"], ["SHEP_LIVE_REQUEST": "go", "SHEP_LIVE_DEBUG_DIR": "/tmp/env"]).liveDebugDir, "/tmp/flag")
    }

    func testTrimmedAndEmptyOrFlagLikeValuesAreNotADirectory() {
        XCTAssertEqual(parse(["--live-request", "go", "--live-debug-dir", "  /tmp/x \n"]).liveDebugDir, "/tmp/x")
        for bad in ["", "   ", "--live-record"] {
            let o = parse(["--live-request", "go", "--live-debug-dir", bad])
            XCTAssertNil(o.liveDebugDir, "\(bad)")
        }
        XCTAssertNil(parse(["--live-request", "go"], ["SHEP_LIVE_DEBUG_DIR": " "]).liveDebugDir)
    }

    func testWithoutALiveRequestItIsIgnoredWithALogLine() {
        let o = parse(["--live-debug-dir", "/tmp/dbg"])
        XCTAssertNil(o.liveDebugDir)
        XCTAssertEqual(o.liveDebugIgnoredLine, "[shep] live: ignored: --live-debug-dir needs --live-request")
        let env = parse([], ["SHEP_LIVE_DEBUG_DIR": "/tmp/dbg"])
        XCTAssertNil(env.liveDebugDir)
        XCTAssertNotNil(env.liveDebugIgnoredLine)
    }

    func testOtherLiveOptionsAreUntouched() {
        let o = parse(["--live-request", "go", "--live-record", "/tmp/o.mov", "--live-debug-dir", "/tmp/dbg"])
        XCTAssertEqual(o.liveRecordPath, "/tmp/o.mov")
        XCTAssertEqual(o.liveRequest, "go")
        XCTAssertFalse(o.approveFlag)
    }
}

final class LiveDebugPolicyTests: XCTestCase {
    /// `/work/repo` is a checkout (it holds a .git); `/work/other` and the home folder are not.
    let checkouts: Set<String> = ["/work/repo"]
    var hasGit: (String) -> Bool { { [checkouts] path in checkouts.contains(path) } }
    let home = "/Users/box"
    let bundle = "/work/repo/build/Build/Products/Debug/Shep.app"

    func refusal(_ path: String, bundle: String? = nil, git: ((String) -> Bool)? = nil) -> String? {
        LiveDebug.refusal(path: path, home: home, appBundlePath: bundle, hasGit: git ?? hasGit)
    }

    func testAnOrdinaryDirectoryOutsideAnyCheckoutIsAllowed() {
        XCTAssertNil(refusal("/work/other/dbg"))
        XCTAssertNil(refusal("/work/other/dbg/"))
        XCTAssertNil(refusal("/work/repo2/dbg"), "a name that merely starts like the checkout's is not inside it")
        XCTAssertNil(refusal("/tmp/shep-debug", bundle: bundle))
    }

    func testAnythingInsideACheckoutIsRefused() {
        for path in ["/work/repo", "/work/repo/dbg", "/work/repo/a/b/c/d", "/work/repo/"] {
            let why = refusal(path)
            XCTAssertNotNil(why, path)
            XCTAssertTrue(why?.contains("git") ?? false, "\(why ?? "nil")")
        }
    }

    func testDotDotCannotWalkOutOfTheCheck() {
        XCTAssertNotNil(refusal("/work/other/../repo/dbg"))
        XCTAssertNotNil(refusal("/work/other/./../repo"))
        XCTAssertNil(refusal("/work/repo/../other/dbg"))
        XCTAssertNil(refusal("/work/repo/../../tmp/dbg"))
    }

    func testAnyDirectoryHoldingADotGitIsRefusedNotOnlyTheAppsCheckout() {
        let git: (String) -> Bool = { $0 == "/Users/box/notes" }
        XCTAssertNotNil(refusal("/Users/box/notes/dbg", git: git))
        XCTAssertNotNil(refusal("/Users/box/notes", git: git))
        XCTAssertNil(refusal("/Users/box/dbg", git: git))
    }

    func testTheRunningAppsOwnCheckoutIsRefusedByName() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertNil(refusal("/work/repo/dbg", bundle: nil, git: none), "no .git anywhere and no app path: nothing to say no with")
        // The app was built into /work/repo2/build; the checkout root is found from the bundle's path.
        let git: (String) -> Bool = { $0 == "/work/repo2" }
        XCTAssertNotNil(refusal("/work/repo2/dbg", bundle: "/work/repo2/build/Shep.app", git: git))
        XCTAssertNotNil(refusal("/work/repo2/build/dbg", bundle: "/work/repo2/build/Shep.app", git: git))
    }

    func testHomeIsExpandedAndRelativePathsAreRefused() {
        XCTAssertNil(refusal("~/shep-debug"))
        XCTAssertNotNil(refusal("~/shep-debug", git: { $0 == "/Users/box" }), "~ expands to the home folder, which here holds a .git")
        for bad in ["", "   ", "dbg", "./dbg", "../dbg", "~other/dbg"] {
            XCTAssertNotNil(refusal(bad), "\(bad)")
        }
    }

    func testTheRootOfTheDiskAndNulBytesAreRefused() {
        XCTAssertNotNil(refusal("/"))
        XCTAssertNotNil(refusal("/tmp/a\u{0}b"))
    }

    func testNormalisation() {
        XCTAssertEqual(LiveDebug.normalizedPath("/a/b/../c//d/./e/", home: home), "/a/c/d/e")
        XCTAssertEqual(LiveDebug.normalizedPath("~/x", home: home), "/Users/box/x")
        XCTAssertEqual(LiveDebug.normalizedPath("/../a", home: home), "/a")
        XCTAssertNil(LiveDebug.normalizedPath("rel", home: home))
        XCTAssertNil(LiveDebug.normalizedPath("", home: home))
    }

    func testEnclosingGitRoot() {
        XCTAssertEqual(LiveDebug.enclosingGitRoot(of: "/work/repo/build/Shep.app", hasGit: hasGit), "/work/repo")
        XCTAssertEqual(LiveDebug.enclosingGitRoot(of: "/work/repo", hasGit: hasGit), "/work/repo")
        XCTAssertNil(LiveDebug.enclosingGitRoot(of: "/work/other", hasGit: hasGit))
    }

    func testTheRefusalSaysWhyAndTheLogLineKeepsItOnOneLine() {
        let why = refusal("/work/repo/dbg") ?? ""
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(LiveLog.debugDirRefused(why), "[shep] live: debug dir refused: " + why)
        XCTAssertFalse(LiveLog.debugDirRefused("a\nb").contains("\n"))
    }
}

final class LiveDebugFilesTests: XCTestCase {
    func trace() -> FixScreenTrace {
        FixScreenTrace(hadRequest: true, namerTargetBox: CGRect(x: 60, y: 100, width: 36, height: 36), namerMatched: false,
                       axCount: 3, foundCount: 1, rankedCount: 2,
                       ranked: [TraceRankedControl(mark: 1, role: "AXButton", label: "Send", matchScore: 10, fromVision: false),
                                TraceRankedControl(mark: 2, role: "AXButton", label: "Gear", matchScore: 0, fromVision: true)],
                       pickerUsed: true, pickerMarks: [2], pickerExplanation: "Gear opens settings.", chosenCount: 1)
    }

    func result(_ t: FixScreenTrace, status: FixScreenResult.Status = .ok, notes: [String] = ["a note"], explanation: String = "") -> FixScreenResult {
        FixScreenResult(status: status, provider: "fake", summary: "s", controls: [], proposals: [], notes: notes, explanation: explanation, trace: t)
    }

    func testTheFolderIsNamedByLocalTimeInChicago() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 13, minute: 0, second: 5)) ?? Date()
        XCTAssertEqual(LiveDebug.runDirectoryName(date: date, timeZone: TimeZone(identifier: "America/Chicago") ?? TimeZone.current), "20261027-080005")
        XCTAssertEqual(LiveDebug.runDirectoryName(date: date, timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current), "20261027-130005")
    }

    func testTheFourFilesHaveTheDocumentedNames() {
        XCTAssertEqual(LiveDebug.fileNames, ["input.png", "ax-controls.txt", "trace.txt", "request.txt"])
    }

    func testAXControlsListRoleLabelSourceAndFrameButNeverAValue() {
        var field = Control(index: 2, role: "AXTextField", title: "Name", window: "Doc", value: "PRIVATE-FIELD-TEXT", frame: CGRect(x: 10, y: 20, width: 30, height: 40))
        field.inTargetWindow = true
        let tip = Control(index: 3, role: "AXButton", help: "Settings", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        let text = LiveDebug.axControlsText([Control(index: 1, role: "AXButton", title: "Save", frame: CGRect(x: 100, y: 200, width: 60, height: 24)), field, tip,
                                             Control(index: 4, role: "AXButton")])
        XCTAssertTrue(text.contains("#1 AXButton \"Save\" source=title frame=100,200,60,24"), text)
        XCTAssertTrue(text.contains("source=tooltip"), text)
        XCTAssertTrue(text.contains("source=none"), text)
        XCTAssertTrue(text.contains("frame=-"), "a control without a frame says so: \(text)")
        XCTAssertFalse(text.contains("PRIVATE-FIELD-TEXT"))
        XCTAssertEqual(LiveDebug.axControlsText([]), "no Accessibility controls were handed to the provider\n")
    }

    func testTraceTextShowsTheNamersPickTheRankedListAndThePicker() {
        let text = LiveDebug.traceText(result(trace()))
        XCTAssertTrue(text.contains("namer: pick box=60,100,36,36 matched=no"), text)
        XCTAssertTrue(text.contains("counts: ax=3 found=1 ranked=2 chosen=1"), text)
        XCTAssertTrue(text.contains("#1 AXButton \"Send\" score=10.00 source=ax"), text)
        XCTAssertTrue(text.contains("#2 AXButton \"Gear\" score=0.00 source=found"), text)
        XCTAssertTrue(text.contains("picker: marks=[2]"), text)
        XCTAssertTrue(text.contains("explanation=\"Gear opens settings.\""), text)
        XCTAssertTrue(text.contains("note: a note"), text)
    }

    // Code review R6: the sampled VoiceOver flag and the focused-element reasons are in the dump, not only on stdout.

    func testTraceTextCarriesTheSampledVoiceOverFlagAndTheFallThroughReasons() {
        let sample = FocusTargetSample(source: .keyboard, voiceOverRunning: true,
                                       voiceOverFailures: [FocusAttemptFailure(.system, .foreignOwner), FocusAttemptFailure(.app, .windowUnavailable)])
        let text = LiveDebug.traceText(result(trace()), focus: sample)
        XCTAssertTrue(text.contains("target: keyboard (voiceover=on; system=foreign-owner app=window-unavailable)\n"), text)
        XCTAssertFalse(text.contains("[shep]"), "the dump line has no log prefix")
    }

    func testTraceTextSaysVoiceOverOffAndNoSource() {
        let off = FocusTargetSample(source: .mouse, voiceOverRunning: false, voiceOverFailures: [])
        XCTAssertTrue(LiveDebug.traceText(result(trace()), focus: off).contains("target: mouse (voiceover=off)\n"))
        let none = FocusTargetSample(source: nil, voiceOverRunning: true, voiceOverFailures: [])
        XCTAssertTrue(LiveDebug.traceText(result(trace()), focus: none).contains("target: none (voiceover=on)\n"))
    }

    func testTraceTextWithoutASampleHasNoTargetLine() {
        XCTAssertFalse(LiveDebug.traceText(result(trace())).contains("target:"))
    }

    func testTheTargetLineIsTheSameTextTheLogPrints() {
        let sample = FocusTargetSample(source: .voiceover, voiceOverRunning: true, voiceOverFailures: [FocusAttemptFailure(.system, .ownerUnavailable)])
        XCTAssertEqual("[shep] " + sample.traceLine,
                       FocusTargetPolicy.diagnosticLine(source: .voiceover, voiceOverRunning: true, voiceOverFailures: [FocusAttemptFailure(.system, .ownerUnavailable)]))
    }

    func testTraceTextCoversNoNamerPickerErrorAndStatus() {
        let none = LiveDebug.traceText(result(FixScreenTrace(hadRequest: false)))
        XCTAssertTrue(none.contains("namer: no pick"), none)
        XCTAssertTrue(none.contains("picker: not used"), none)
        XCTAssertTrue(none.contains("ranked: none"), none)
        let broke = LiveDebug.traceText(result(FixScreenTrace(hadRequest: true, pickerError: "The model server answered 500: boom"), status: .failed("down"), explanation: "Nothing fits."))
        XCTAssertTrue(broke.contains("picker: error=\"The model server answered 500: boom\""), broke)
        XCTAssertTrue(broke.contains("status: failed (down)"), broke)
        XCTAssertTrue(broke.contains("none: Nothing fits."), broke)
    }

    func testTraceTextIsScrubbed() {
        let t = FixScreenTrace(hadRequest: true, pickerUsed: true, pickerExplanation: "key sk-abcdefghijklmnop1234567890 leaked", pickerError: "Bearer abcdefghijklmnopqrstuvwxyz")
        let text = LiveDebug.traceText(result(t))
        XCTAssertFalse(text.contains("abcdefghijkl"), text)
        XCTAssertTrue(text.contains(Redact.mask), text)
    }

    func testRequestText() {
        XCTAssertEqual(LiveDebug.requestText("  turn on the turtle \n"), "turn on the turtle\n")
        XCTAssertEqual(LiveDebug.requestText(nil), "(no request)\n")
        XCTAssertEqual(LiveDebug.requestText("   "), "(no request)\n")
    }

    func testTheLogLines() {
        XCTAssertEqual(LiveLog.debugDumpWritten("/tmp/dbg/20261027-080005"), "[shep] live: debug dump written: /tmp/dbg/20261027-080005")
        XCTAssertEqual(LiveLog.debugDumpFailed("could not write input.png"), "[shep] live: debug dump failed: could not write input.png")
    }
}
