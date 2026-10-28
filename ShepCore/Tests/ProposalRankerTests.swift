import CoreGraphics
import XCTest
@testable import ShepCore

final class ProposalRankerTests: XCTestCase {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    let bundle = "com.example.app"

    func ctl(_ i: Int, _ title: String, role: String = "AXButton", x: Double = 100, y: Double = 100, w: Double = 60, h: Double = 30,
             vision: Bool = false, subrole: String = "", enabled: Bool = true, actions: [String]? = nil) -> Control {
        Control(index: i, role: role, subrole: subrole, title: title, frame: CGRect(x: x, y: y, width: w, height: h), enabled: enabled,
                actions: actions ?? (vision ? [] : ["AXPress"]), pathID: vision ? "v\(i)" : "0/\(i)", fromVision: vision)
    }

    func labels(_ r: [RankedControl]) -> [String] { r.map { $0.control.label } }

    // MARK: words

    func testTokensDropFillerWords() {
        XCTAssertEqual(ProposalRanker.tokens("Please click the Save button"), ["save"])
        XCTAssertEqual(ProposalRanker.tokens("close this"), ["close"])
        XCTAssertEqual(ProposalRanker.tokens("unlabeled icon"), [])
        XCTAssertEqual(ProposalRanker.tokens("Open Settings…"), ["open", "settings"])
    }

    func testMatchScoresExactSynonymAndWholeLabel() {
        func score(_ request: String, _ label: String) -> Double {
            ProposalRanker.match(request: ProposalRanker.tokens(request), rawRequest: request, label: ProposalRanker.tokens(label), rawLabel: label)
        }
        XCTAssertEqual(score("save it", "Save"), 14)               // exact 10 + the whole label is in the request 4
        XCTAssertEqual(score("store it", "Save"), 6)               // synonym
        XCTAssertEqual(score("send it", "Submit"), 6)
        XCTAssertEqual(score("find stuff", "Search"), 6)
        XCTAssertEqual(score("open settings", "Preferences"), 6)
        XCTAssertEqual(score("closing", "Quit"), 6, "-ing forms reach the synonym table")
        XCTAssertEqual(score("play music", "Save"), 0)
        XCTAssertEqual(score("back", "Back"), 14)
    }

    // MARK: exclusions

    func testNeverProposesTextPicturesDisabledSecureRefusedOrWindowChrome() {
        let controls = [
            ctl(1, "Save"), ctl(2, "Close", subrole: "AXCloseButton"), ctl(3, "Quit app"), ctl(4, "Off", enabled: false),
            ctl(5, "Caption", role: "AXStaticText", actions: []), ctl(6, "Logo", role: "AXImage", actions: []),
            ctl(7, "Delete all"), ctl(8, "Secret", role: "AXSecureTextField", actions: []),
            ctl(9, "Home", role: "AXLink", actions: ["AXPress"]), ctl(10, "Volume", role: "AXSlider", actions: []),
            ctl(11, "Zoom", subrole: "AXZoomButton"),
        ]
        let r = ProposalRanker.rank(controls, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(labels(r), ["Save", "Home"])
    }

    func testChromeComesBackWhenTheRequestIsAboutIt() {
        let controls = [ctl(1, "Save"), ctl(2, "Close", subrole: "AXCloseButton"), ctl(3, "Quit app")]
        let r = ProposalRanker.rank(controls, request: "close the window", bundleID: bundle, window: window)
        XCTAssertEqual(labels(r), ["Close", "Quit app", "Save"])
        XCTAssertEqual(r[0].matchScore, 14)   // exact 10 + whole label 4
        XCTAssertEqual(r[1].matchScore, 6)    // close and quit are synonyms
        XCTAssertEqual(r[2].matchScore, 0)
        let exit = ProposalRanker.rank(controls, request: "exit", bundleID: bundle, window: window)
        XCTAssertTrue(labels(exit).contains("Close"), "exit is a synonym of close")
    }

    // MARK: ordering

    func testRequestMatchBeatsEverything() {
        let controls = [ctl(1, "Submit form"), ctl(2, "Send"), ctl(3, "Cancel")]
        let r = ProposalRanker.rank(controls, request: "send the message", bundleID: bundle, window: window)
        XCTAssertEqual(labels(r), ["Send", "Submit form", "Cancel"])
        XCTAssertEqual(r[0].score, 20.5)   // button 3 + match 14 + app lists it 2 + labelled 1.5
        XCTAssertEqual(r[1].score, 12.5)   // 3 + 6 + 2 + 1.5
        XCTAssertEqual(r[2].score, 6.5)
    }

    func testControlsTheAppListsOutrankTheSameControlFoundOnTheScreenshot() {
        let controls = [ctl(1, "Settings", x: 100, vision: true), ctl(2, "Settings", x: 300)]
        let r = ProposalRanker.rank(controls, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(r.map { $0.control.fromVision }, [false, true])
        XCTAssertEqual(r[0].score - r[1].score, 2, accuracy: 1e-9)
    }

    func testUnlabeledGuessesRankBelowNamedOnes() {
        let controls = [ctl(1, "unlabeled icon", vision: true), ctl(2, "Gear", x: 300, vision: true)]
        let r = ProposalRanker.rank(controls, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(labels(r), ["Gear", "unlabeled icon"])
        XCTAssertEqual(r[0].score, 4.5)    // button 3 + labelled 1.5
        XCTAssertEqual(r[1].score, 2)      // 3 - 1
    }

    func testRolePriorOrdersKinds() {
        let controls = [
            ctl(1, "Tab one", role: "AXTab", x: 10), ctl(2, "Go", role: "AXButton", x: 100), ctl(3, "Home", role: "AXLink", x: 200),
            ctl(4, "Name", role: "AXTextField", x: 300),
        ]
        let plain = ProposalRanker.rank(controls, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(labels(plain), ["Go", "Home", "Tab one", "Name"])
        let typing = ProposalRanker.rank(controls, request: "type my email", bundleID: bundle, window: window)
        XCTAssertEqual(typing.first?.control.label, "Name", "asking to type lifts the text field above the button")
    }

    func testSizeAndPositionSanity() {
        let controls = [
            ctl(1, "Fine", x: 100, y: 100), ctl(2, "Huge", x: 50, y: 50, w: 500, h: 400), ctl(3, "Outside", x: 900, y: 10),
            ctl(4, "Speck", x: 300, y: 300, w: 4, h: 4),
        ]
        let r = ProposalRanker.rank(controls, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(labels(r), ["Fine", "Speck", "Huge", "Outside"])
        XCTAssertEqual(r.first { $0.control.label == "Huge" }?.score ?? 0, 3.5, accuracy: 1e-9)      // 3 + 2 + 1.5 - 3
        XCTAssertEqual(r.first { $0.control.label == "Outside" }?.score ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(r.first { $0.control.label == "Speck" }?.score ?? 0, 5, accuracy: 1e-9)       // 6.5 - 1.5
    }

    func testTiesKeepTheListOrderAndTheListIsCapped() {
        let many = (1...20).map { ctl($0, "Item \($0)", x: Double($0) * 10) }
        let r = ProposalRanker.rank(many, request: nil, bundleID: bundle, window: window)
        XCTAssertEqual(r.count, ProposalRanker.topK)
        XCTAssertEqual(labels(r), (1...12).map { "Item \($0)" })
        XCTAssertEqual(ProposalRanker.rank(many, request: nil, bundleID: bundle, window: window, limit: 2).count, 2)
    }

    func testNoRequestAndNoControlsGiveNothing() {
        XCTAssertTrue(ProposalRanker.rank([], request: nil, bundleID: bundle, window: window).isEmpty)
        XCTAssertTrue(ProposalRanker.rank([ctl(1, "Save")], request: "  ", bundleID: bundle, window: window).first?.matchScore == 0)
    }

    func testDeniedAppsGetNoCandidates() {
        XCTAssertTrue(ProposalRanker.rank([ctl(1, "Save")], request: nil, bundleID: "com.1password.1password", window: window).isEmpty)
    }
}
