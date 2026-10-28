import CoreGraphics
import XCTest
@testable import ShepCore

final class DetectorTests: XCTestCase {
    // A 400x300 pt window at (100, 50) captured on Retina: 800x600 px.
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let size = CGSize(width: 800, height: 600)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, score: Double = 0.9, source: String = "omniparser-v3", kind: String = "icon", caption: String = "") -> DetectedBox {
        DetectedBox(box: CGRect(x: x, y: y, width: w, height: h), score: score, source: source, kind: kind, caption: caption)
    }
    func ax(_ i: Int, _ title: String, frame: CGRect) -> Control {
        Control(index: i, role: "AXButton", title: title, frame: frame, actions: ["AXPress"], pathID: "0/\(i)")
    }

    // MARK: config and wire format

    func testDefaultsAreLocalAndSAM3IsOff() {
        let c = DetectorConfig()
        XCTAssertEqual(c.baseURL.absoluteString, "http://127.0.0.1:8765")
        XCTAssertEqual(c.detectURL.absoluteString, "http://127.0.0.1:8765/detect")
        XCTAssertFalse(c.useSAM3)
        XCTAssertNoThrow(try c.validate())
        XCTAssertThrowsError(try DetectorConfig(baseURL: URL(string: "http://example.com:8765")!).validate())
        XCTAssertThrowsError(try DetectorConfig(baseURL: URL(string: "http://127.0.0.1:\(11230 + 4)")!).validate())
    }

    func testRequestCarriesTheImageAndTheSAM3Flag() throws {
        let off = try DetectorRequests.detect(png: png, config: DetectorConfig())
        XCTAssertEqual(off.method, "POST")
        XCTAssertEqual(off.url.absoluteString, "http://127.0.0.1:8765/detect")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: off.body) as? [String: Any])
        XCTAssertEqual(o["image"] as? String, png.base64EncodedString())
        XCTAssertEqual(o["sam3"] as? Bool, false)
        let on = try DetectorRequests.detect(png: png, config: DetectorConfig(useSAM3: true))
        XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: on.body) as? [String: Any]))["sam3"] as? Bool, true)
    }

    func testResponseBoxesAreClippedAndBadRowsDropped() throws {
        let json = #"""
        {"boxes":[{"box":[10,20,110,70],"score":0.8,"source":"omniparser-v3","kind":"icon","caption":"gear"},
                  {"box":[780,580,900,700],"score":0.5},
                  {"box":[5,5,6,6]},
                  {"box":[1,2,3]},
                  {"box":[900,900,950,950]},
                  {"nope":1}],
         "notes":["omniparser 1.2 s"]}
        """#
        let r = try DetectorResponses.boxes(Data(json.utf8), imageSize: size)
        XCTAssertEqual(r.boxes.count, 2)
        XCTAssertEqual(r.boxes[0].box, CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(r.boxes[0].caption, "gear")
        XCTAssertEqual(r.boxes[1].box, CGRect(x: 780, y: 580, width: 20, height: 20), "clipped to the image")
        XCTAssertEqual(r.boxes[1].score, 0.5)
        XCTAssertTrue(r.notes.contains("omniparser 1.2 s"))
        XCTAssertTrue(r.notes.contains { $0.contains("dropped 4") })
        XCTAssertThrowsError(try DetectorResponses.boxes(Data("nope".utf8), imageSize: size))
        XCTAssertThrowsError(try DetectorResponses.boxes(Data(#"{"boxes":"x"}"#.utf8), imageSize: size))
    }

    func testSidecarRoundTripAndErrors() async throws {
        let ok = Result<MetaHTTPResponse, Error>.success(MetaHTTPResponse(status: 200, body: Data(#"{"boxes":[{"box":[10,20,110,70],"score":0.8}]}"#.utf8)))
        let t = StubTransport(ok)
        let found = try await SidecarDetector(transport: t).detect(png: png, imageSize: size)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(t.requests.count, 1)

        let down = SidecarDetector(transport: StubTransport(.failure(URLError(.cannotConnectToHost))))
        do { _ = try await down.detect(png: png, imageSize: size); XCTFail("must throw") }
        catch {
            guard case .unreachable(let why)? = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("detector-server.py"), "the message says how to start it")
        }
        let bad = SidecarDetector(transport: StubTransport(.success(MetaHTTPResponse(status: 503, body: Data(#"{"error":"sam3 is not enabled"}"#.utf8)))))
        do { _ = try await bad.detect(png: png, imageSize: size); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? ProviderError, .http(503, "sam3 is not enabled")) }

        let remote = StubTransport(ok)
        do { _ = try await SidecarDetector(config: DetectorConfig(baseURL: URL(string: "http://example.com:8765")!), transport: remote).detect(png: png, imageSize: size); XCTFail("must throw") } catch {}
        XCTAssertTrue(remote.requests.isEmpty, "nothing is sent off this Mac")
        XCTAssertEqual(SidecarDetector(config: DetectorConfig(useSAM3: true)).name, "omniparser-v3+sam3")
    }

    // MARK: merging with Accessibility

    func testBoxesTheAXTreeAlreadyHasAreDropped() {
        // The AX "Send" button is at screen (200,100,40,20); the detector's first box lands on it at screen (202,101,40,20).
        let send = ax(1, "Send", frame: CGRect(x: 200, y: 100, width: 40, height: 20))
        let found = ControlMerger.candidates(detections: [box(204, 102, 80, 40), box(600, 100, 60, 60)], geometry: geometry, ax: [send])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].pixelBox, CGRect(x: 600, y: 100, width: 60, height: 60))
    }

    func testAnIconInsideItsButtonFrameIsTheSameControl() {
        // The detector boxes just the glyph (inside the AX button's frame, similar size): not a new control.
        let button = ax(1, "Mute", frame: CGRect(x: 300, y: 200, width: 40, height: 40))
        let glyph = box(410, 310, 50, 50)   // 25 pt in a 40 pt frame: IoU 0.39, so only the nested rule drops it
        XCTAssertTrue(ControlMerger.candidates(detections: [glyph], geometry: geometry, ax: [button]).isEmpty)
    }

    func testABigAXContainerDoesNotSwallowTheDetectorBoxes() {
        let window = Control(index: 1, role: "AXGroup", frame: CGRect(x: 100, y: 50, width: 400, height: 300), pathID: "0")
        let found = ControlMerger.candidates(detections: [box(100, 100, 60, 60), box(300, 300, 60, 60)], geometry: geometry, ax: [window])
        XCTAssertEqual(found.count, 2, "a container holding everything must not hide the controls inside it")
    }

    func testTwoDetectorsFindingTheSameControlCollapseToTheBestScore() {
        let found = ControlMerger.candidates(detections: [box(100, 100, 50, 50, score: 0.6, source: "sam3", kind: "rounded rectangle"),
                                                          box(102, 101, 50, 50, score: 0.95, source: "omniparser-v3", kind: "icon")],
                                             geometry: geometry, ax: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].score, 0.95)
        XCTAssertEqual(found[0].concept, "icon")
    }

    func testNestedBoxesOfSimilarSizeCollapseButASmallIconInABigPanelDoesNot() {
        let nested = ControlMerger.candidates(detections: [box(100, 100, 100, 50, score: 0.9), box(110, 105, 70, 40, score: 0.8)], geometry: geometry, ax: [])
        XCTAssertEqual(nested.count, 1)
        let panel = ControlMerger.candidates(detections: [box(100, 100, 500, 400, score: 0.9), box(150, 150, 30, 30, score: 0.8)], geometry: geometry, ax: [])
        XCTAssertEqual(panel.count, 2)
    }

    func testCandidatesComeInReadingOrderNumberedWithCaptionHints() {
        let dets = [box(500, 300, 40, 40, caption: "lower"), box(100, 10, 40, 40, caption: "first"), box(300, 14, 40, 40)]
        let found = ControlMerger.candidates(detections: dets, geometry: geometry, ax: [])
        XCTAssertEqual(found.map { Int($0.pixelBox.minX) }, [100, 300, 500])
        XCTAssertEqual(found.map(\.id), [1, 2, 3])
        let hints = ControlMerger.hints(for: found, detections: dets)
        XCTAssertEqual(hints, [1: "first", 3: "lower"])
    }

    func testSameControlPredicate() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(VisionRepair.sameControl(a, CGRect(x: 5, y: 5, width: 100, height: 100)))
        XCTAssertTrue(VisionRepair.sameControl(a, CGRect(x: 20, y: 20, width: 70, height: 70)), "inside, comparable size")
        XCTAssertFalse(VisionRepair.sameControl(a, CGRect(x: 20, y: 20, width: 30, height: 30)), "a small box in a big one")
        XCTAssertFalse(VisionRepair.sameControl(a, CGRect(x: 200, y: 0, width: 100, height: 100)))
        XCTAssertFalse(VisionRepair.sameControl(a, CGRect(x: 100, y: 0, width: 100, height: 100)), "touching edges")
    }
}

final class DetectorVisionProviderTests: XCTestCase {
    let geometry = CaptureGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600), scale: 2)
    let prepared = PreparedImage(jpeg: Data([0xFF, 0xD8, 0xFF]), size: CGSize(width: 400, height: 300), originalSize: CGSize(width: 800, height: 600))
    let sendAX = Control(index: 1, role: "AXButton", title: "Send", window: "Inbox", frame: CGRect(x: 200, y: 100, width: 40, height: 20), actions: ["AXPress"], pathID: "0/1")

    func input(request: String? = nil, ax: [Control]? = nil) -> VisionInput {
        VisionInput(png: Data([1]), geometry: geometry, axControls: ax ?? [sendAX], bundleID: "com.example.chat", windowTitle: "Inbox", request: request)
    }
    func dets() -> [DetectedBox] {
        [DetectedBox(box: CGRect(x: 204, y: 102, width: 80, height: 40), score: 0.9, source: "omniparser-v3", kind: "icon"),   // the AX Send button
         DetectedBox(box: CGRect(x: 600, y: 100, width: 60, height: 60), score: 0.8, source: "omniparser-v3", kind: "icon", caption: "gear"),
         DetectedBox(box: CGRect(x: 100, y: 400, width: 60, height: 60), score: 0.7, source: "omniparser-v3", kind: "icon")]
    }
    func provider(detector: DetectorProvider, namer: ControlNaming, preparer: PreparedImage? = nil) -> DetectorVisionProvider {
        DetectorVisionProvider(detector: detector, namer: namer, preparer: FakePreparer(result: preparer ?? prepared))
    }

    func testDetectorBoxesMergedWithAXAreNamedByTheNamer() async throws {
        let namer = FakeNamer(result: NamingResult(summary: "A chat window.", labels: [1: MuseLabel(id: 1, name: "Settings", role: "button")], notes: []))
        let p = provider(detector: FakeDetector(boxes: dets()), namer: namer)
        let a = try await p.analyze(input())
        XCTAssertEqual(a.summary, "A chat window.")
        XCTAssertEqual(a.controls.map(\.name), ["Settings", "unlabeled icon"], "the AX Send box is not offered again; an unnamed one stays unlabeled")
        XCTAssertEqual(a.controls[0].box, CGRect(x: 600, y: 100, width: 60, height: 60))
        XCTAssertEqual(a.controls[0].role, "button")
        let job = try XCTUnwrap(namer.jobs.first)
        XCTAssertEqual(job.candidates.count, 2)
        XCTAssertEqual(job.hints, [1: "gear"])
        XCTAssertEqual(job.axControls.map(\.label), ["Send"])
        XCTAssertFalse(p.sendsOffDevice)
        XCTAssertEqual(p.name, "fake-detector+fake-namer")
    }

    func testNothingNewMeansTheNamerIsNeverCalled() async throws {
        let namer = FakeNamer(result: NamingResult())
        let a = try await provider(detector: FakeDetector(boxes: [dets()[0]]), namer: namer).analyze(input())
        XCTAssertTrue(a.controls.isEmpty)
        XCTAssertTrue(namer.jobs.isEmpty)
    }

    func testANamerFailureStillReturnsTheBoxesUnlabeled() async throws {
        let p = provider(detector: FakeDetector(boxes: dets()), namer: FakeNamer(error: .unreachable("glimmer down")))
        let a = try await p.analyze(input())
        XCTAssertEqual(a.controls.map(\.name), ["unlabeled icon", "unlabeled icon"])
        XCTAssertTrue(a.notes.contains { $0.contains("naming failed") })
    }

    func testDetectorAndImageErrorsPropagate() async {
        let down = provider(detector: FakeDetector(error: .unreachable("no sidecar")), namer: FakeNamer(result: NamingResult()))
        do { _ = try await down.analyze(input()); XCTFail("must throw") } catch { XCTAssertEqual(error as? ProviderError, .unreachable("no sidecar")) }
        let noImage = DetectorVisionProvider(detector: FakeDetector(boxes: dets()), namer: FakeNamer(result: NamingResult()), preparer: FakePreparer(result: nil))
        do { _ = try await noImage.analyze(input()); XCTFail("must throw") } catch { XCTAssertEqual(error as? ProviderError, .imageUnreadable) }
    }

    func testTargetByIdAndTargetTheDetectorMissed() async throws {
        let byId = try await provider(detector: FakeDetector(boxes: dets()),
                                      namer: FakeNamer(result: NamingResult(labels: [1: MuseLabel(id: 1, name: "Settings")], target: .candidate(1))))
            .analyze(input(request: "open settings"))
        XCTAssertEqual(byId.targetBox, CGRect(x: 600, y: 100, width: 60, height: 60))

        let missed = CGRect(x: 300, y: 300, width: 50, height: 50)
        let extra = try await provider(detector: FakeDetector(boxes: dets()),
                                       namer: FakeNamer(result: NamingResult(labels: [1: MuseLabel(id: 1, name: "Settings")], target: .box(name: "Mute", rect: missed))))
            .analyze(input(request: "mute"))
        XCTAssertEqual(extra.targetBox, missed)
        XCTAssertEqual(extra.controls.last?.name, "Mute")

        // A "missed" box that is really one of the detector's boxes resolves to that box instead of adding a duplicate.
        let near = CGRect(x: 602, y: 101, width: 60, height: 60)
        let dup = try await provider(detector: FakeDetector(boxes: dets()),
                                     namer: FakeNamer(result: NamingResult(labels: [:], target: .box(name: "Gear", rect: near))))
            .analyze(input(request: "gear"))
        XCTAssertEqual(dup.targetBox, CGRect(x: 600, y: 100, width: 60, height: 60))
        XCTAssertEqual(dup.controls.count, 2)
    }

    // MARK: through the pipeline

    func testPipelineOffersOnlyThePickedControlWhenTheRequestNamedOne() async {
        let named = NamingResult(labels: [1: MuseLabel(id: 1, name: "Settings", role: "button"), 2: MuseLabel(id: 2, name: "Attach", role: "button")], target: .candidate(2))
        let p = provider(detector: FakeDetector(boxes: dets()), namer: FakeNamer(result: named))
        let asked = await FixScreenPipeline(provider: p).run(input(request: "attach a file"))
        XCTAssertEqual(asked.status, .ok)
        XCTAssertEqual(asked.proposals.count, 1)
        XCTAssertEqual(asked.proposals.first?.action.control.label, "Attach")
        XCTAssertEqual(asked.foundCount, 2, "the other found control is still listed")
        guard case .required? = asked.proposals.first?.requirement else { return XCTFail("a found control always asks") }

        let all = await FixScreenPipeline(provider: p).run(input())
        XCTAssertEqual(all.proposals.count, 2, "no request: every found control is offered")
    }

    func testPipelineCanPickAnAppControlAndStillAsks() async {
        // The detector box of the AX Send button: the target resolves to the app's own control, not a found one.
        let p = provider(detector: FakeDetector(boxes: dets()),
                         namer: FakeNamer(result: NamingResult(labels: [1: MuseLabel(id: 1, name: "Settings")],
                                                              target: .box(name: "Send", rect: CGRect(x: 204, y: 102, width: 80, height: 40)))))
        let r = await FixScreenPipeline(provider: p).run(input(request: "send it"))
        XCTAssertEqual(r.proposals.count, 1)
        XCTAssertEqual(r.proposals.first?.action.control.label, "Send")
        XCTAssertEqual(r.proposals.first?.action.kind, .axPress)
        guard case .required? = r.proposals.first?.requirement else { return XCTFail("every proposal must ask") }
    }

    func testPipelineExplainsWhenTheRequestedControlIsOneShepNeverPresses() async {
        // The model points at a "Delete all" control: policy removes it, so the pick matches nothing, and no other control
        // fits "delete everything" either: no proposals, and a sentence saying so.
        let p = provider(detector: FakeDetector(boxes: dets()),
                         namer: FakeNamer(result: NamingResult(labels: [:], target: .box(name: "Delete all", rect: CGRect(x: 700, y: 500, width: 50, height: 50)))))
        let r = await FixScreenPipeline(provider: p).run(input(request: "delete everything"))
        XCTAssertTrue(r.proposals.isEmpty)
        XCTAssertTrue(r.notes.contains { $0.contains("did not match") })
        XCTAssertTrue(r.explanation.contains("couldn\u{2019}t find") || r.explanation.contains("couldn't find"), r.explanation)
        XCTAssertFalse(r.proposals.contains { $0.action.control.label == "Delete all" })
    }

    func testStaticTextAndPicturesTheModelCalledControlsAreNotOffered() async {
        // Box 1 is a wide, short line the model called a text field; box 2 is a logo; box 3 is a real icon button.
        let boxes = [DetectedBox(box: CGRect(x: 600, y: 100, width: 240, height: 30), score: 0.9, source: "omniparser-v3", kind: "icon"),
                     DetectedBox(box: CGRect(x: 100, y: 400, width: 60, height: 60), score: 0.8, source: "omniparser-v3", kind: "icon"),
                     DetectedBox(box: CGRect(x: 300, y: 400, width: 60, height: 60), score: 0.7, source: "omniparser-v3", kind: "icon")]
        // Reading order of the three boxes: (600,100) first, then (100,400), then (300,400).
        let named = NamingResult(labels: [1: MuseLabel(id: 1, name: "Body text", role: "text field"),
                                          2: MuseLabel(id: 2, name: "Company logo", role: "image"),
                                          3: MuseLabel(id: 3, name: "Attach", role: "icon")])
        let a = try? await provider(detector: FakeDetector(boxes: boxes), namer: FakeNamer(result: named)).analyze(input())
        XCTAssertEqual(a?.controls.map(\.name), ["Attach"])
        XCTAssertEqual(a?.controls.first?.role, "icon")
        XCTAssertTrue((a?.notes ?? []).contains { $0.contains("not controls") })
        let r = await FixScreenPipeline(provider: provider(detector: FakeDetector(boxes: boxes), namer: FakeNamer(result: named))).run(input())
        XCTAssertEqual(r.proposals.map { $0.action.control.label }, ["Attach"])
    }

    func testABoxOverlappingAnAppControlTakesItsRoleAndIsNotListedAgain() async throws {
        // Overlaps the Send button by IoU 0.43 (below the 0.5 de-dup line); the model calls it a text field.
        let box = DetectedBox(box: CGRect(x: 220, y: 108, width: 80, height: 40), score: 0.9, source: "omniparser-v3", kind: "icon")   // pixels; screen (210,104,40,20)
        let named = NamingResult(labels: [1: MuseLabel(id: 1, name: "Message", role: "text field")])
        let a = try await provider(detector: FakeDetector(boxes: [box]), namer: FakeNamer(result: named)).analyze(input())
        XCTAssertTrue(a.controls.isEmpty)
        XCTAssertTrue(a.notes.contains { $0.contains("Accessibility") })
    }
}
