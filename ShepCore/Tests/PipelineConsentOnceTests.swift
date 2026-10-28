import CoreGraphics
import Foundation
import XCTest
@testable import ShepCore

// Tests reproducing the code review of ad80789 (R4): consent is read once per run, and the input dump is a hook inside the
// pipeline that fires only for a run that is about to send, with the same decision.

/// A consent source that answers from a script and counts its reads.
final class ScriptedConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var reads = 0

    init(_ answers: [Bool]) { self.answers = answers }

    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return answers.isEmpty ? false : answers.removeFirst()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

/// Records the order of sink and provider calls.
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class OrderSpyProvider: VisionProvider, @unchecked Sendable {
    let name = "order-spy"
    let sendsOffDevice: Bool
    private let log: OrderLog
    init(log: OrderLog, sendsOffDevice: Bool) { self.log = log; self.sendsOffDevice = sendsOffDevice }
    func analyze(_ input: VisionInput) async throws -> ScreenAnalysis {
        log.add("analyze")
        return ScreenAnalysis(summary: "", controls: [])
    }
}

final class PipelineConsentOnceTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let button = Control(index: 1, role: "AXButton", title: "Send", window: "Inbox", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")

    func input(bundle: String = "com.example.chat") -> VisionInput {
        VisionInput(png: Data([1, 2, 3]), geometry: geometry, axControls: [button], bundleID: bundle, windowTitle: "Inbox", request: "send it")
    }

    func empty(offDevice: Bool) -> FakeProvider { FakeProvider(analysis: ScreenAnalysis(summary: "", controls: []), sendsOffDevice: offDevice) }

    func testConsentThatFlipsAfterTheFirstReadStillSendsAndDumpsWithOneRead() async {
        let consent = ScriptedConsent([true, false])
        let provider = empty(offDevice: true)
        let order = OrderLog()
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { consent.next() })
        let result = await pipeline.run(input(), inputSink: { _ in order.add("sink") })
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(consent.count, 1, "consent is read exactly once per run")
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(order.all, ["sink"])
    }

    func testConsentThatIsFalseFirstDumpsNothingAndCallsNoProvider() async {
        let consent = ScriptedConsent([false, true])
        let provider = empty(offDevice: true)
        let order = OrderLog()
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { consent.next() })
        let result = await pipeline.run(input(), inputSink: { _ in order.add("sink") })
        XCTAssertEqual(result.status, .notAllowed("Sending screenshots to the cloud is off."))
        XCTAssertEqual(consent.count, 1)
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertTrue(order.all.isEmpty)
    }

    func testALocalProviderNeedsNoConsentButTheRunStillReadsItOnce() async {
        let consent = ScriptedConsent([false])
        let provider = empty(offDevice: false)
        let order = OrderLog()
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { consent.next() })
        let result = await pipeline.run(input(), inputSink: { _ in order.add("sink") })
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(consent.count, 1, "read once at the start, whatever the provider")
        XCTAssertEqual(order.all, ["sink"], "a local provider sends nothing off the Mac, so consent does not gate the dump")
    }

    func testAWrongTargetNeverCallsTheSink() async {
        let consent = ScriptedConsent([true])
        let provider = empty(offDevice: false)
        let order = OrderLog()
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { consent.next() }, requiredBundleID: "org.m0k.transmission")
        let result = await pipeline.run(input(bundle: "com.google.Chrome"), inputSink: { _ in order.add("sink") })
        guard case .notAllowed = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(order.all.isEmpty)
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(consent.count, 1)
    }

    func testANeverCaptureAppNeverCallsTheSink() async {
        for bundle in ["com.apple.mail", "com.apple.Terminal", "com.1password.1password", ""] {
            let order = OrderLog()
            let provider = empty(offDevice: false)
            let result = await FixScreenPipeline(provider: provider, cloudAllowed: { true }).run(input(bundle: bundle), inputSink: { _ in order.add("sink") })
            guard case .notAllowed = result.status else { XCTFail("\(bundle): \(result.status)"); continue }
            XCTAssertTrue(order.all.isEmpty, bundle)
            XCTAssertTrue(provider.calls.isEmpty, bundle)
        }
    }

    func testTheSinkFiresStrictlyBeforeTheProviderIsAsked() async {
        let order = OrderLog()
        let provider = OrderSpyProvider(log: order, sendsOffDevice: true)
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { true })
        _ = await pipeline.run(input(), inputSink: { _ in order.add("sink") })
        XCTAssertEqual(order.all, ["sink", "analyze"])
    }

    func testTheSinkSeesTheInputTheProviderGets() async {
        let provider = empty(offDevice: false)
        let box = OrderLog()
        let pipeline = FixScreenPipeline(provider: provider, cloudAllowed: { true })
        _ = await pipeline.run(input(), inputSink: { seen in box.add("png=\(seen.png.count) ax=\(seen.axControls.count) bundle=\(seen.bundleID)") })
        XCTAssertEqual(box.all, ["png=3 ax=\(provider.calls[0].axControls.count) bundle=com.example.chat"])
    }

    func testRunWithoutASinkBehavesAsBefore() async {
        let consent = ScriptedConsent([true, true, true])
        let provider = empty(offDevice: true)
        let result = await FixScreenPipeline(provider: provider, cloudAllowed: { consent.next() }).run(input())
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(consent.count, 1)
    }

    func testTheGateStillAnswersForTheCoordinatorFreeCallers() {
        let pipeline = FixScreenPipeline(provider: empty(offDevice: true), cloudAllowed: { false })
        XCTAssertEqual(pipeline.gate(input()), .notAllowed("Sending screenshots to the cloud is off."))
        XCTAssertNil(FixScreenPipeline(provider: empty(offDevice: true), cloudAllowed: { true }).gate(input()))
    }
}
