import XCTest
@testable import ShepCore

final class PermissionStateTests: XCTestCase {
    func testLabelsAndButtons() {
        XCTAssertTrue(PermissionState.granted.isGranted)
        XCTAssertFalse(PermissionState.denied.isGranted)
        XCTAssertEqual(PermissionState.granted.label, "Granted")
        XCTAssertEqual(PermissionState.notDetermined.label, "Not asked yet")
        XCTAssertTrue(PermissionState.denied.label.contains("System Settings"))
        XCTAssertEqual(PermissionState.notDetermined.requestTitle, "Grant")
        XCTAssertEqual(PermissionState.denied.requestTitle, "Open Settings")
        XCTAssertEqual(PermissionState.restricted.requestTitle, "Open Settings")
    }
}

final class DogMessageTests: XCTestCase {
    func testParsesTheMessagesThePageSends() {
        XCTAssertEqual(DogMessage.parse(["submit": "fix this"]), .submit("fix this"))
        XCTAssertEqual(DogMessage.parse(["cancel": true]), .cancel)
        XCTAssertEqual(DogMessage.parse(["choice": "approve"]), .choice("approve"))
        XCTAssertEqual(DogMessage.parse(["card": "shown"]), .cardShown)
        XCTAssertEqual(DogMessage.parse(["card": "hidden"]), .cardHidden)
        XCTAssertEqual(DogMessage.parse(["say": "hi"]), .said("hi"))
        XCTAssertEqual(DogMessage.parse(["ready": true]), .ready)
        XCTAssertEqual(DogMessage.parse(["activate": true]), .activate)
        XCTAssertNil(DogMessage.parse(["activate": false]))
        XCTAssertNil(DogMessage.parse(["ready": false]))
        XCTAssertEqual(DogMessage.parse(["error": "boom"]), .pageError("boom"))
    }

    func testJunkIsIgnored() {
        XCTAssertNil(DogMessage.parse("submit"))
        XCTAssertNil(DogMessage.parse(["card": "weird"]))
        XCTAssertNil(DogMessage.parse(["cancel": false]))
        XCTAssertNil(DogMessage.parse([String: Any]()))
        XCTAssertEqual(DogMessage.parse(["submit": String(repeating: "a", count: 900)]), .submit(String(repeating: "a", count: 500)))
    }
}
