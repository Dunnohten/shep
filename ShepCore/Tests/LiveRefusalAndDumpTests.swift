import CoreGraphics
import XCTest
@testable import ShepCore

// Tests reproducing the code review of 54554aa (F2, F3 list, the debug dump, F1 recorder ownership).

/// F2: an explicitly supplied `--live-target` that is unusable refuses the live run. The decision is pure (`LiveRequestStart`);
/// AppDelegate only acts on it, so a refused run makes no call to Shep's arrival, the capture, the reader or a provider.
final class LiveRequestStartTests: XCTestCase {
    func parse(_ args: [String], _ env: [String: String] = [:]) -> LaunchOptions { LaunchOptions.parse(arguments: args, environment: env) }

    func testAnInvalidExplicitTargetRefusesTheRun() {
        let o = parse(["Shep", "--live-request", "save", "--live-target", "org.m0k.transmission "])
        XCTAssertEqual(LiveRequestStart.decide(options: o), .refuse("target: --live-target is not a bundle id"))
    }

    func testEveryKindOfUnusableTargetRefuses() {
        let cases: [([String], [String: String])] = [
            (["--live-request", "x", "--live-target"], [:]),
            (["--live-request", "x", "--live-target="], [:]),
            (["--live-request", "x", "--live-target", "a b"], [:]),
            (["--live-request", "x", "--live-target", String(repeating: "a", count: 256)], [:]),
            (["--live-request", "x"], ["SHEP_LIVE_TARGET": "junk value"]),
            (["--live-request", "x"], ["SHEP_LIVE_TARGET": ""]),
        ]
        for (args, env) in cases {
            guard case .refuse(let why) = LiveRequestStart.decide(options: parse(["Shep"] + args, env)) else { return XCTFail("\(args) \(env)") }
            XCTAssertTrue(why.hasPrefix("target: "), why)
        }
    }

    func testNoFlagAndNoEnvironmentRunsOnTheFrontApp() {
        XCTAssertEqual(LiveRequestStart.decide(options: parse(["Shep", "--live-request", "x"])), .run)
    }

    func testAValidTargetRuns() {
        XCTAssertEqual(LiveRequestStart.decide(options: parse(["Shep", "--live-request", "x", "--live-target", "org.m0k.transmission"])), .run)
    }

    func testWithoutALiveRequestTheFlagIsIgnoredAndNothingIsRefused() {
        XCTAssertEqual(LiveRequestStart.decide(options: parse(["Shep", "--live-target", "bad value"])), .run)
    }

    func testTheRefusalLinesAreReasonOutcomeFinishedAndNameNoBundleId() {
        let lines = LiveRequestStart.refusalLines("target: --live-target is not a bundle id")
        XCTAssertEqual(lines, ["[shep] live: reason: target: --live-target is not a bundle id", "[shep] live: outcome: refused", "[shep] live: finished"])
        XCTAssertFalse(LiveRequestStart.overlayLine.isEmpty)
        XCTAssertLessThan(LiveRequestStart.overlayLine.count, 80)
    }
}

/// Spies on the debug writer: nothing may be created before the cloud-send decision.
final class SpyDebugSink: LiveDebugSink {
    var files: [String: Data] = [:]
    var announced = false
    func write(_ name: String, _ data: Data) { files[name] = data }
    func write(_ name: String, text: String) { files[name] = Data(text.utf8) }
    func announce() { announced = true }
}

final class LiveDebugGateTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let button = Control(index: 1, role: "AXButton", title: "Send", window: "Inbox", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")

    func input(bundle: String = "com.example.chat") -> VisionInput {
        VisionInput(png: Data([1, 2, 3]), geometry: geometry, axControls: [button], bundleID: bundle, windowTitle: "Inbox", request: "send it")
    }

    func dump(provider: FakeProvider, cloudAllowed: Bool, bundle: String = "com.example.chat", required: String? = nil) -> (sink: SpyDebugSink, begun: Int, returned: Bool) {
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { cloudAllowed }, requiredBundleID: required)
        let i = input(bundle: bundle)
        let sink = SpyDebugSink()
        var begun = 0
        let made = LiveDebug.dumpInputs(gate: pipeline.gate(i), begin: { begun += 1; return sink }, png: i.png, axControls: i.axControls, request: i.request)
        return (sink, begun, made != nil)
    }

    func empty(offDevice: Bool) -> FakeProvider { FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []), sendsOffDevice: offDevice) }

    func testACloudProviderWithCloudOffMakesNoDumpAtAll() {
        let r = dump(provider: empty(offDevice: true), cloudAllowed: false)
        XCTAssertEqual(r.begun, 0, "the directory must not even be created")
        XCTAssertTrue(r.sink.files.isEmpty)
        XCTAssertFalse(r.returned)
    }

    func testACloudProviderWithCloudOnDumps() {
        let r = dump(provider: empty(offDevice: true), cloudAllowed: true)
        XCTAssertEqual(r.begun, 1)
        XCTAssertEqual(Set(r.sink.files.keys), ["input.png", "ax-controls.txt", "request.txt"])
        XCTAssertTrue(r.returned)
    }

    func testALocalProviderDumpsWithoutTheCloudSetting() {
        let r = dump(provider: empty(offDevice: false), cloudAllowed: false)
        XCTAssertEqual(r.begun, 1)
        XCTAssertEqual(r.sink.files["input.png"], Data([1, 2, 3]))
    }

    func testANeverCaptureAppMakesNoDump() {
        for bundle in ["com.apple.mail", "com.apple.Terminal", "com.1password.1password", ""] {
            let r = dump(provider: empty(offDevice: false), cloudAllowed: true, bundle: bundle)
            XCTAssertEqual(r.begun, 0, bundle)
            XCTAssertTrue(r.sink.files.isEmpty, bundle)
        }
    }

    func testAWrongTargetBundleMakesNoDump() {
        let r = dump(provider: empty(offDevice: false), cloudAllowed: true, bundle: "com.google.Chrome", required: "org.m0k.transmission")
        XCTAssertEqual(r.begun, 0)
        XCTAssertTrue(r.sink.files.isEmpty)
        let ok = dump(provider: empty(offDevice: false), cloudAllowed: true, bundle: "org.m0k.transmission", required: "org.m0k.transmission")
        XCTAssertEqual(ok.begun, 1)
    }

    func testTheDumpDecisionComesFromTheGateAlone() {
        // The writer cannot be opened by anything but a nil gate.
        var begun = 0
        _ = LiveDebug.dumpInputs(gate: .notAllowed("x"), begin: { begun += 1; return nil }, png: Data(), axControls: [], request: nil)
        _ = LiveDebug.dumpInputs(gate: .failed("x"), begin: { begun += 1; return nil }, png: Data(), axControls: [], request: nil)
        XCTAssertEqual(begun, 0)
        _ = LiveDebug.dumpInputs(gate: nil, begin: { begun += 1; return nil }, png: Data(), axControls: [], request: nil)
        XCTAssertEqual(begun, 1)
    }

    func testTheGateIsWhatRunDoes() async {
        let cases: [(offDevice: Bool, cloud: Bool, bundle: String, required: String?)] = [
            (true, false, "com.example.chat", nil), (true, true, "com.example.chat", nil), (false, false, "com.apple.mail", nil),
            (false, false, "com.example.chat", "other.app"), (false, false, "com.example.chat", "com.example.chat"),
        ]
        for c in cases {
            let provider = empty(offDevice: c.offDevice)
            let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { c.cloud }, requiredBundleID: c.required)
            let gate = pipeline.gate(input(bundle: c.bundle))
            let result = await pipeline.run(input(bundle: c.bundle))
            if let gate = gate {
                XCTAssertEqual(result.status, gate, "\(c)")
                XCTAssertTrue(provider.calls.isEmpty, "\(c)")
            } else {
                XCTAssertEqual(result.status, .ok, "\(c)")
            }
        }
    }
}

/// The dump writes scrubbed text only, with capped lines.
final class LiveDebugScrubTests: XCTestCase {
    /// A key-shaped fake, assembled from pieces so no key-looking literal sits in the source.
    let secret = "s" + "k-" + String(repeating: "q", count: 24)

    func testAxControlsAreScrubbedInEveryField() {
        let c = Control(index: 1, role: "AXStaticText", title: "", description: "token " + secret, window: "W", value: nil, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        let text = LiveDebug.axControlsText([c])
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains(Redact.mask))
    }

    func testRoleAndSourceStringsAreScrubbedToo() {
        // Redact.scrub masks a key only at a word boundary, so the secret is separated from the role prefix.
        for separator in [" ", ":"] {
            let c = Control(index: 1, role: "AX" + separator + secret, title: "ok", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
            let text = LiveDebug.axControlsText([c])
            XCTAssertFalse(text.contains(secret), "separator '\(separator)'")
            XCTAssertTrue(text.contains(Redact.mask), "separator '\(separator)'")
        }
    }

    func testARequestIsScrubbedAndCapped() {
        let text = LiveDebug.requestText("use key " + secret + " " + String(repeating: "x", count: 5000))
        XCTAssertFalse(text.contains(secret))
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, LiveDebug.lineLimit + 1) }
    }

    func testLongLabelsAreCappedOnOneLine() {
        let c = Control(index: 1, role: "AXStaticText", description: String(repeating: "word ", count: 400), frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        let text = LiveDebug.axControlsText([c])
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, LiveDebug.lineLimit + 1) }
        XCTAssertEqual(text.split(separator: "\n").count, 1)
    }

    func testANewlineInALabelCannotForgeAnotherLine() {
        let c = Control(index: 1, role: "AXStaticText", description: "a\n#2 AXButton \"Delete\" source=title", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(LiveDebug.axControlsText([c]).split(separator: "\n").count, 1)
    }

    func testTheTraceIsScrubbedAndItsLinesCapped() {
        var trace = FixScreenTrace(hadRequest: true)
        trace.pickerUsed = true
        trace.pickerExplanation = secret + " " + String(repeating: "y", count: 3000)
        let result = FixScreenResult(status: .ok, provider: "fake", summary: "", controls: [], proposals: [], notes: [], trace: trace)
        let text = LiveDebug.traceText(result)
        XCTAssertFalse(text.contains(secret))
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, LiveDebug.lineLimit + 1) }
    }

    func testTheDumpWritesNoUnscrubbedTextThroughTheSeam() {
        let sink = SpyDebugSink()
        let c = Control(index: 1, role: "AXStaticText", description: secret, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        _ = LiveDebug.dumpInputs(gate: nil, begin: { sink }, png: Data([9]), axControls: [c], request: "go " + secret)
        for (name, data) in sink.files where name.hasSuffix(".txt") {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret), name)
        }
        XCTAssertEqual(sink.files["input.png"], Data([9]), "the image is the exact bytes handed to the provider")
    }
}

/// F3: the shared never-capture list in scripts/capture-policy-lib.sh must agree with ControlPolicy.mayCapture.
final class CapturePolicyLibTests: XCTestCase {
    func libText() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/capture-policy-lib.sh")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("scripts/ not reachable from the test bundle") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The bundle id literals between the BEGIN and END markers; a trailing `*` makes a prefix.
    func listed() throws -> (exact: [String], prefixes: [String]) {
        let text = try libText()
        guard let begin = text.range(of: "# BEGIN never-capture list"), let end = text.range(of: "# END never-capture list"), begin.upperBound < end.lowerBound else {
            XCTFail("the list markers are missing"); return ([], [])
        }
        var exact: [String] = [], prefixes: [String] = []
        var allowed = CharacterSet(charactersIn: ("a" as Unicode.Scalar)..."z")   // a-z
        allowed.formUnion(CharacterSet(charactersIn: ("0" as Unicode.Scalar)..."9"))   // 0-9
        allowed.insert(charactersIn: ".-_*")
        for rawLine in text[begin.upperBound..<end.lowerBound].split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            for piece in line.split(whereSeparator: { "|\\) \t".contains($0) }) {
                let token = String(piece)
                guard token.contains("."), token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
                if token.hasSuffix("*") { prefixes.append(String(token.dropLast())) } else { exact.append(token) }
            }
        }
        return (exact, prefixes)
    }

    func testEveryListedIdIsRefusedByTheSwiftPolicy() throws {
        let (exact, prefixes) = try listed()
        XCTAssertGreaterThan(exact.count, 30)
        for id in exact { XCTAssertFalse(ControlPolicy.mayCapture(bundleID: id), id) }
        XCTAssertFalse(prefixes.isEmpty)
        for p in prefixes { XCTAssertFalse(ControlPolicy.mayCapture(bundleID: p + "anything"), p) }
    }

    func testEveryIdTheSwiftPolicyNeverCapturesIsInTheList() throws {
        let (exact, prefixes) = try listed()
        let all = ControlPolicy.deniedBundleIDs.union(ControlPolicy.neverCaptureIDs).union(ControlPolicy.commandRunnerIDs)
        for id in all { XCTAssertTrue(exact.contains(id), "\(id) is refused by Swift but missing from capture-policy-lib.sh") }
        XCTAssertTrue(prefixes.contains("com.jetbrains."))
        XCTAssertTrue(prefixes.contains("dev.warp."))
    }

    func testTheRepresentativeDeniedAppsAreListed() throws {
        let (exact, _) = try listed()
        for id in ["com.apple.mail", "com.apple.mobilesms", "com.apple.keychainaccess", "com.apple.terminal", "com.1password.1password",
                   "com.bitwarden.desktop", "com.apple.passwords", "com.lastpass.lastpass", "com.googlecode.iterm2"] {
            XCTAssertTrue(exact.contains(id), id)
        }
        XCTAssertFalse(exact.contains("org.m0k.transmission"))
    }
}

/// F1 (adapted for R1): the recorder deletes only what it made. The absence Boolean is gone; ownership is a `RecordingSlot` (identity), tested
/// in depth in RecordingSlotTests.swift. These four keep the original intent against the real file system.
final class RecordingOutputOwnershipTests: XCTestCase {
    func testAnExistingOutputIsNeverClaimedAndNeverRemovable() {
        let dir = SlotFS.freshDirectory("own-existing")
        SlotFS.write("theirs", to: dir + "/out.mov")
        guard case .failure = RecordingSlot.claim(finalPath: dir + "/out.mov") else { return XCTFail("claimed an existing file") }
        XCTAssertEqual(SlotFS.read(dir + "/out.mov"), "theirs")
    }

    func testNothingIsRemovableBeforeAClaim() {
        let dir = SlotFS.freshDirectory("own-none")
        SlotFS.write("theirs", to: dir + "/out.mov")
        XCTAssertEqual(SlotFS.names(in: dir), ["out.mov"])
    }

    func testAFreshOutputIsClaimedAndRemovable() throws {
        let dir = SlotFS.freshDirectory("own-fresh")
        let slot = try RecordingSlot.claim(finalPath: dir + "/out.mov").get()
        SlotFS.write("partial", to: slot.clipPath)
        XCTAssertEqual(slot.discard(), .removed)
        XCTAssertEqual(SlotFS.names(in: dir), [])
    }

    func testARefusedClaimAfterAGoodOneDoesNotRevokeNorGrant() throws {
        let dir = SlotFS.freshDirectory("own-twice")
        let slot = try RecordingSlot.claim(finalPath: dir + "/out.mov").get()
        guard case .failure = RecordingSlot.claim(finalPath: dir + "/out.mov") else { return XCTFail("claimed twice") }
        SlotFS.write("partial", to: slot.clipPath)
        XCTAssertEqual(slot.discard(), .removed, "the first claim still owns its directory")
    }
}
