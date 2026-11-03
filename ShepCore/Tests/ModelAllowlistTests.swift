import XCTest
@testable import ShepCore

final class ModelAllowlistTests: XCTestCase {
    func testTheDefaultGlimmerPathAndAnyMuseGlimmerIdAreAccepted() throws {
        XCTAssertNoThrow(try GlimmerConfig().validate())
        XCTAssertNoThrow(try GlimmerConfig(model: GlimmerConfig.defaultModelPath(home: "/Users/me")).validate())
        XCTAssertNoThrow(try GlimmerConfig(model: "/anywhere/else/MUSE-GLIMMER-8B").validate(), "case does not matter")
        XCTAssertNoThrow(try GlimmerConfig(model: "muse-glimmer").validate())
        XCTAssertNoThrow(try GlimmerConfig(model: "/m/Muse-Glimmer-30B-4bit/").validate(), "a trailing slash")
    }

    func testGlimmerRefusesEveryOtherModelName() {
        for model in ["", "/m/g", "gpt-4o", "/m/Some-Other-30B", "muse-spark-1.3", "/m/Muse-Glimmer/other", "glimmer", "muse_glimmer", "/muse-glimmer/x/.."] {
            XCTAssertThrowsError(try GlimmerConfig(model: model).validate(), model)
        }
        do { try GlimmerConfig(model: "gpt-4o").validate(); XCTFail("must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Muse Glimmer"), error.localizedDescription) }
    }

    func testGlimmerRefusesAnAddressThatIsNotThisMac() {
        for url in ["http://example.com:8080/v1", "https://api.meta.ai/v1", "http://192.168.1.5:8080/v1", "http://user:pw@127.0.0.1:8080/v1"] {
            XCTAssertThrowsError(try GlimmerConfig(baseURL: URL(string: url)!).validate(), url)
        }
        XCTAssertNoThrow(try GlimmerConfig(baseURL: URL(string: "http://127.0.0.1:18089/v1")!).validate(), "any local port is fine")
    }

    func testMuseSparkIsAcceptedOnlyAtTheMetaHost() {
        XCTAssertNoThrow(try LabelModelConfig.spark().validate())
        XCTAssertEqual(LabelModelConfig.spark().model, "muse-spark-1.3")
        XCTAssertNoThrow(try LabelModelConfig(kind: .meta, baseURL: URL(string: "https://api.meta.ai/v1")!, model: "Muse-Spark-2", maxTokens: 500).validate())
        XCTAssertNoThrow(try MetaConfig().validate())
        for url in ["https://example.com/v1", "http://api.meta.ai/v1", "https://api.meta.ai.example.com/v1", "https://user@api.meta.ai/v1",
                    "https://api.meta.ai:8443/v1", "http://127.0.0.1:8080/v1"] {
            XCTAssertThrowsError(try LabelModelConfig(kind: .meta, baseURL: URL(string: url)!, model: "muse-spark-1.3", maxTokens: 500).validate(), url)
            XCTAssertThrowsError(try MetaConfig(baseURL: URL(string: url)!).validate(), url)
        }
    }

    func testMuseSparkRefusesOtherModelNames() {
        for model in ["", "gpt-4o", "muse-spark", "muse-spark-", "muse-glimmer-30b", "sam-3.1", "x/muse-spark-1.3", "muse-spark-1.3-contributor"] {
            XCTAssertThrowsError(try LabelModelConfig(kind: .meta, baseURL: URL(string: "https://api.meta.ai/v1")!, model: model, maxTokens: 500).validate(), model)
        }
        XCTAssertThrowsError(try MetaConfig(museModel: "gpt-4o").validate())
    }

    func testTheFactoryRefusesAForeignGlimmerModelFromTheEnvironment() {
        let c = ProviderConfig.from(environment: ["SHEP_GLIMMER_MODEL": "/m/Some-Other-30B"], home: "/Users/me")
        XCTAssertThrowsError(try ProviderFactory.make(config: c, environment: [:]))
        XCTAssertNil(ProviderFactory.makePicker(config: c, environment: [:]), "no picker for a refused model")
        XCTAssertThrowsError(try LabelNamerFactory.make(environment: ["SHEP_GLIMMER_MODEL": "/m/Some-Other-30B"], home: "/Users/me"))
        XCTAssertNoThrow(try LabelNamerFactory.make(environment: [:], home: "/Users/me"))
    }

    func testTheSettingsCheckUsesTheSameAllowlist() {
        XCTAssertNil(ShepSettings.glimmerURLIssue("http://127.0.0.1:8080/v1"))
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("https://example.com/v1"))
    }
}
