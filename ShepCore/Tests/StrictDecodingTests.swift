import CoreGraphics
import XCTest
@testable import ShepCore

/// Malformed model or sidecar JSON must be rejected, never coerced into a different valid target.
final class StrictDecodingTests: XCTestCase {
    let size = CGSize(width: 1000, height: 1000)
    let prepared = PreparedImage(jpeg: Data([0xFF, 0xD8, 0xFF]), size: CGSize(width: 960, height: 624), originalSize: CGSize(width: 3024, height: 1964))
    var candidates: [VisionCandidate] {
        [VisionCandidate(id: 1, pixelBox: CGRect(x: 1512, y: 982, width: 151, height: 98), screenFrame: CGRect(x: 756, y: 491, width: 75, height: 49), concept: "icon", score: 0.9),
         VisionCandidate(id: 2, pixelBox: CGRect(x: 300, y: 100, width: 200, height: 100), screenFrame: CGRect(x: 150, y: 50, width: 100, height: 50), concept: "icon", score: 0.8)]
    }
    func job() -> NamingJob {
        NamingJob(image: prepared, candidates: candidates, hints: [:], axControls: [], request: "x", windowTitle: "W")
    }
    func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
    func object(_ text: String) -> [String: Any] { json(text) as! [String: Any] }

    // MARK: numbers

    func testBooleansAndTextAreNotNumbers() {
        let o = object(#"{"a": true, "b": false, "c": 1, "d": 2.5, "e": "3", "f": null}"#)
        XCTAssertNil(MetaResponses.number(o["a"]))
        XCTAssertNil(MetaResponses.number(o["b"]))
        XCTAssertEqual(MetaResponses.number(o["c"]), 1)
        XCTAssertEqual(MetaResponses.number(o["d"]), 2.5)
        XCTAssertNil(MetaResponses.number(o["e"]), "a quoted number is text")
        XCTAssertNil(MetaResponses.number(o["f"]))
        XCTAssertNil(MetaResponses.number(true))
        XCTAssertNil(MetaResponses.number(NSNumber(value: true)))
        XCTAssertNil(MetaResponses.number(Double.nan))
        XCTAssertNil(MetaResponses.number(Double.infinity))
    }

    func testIntegersMustBeWholeNumbers() {
        XCTAssertEqual(MetaResponses.integer(3), 3)
        XCTAssertEqual(MetaResponses.integer(3.0), 3)
        XCTAssertNil(MetaResponses.integer(3.5))
        XCTAssertNil(MetaResponses.integer(true))
        XCTAssertNil(MetaResponses.integer("3"))
        XCTAssertNil(MetaResponses.integer(1e300))
    }

    func testFourNumbersNeedsExactlyFourValidEntries() {
        XCTAssertEqual(MetaResponses.fourNumbers(json("[1,2,3,4]")), [1, 2, 3, 4])
        XCTAssertNil(MetaResponses.fourNumbers(json(#"[0,"bad",0,1000,1000]"#)), "five entries, one bad: the bad one is not dropped to make four")
        XCTAssertNil(MetaResponses.fourNumbers(json("[0,0,1000,1000,5]")))
        XCTAssertNil(MetaResponses.fourNumbers(json("[1,2,3]")))
        XCTAssertNil(MetaResponses.fourNumbers(json(#"[1,2,3,"4"]"#)))
        XCTAssertNil(MetaResponses.fourNumbers(json("[true,2,3,4]")))
        XCTAssertNil(MetaResponses.fourNumbers(json("[1,2,3,null]")))
        XCTAssertNil(MetaResponses.fourNumbers("1,2,3,4"))
    }

    func testScoresAreClampedAndMalformedOnesAreLow() {
        XCTAssertEqual(MetaResponses.score(nil), 1)
        XCTAssertEqual(MetaResponses.score(NSNull()), 1)
        XCTAssertEqual(MetaResponses.score(0.4), 0.4)
        XCTAssertEqual(MetaResponses.score(7), 1)
        XCTAssertEqual(MetaResponses.score(-3), 0)
        XCTAssertEqual(MetaResponses.score("high"), 0)
        XCTAssertEqual(MetaResponses.score(true), 0)
    }

    // MARK: namer

    func testABooleanIdIsNotCandidateOne() {
        let obj = object(#"{"target": {"id": true, "box": null, "name": null}}"#)
        XCTAssertNil(GlimmerNaming.target(in: obj, ids: [1, 2], size: size))
        let rows = GlimmerNaming.parse(text: #"{"summary":"s","controls":[{"id":true,"name":"Gear","role":"button"}],"target":null}"#, job: job())
        XCTAssertNil(rows.result, "a row whose id is a boolean names nothing")
    }

    func testAnIdThatIsPresentButWrongNeverFallsBackToTheBoxOrToACandidate() {
        for id in ["42", "0", "-1", "1.5", #""1""#, "[]", "{}"] {
            let obj = object("{\"target\": {\"id\": \(id), \"box\": [100,100,200,200], \"name\": \"Gear\"}}")
            XCTAssertNil(GlimmerNaming.target(in: obj, ids: [1, 2], size: size), "id \(id)")
        }
        XCTAssertEqual(GlimmerNaming.target(in: object(#"{"target": {"id": 2, "box": null, "name": null}}"#), ids: [1, 2], size: size), .candidate(2))
    }

    func testAMalformedBoxIsNoTarget() {
        for box in [#"[0,"bad",0,1000,1000]"#, "[0,0,1000,1000,5]", "[0,0,1000]", "[true,0,500,500]", "[-1e308,0,1e308,500]", "{}", #""0,0,1,1""#] {
            let obj = object("{\"target\": {\"id\": null, \"box\": \(box), \"name\": \"Gear\"}}")
            XCTAssertNil(GlimmerNaming.target(in: obj, ids: [1, 2], size: size), box)
        }
        guard case .box? = GlimmerNaming.target(in: object(#"{"target": {"id": null, "box": [100,100,200,200], "name": "Gear"}}"#), ids: [1], size: size) else {
            return XCTFail("a good box still works")
        }
    }

    func testRowsWithUnknownOrRepeatedIdsDoNotTakeAnotherControlsName() {
        let r = GlimmerNaming.parse(text: #"{"summary":"s","controls":[{"id":9,"name":"Ghost","role":"button"},{"id":1,"name":"Gear","role":"button"},{"id":1,"name":"Dup","role":"button"}],"target":null}"#, job: job())
        XCTAssertEqual(r.result?.labels[1]?.name, "Gear")
        XCTAssertNil(r.result?.labels[2], "id 9 did not become candidate 2")
    }

    func testMuseLabelsIgnoreBooleanAndFractionalIds() {
        let labels = MetaResponses.labels(#"{"labels":[{"id":true,"name":"A"},{"id":1.5,"name":"B"},{"id":2,"name":"C"}]}"#, ids: [1, 2])
        XCTAssertEqual(labels.keys.sorted(), [2])
    }

    // MARK: detector and SAM boxes

    func testDetectorRowsWithMalformedBoxesAreDropped() throws {
        let body = #"{"boxes":[{"box":[0,"bad",0,100,100]},{"box":[true,0,50,50]},{"box":[0,0,50]},{"box":[-1e308,0,1e308,50]},{"box":[10,10,60,60],"score":"high"},{"box":[20,20,70,70],"score":9}]}"#
        let r = try DetectorResponses.boxes(Data(body.utf8), imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(r.boxes.count, 2)
        XCTAssertEqual(r.boxes.map(\.score), [0, 1], "a malformed score is 0, a huge one is clamped to 1")
        XCTAssertTrue(r.notes.contains { $0.contains("dropped 4") })
    }

    func testSAMRegionNeedsAWellFormedBox() {
        let image = CGSize(width: 1000, height: 1000)
        for box in [#"{"box":[0,"bad",0,1000,1000]}"#, #"{"box":[true,0,500,500]}"#, #"{"box":[0,0,500]}"#,
                    #"{"x":true,"y":0,"width":50,"height":50}"#, #"{"x":"1","y":0,"width":50,"height":50}"#, #"{"box":[-1e308,0,1e308,500]}"#] {
            XCTAssertNil(MetaResponses.region(object(box), concept: "button", imageSize: image), box)
        }
        XCTAssertNotNil(MetaResponses.region(object(#"{"box":[10,10,60,60]}"#), concept: "button", imageSize: image))
        XCTAssertNotNil(MetaResponses.region(object(#"{"x":10,"y":10,"width":50,"height":50}"#), concept: "button", imageSize: image))
    }

    func testHugeCoordinatesDoNotOverflowIntoAFullImageBox() {
        let space = CoordinateSpace(windowFrame: CGRect(origin: .zero, size: size), imageSize: size)
        XCTAssertNil(space.pixelRect(fromNormalized: [-1e308, 0, 1e308, 500]))
        XCTAssertNil(space.pixelRect(fromNormalized: [0, 0, Double.infinity, 5]))
    }
}
