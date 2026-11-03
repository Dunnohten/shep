import XCTest
@testable import ShepCore

// Written for Shep.

/// Every local address Shep can be pointed at (the Glimmer server, the label model, the detector sidecar, the Settings ping) refuses
/// the other local model server's port before anything is sent, and the cloud path accepts only api.meta.ai.
final class OtherModelServerTests: XCTestCase {
    private var port: Int { LoopbackURL.otherModelServerPort }

    func testThePortIsTheOtherServersAndNoOther() {
        XCTAssertEqual(port, 11230 + 4)
        XCTAssertTrue(LoopbackURL.isOtherModelServer(URL(string: "http://127.0.0.1:\(port)/v1")!))
        XCTAssertFalse(LoopbackURL.isOtherModelServer(URL(string: GlimmerConfig.defaultBaseURL)!))
        XCTAssertFalse(LoopbackURL.isOtherModelServer(URL(string: "http://127.0.0.1:8766")!))
    }

    func testGlimmerRefusesItEvenWithAMuseModelName() {
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            let url = URL(string: "http://\(host):\(port)/v1")!
            XCTAssertThrowsError(try GlimmerConfig(baseURL: url, model: "Muse-Glimmer-30B-4bit").validate(), host)
        }
        XCTAssertNoThrow(try GlimmerConfig().validate())
    }

    func testTheLabelModelRefusesIt() {
        let g = GlimmerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!)
        XCTAssertThrowsError(try LabelModelConfig.glimmer(g).validate())
        XCTAssertNoThrow(try LabelModelConfig.glimmer().validate())
    }

    func testTheDetectorRefusesIt() {
        XCTAssertThrowsError(try DetectorConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!).validate())
        XCTAssertNoThrow(try DetectorConfig().validate())
    }

    func testTheSettingsAddressRefusesIt() {
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("http://127.0.0.1:\(port)/v1"))
        XCTAssertNil(ShepSettings.glimmerURLIssue(GlimmerConfig.defaultBaseURL))
    }

    func testTheCloudLabelModelIsMuseSparkAtMetaOnly() {
        XCTAssertNoThrow(try LabelModelConfig.spark().validate())
        let other = LabelModelConfig(kind: .meta, baseURL: URL(string: "https://example.com/v1")!, model: "muse-spark-1.3", maxTokens: 100)
        XCTAssertThrowsError(try other.validate())
        let local = LabelModelConfig(kind: .meta, baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, model: "muse-spark-1.3", maxTokens: 100)
        XCTAssertThrowsError(try local.validate())
    }
}
