import XCTest
@testable import ShepCore

final class SettingsModelTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "shep.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsAreTheBriefs() {
        let s = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(s, ShepSettings.defaults)
        XCTAssertEqual(s.themeName, "Tangerine")
        XCTAssertEqual(s.pushToTalkKey, .rightOption)
        XCTAssertEqual(s.callShortcut, HotKeySpec.call)
        XCTAssertTrue(s.speakReplies)
        XCTAssertEqual(s.glimmerURL, "http://127.0.0.1:8080/v1")
        XCTAssertFalse(s.sam3, "SAM 3 is opt-in")
        XCTAssertTrue(s.hideFromCapture, "hidden from screen recordings until the owner says otherwise")
    }

    func testKeysAreTheOnesTheAppAlreadyUses() {
        XCTAssertEqual(SettingsKey.theme, "shep.theme")
        XCTAssertEqual(SettingsKey.hideFromCapture, "shep.hideFromCapture")
        let all = [SettingsKey.theme, SettingsKey.hideFromCapture, SettingsKey.speakReplies, SettingsKey.pushToTalkKey,
                   SettingsKey.callShortcut, SettingsKey.glimmerURL, SettingsKey.sam3]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.hasPrefix("shep.") })
    }

    func testSaveThenLoadRoundTrips() {
        let store = SettingsStore(defaults: defaults)
        var s = ShepSettings.defaults
        s.themeName = "Cobalt"; s.pushToTalkKey = .rightCommand; s.callShortcutID = HotKeySpec.presets[2].id
        s.speakReplies = false; s.glimmerURL = "http://localhost:9000/v1"; s.sam3 = true; s.hideFromCapture = false
        store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertEqual(defaults.string(forKey: "shep.theme"), "Cobalt")
        XCTAssertEqual(defaults.bool(forKey: "shep.hideFromCapture"), false)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set("Mauve", forKey: SettingsKey.theme)
        defaults.set("leftShift", forKey: SettingsKey.pushToTalkKey)
        defaults.set("99-99", forKey: SettingsKey.callShortcut)
        defaults.set("not a url", forKey: SettingsKey.glimmerURL)
        let s = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(s.themeName, "Tangerine")
        XCTAssertEqual(s.pushToTalkKey, .rightOption)
        XCTAssertEqual(s.callShortcutID, HotKeySpec.call.id)
        XCTAssertEqual(s.glimmerURL, ShepSettings.defaultGlimmerURL)
    }

    func testThemeNamesAreNormalised() {
        var s = ShepSettings.defaults
        s.themeName = "beagle-tan"
        XCTAssertEqual(s.sanitized().themeName, "Beagle Tan")
        XCTAssertEqual(ShepThemes.all.count, 12)
    }

    func testGlimmerURLValidation() {
        XCTAssertNil(ShepSettings.glimmerURLIssue("http://127.0.0.1:8080/v1"))
        XCTAssertNil(ShepSettings.glimmerURLIssue("  http://localhost:8081/v1 "))
        XCTAssertNotNil(ShepSettings.glimmerURLIssue(""))
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("ftp://127.0.0.1/v1"))
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("http://example.com/v1"), "not on this Mac")
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("http://127.0.0.1:\(11230 + 4)/v1"), "another local model server's port")
        XCTAssertNotNil(ShepSettings.glimmerURLIssue("garbage"))
        var s = ShepSettings.defaults
        s.glimmerURL = "http://example.com/v1"
        XCTAssertNotNil(s.glimmerURLIssue)
        XCTAssertEqual(s.sanitized().glimmerURL, ShepSettings.defaultGlimmerURL, "a bad address is never stored")
    }

    func testLaunchEnvironmentWinsOverSettings() {
        let store = SettingsStore(defaults: defaults)
        var s = ShepSettings.defaults
        s.glimmerURL = "http://127.0.0.1:9001/v1"; s.sam3 = true
        store.save(s)
        let fromSettings = store.effectiveEnvironment(["HOME": "/x"])
        XCTAssertEqual(fromSettings["SHEP_GLIMMER_URL"], "http://127.0.0.1:9001/v1")
        XCTAssertEqual(fromSettings["SHEP_SAM3"], "1")
        XCTAssertEqual(fromSettings["HOME"], "/x")
        let launched = store.effectiveEnvironment(["SHEP_GLIMMER_URL": "http://127.0.0.1:18089/v1", "SHEP_SAM3": "0"])
        XCTAssertEqual(launched["SHEP_GLIMMER_URL"], "http://127.0.0.1:18089/v1")
        XCTAssertEqual(launched["SHEP_SAM3"], "0")
        let plain = SettingsStore(defaults: UserDefaults(suiteName: suite + ".empty")!).effectiveEnvironment([:])
        XCTAssertNil(plain["SHEP_GLIMMER_URL"], "the default address needs no variable")
        XCTAssertNil(plain["SHEP_SAM3"])
        UserDefaults(suiteName: suite + ".empty")?.removePersistentDomain(forName: suite + ".empty")
        // The provider config sees it.
        XCTAssertEqual(ProviderConfig.from(environment: fromSettings, home: "/Users/x").glimmer.baseURL.absoluteString, "http://127.0.0.1:9001/v1")
        XCTAssertTrue(ProviderConfig.from(environment: fromSettings, home: "/Users/x").detector.useSAM3)
    }

    func testMetaIsAvailableOnlyWithAKeyAndNeverShowsIt() {
        XCTAssertFalse(ProviderAvailability.metaAvailable(environment: [:]))
        XCTAssertFalse(ProviderAvailability.metaAvailable(environment: ["MODEL_API_KEY": "  "]))
        XCTAssertTrue(ProviderAvailability.metaAvailable(environment: ["MODEL_API_KEY": "sk-secret-value"]))
        XCTAssertFalse(ProviderAvailability.metaStatus(environment: ["MODEL_API_KEY": "sk-secret-value"]).contains("sk-secret-value"))
        XCTAssertTrue(ProviderAvailability.metaStatus(environment: [:]).contains("MODEL_API_KEY"))
        XCTAssertTrue(ProviderAvailability.sam3Note.contains("SAM 3 by Meta, under the SAM License"))
        XCTAssertTrue(ProviderAvailability.sam3Note.contains("Hugging Face token"))
    }

    func testShortcutPresetsHaveDistinctIds() {
        let ids = HotKeySpec.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(HotKeySpec.call.id, "49-4864")   // key 49, control + shift + command = 0x1300
    }
}

final class GlimmerPingTests: XCTestCase {
    struct Stub: MetaTransport {
        var result: Result<MetaHTTPResponse, Error>
        func send(_ request: MetaHTTPRequest) async throws -> MetaHTTPResponse { try result.get() }
    }
    struct Down: Error {}

    func testRequestIsAGetOnModels() {
        let r = GlimmerPing.request(baseURL: URL(string: "http://127.0.0.1:8080/v1")!)
        XCTAssertEqual(r.url.absoluteString, "http://127.0.0.1:8080/v1/models")
        XCTAssertEqual(r.method, "GET")
        XCTAssertTrue(r.body.isEmpty)
    }

    func testInterpretsAModelList() {
        let body = try! JSONSerialization.data(withJSONObject: ["data": [["id": "/Users/x/models/Muse-Glimmer-30B-4bit"], ["id": "other"]]])
        let o = GlimmerPing.interpret(status: 200, body: body)
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.models.count, 2)
        XCTAssertEqual(o.message, "Glimmer is answering: Muse-Glimmer-30B-4bit (and 1 more).")
        XCTAssertFalse(GlimmerPing.interpret(status: 404, body: Data()).ok)
        XCTAssertEqual(GlimmerPing.interpret(status: 500, body: Data()).message, "The server answered 500.")
        let empty = GlimmerPing.interpret(status: 200, body: Data("{}".utf8))
        XCTAssertTrue(empty.ok)
        XCTAssertTrue(empty.models.isEmpty)
    }

    func testRunReportsSuccessUnreachableAndRefusals() async {
        let body = try! JSONSerialization.data(withJSONObject: ["data": [["id": "m"]]])
        let ok = await GlimmerPing.run(urlText: "http://127.0.0.1:8080/v1", transport: Stub(result: .success(MetaHTTPResponse(status: 200, body: body))))
        XCTAssertTrue(ok.ok)
        let down = await GlimmerPing.run(urlText: "http://127.0.0.1:8080/v1", transport: Stub(result: .failure(Down())))
        XCTAssertFalse(down.ok)
        XCTAssertTrue(down.message.contains("Nothing is answering"))
        let remote = await GlimmerPing.run(urlText: "http://example.com/v1", transport: Stub(result: .success(MetaHTTPResponse(status: 200, body: Data()))))
        XCTAssertFalse(remote.ok, "a non-local address is refused before anything is sent")
    }
}

final class BarkSettingsTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "shep.tests.bark.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultsAreOnAtPointSix() {
        let s = SettingsStore(defaults: defaults).load()
        XCTAssertTrue(s.barkWhenDone)
        XCTAssertEqual(s.barkVolume, 0.6, accuracy: 1e-9)
    }

    func testRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        var s = store.load()
        s.barkWhenDone = false; s.barkVolume = 0.25
        store.save(s)
        let back = store.load()
        XCTAssertFalse(back.barkWhenDone)
        XCTAssertEqual(back.barkVolume, 0.25, accuracy: 1e-9)
    }

    func testVolumeIsClampedToZeroToOne() {
        let store = SettingsStore(defaults: defaults)
        var s = store.load()
        s.barkVolume = 3; store.save(s)
        XCTAssertEqual(store.load().barkVolume, 1)
        s.barkVolume = -1; store.save(s)
        XCTAssertEqual(store.load().barkVolume, 0)
        defaults.set(Double.nan, forKey: SettingsKey.barkVolume)
        XCTAssertEqual(store.load().barkVolume, 0.6, accuracy: 1e-9)
    }

    func testKeys() {
        XCTAssertEqual(SettingsKey.barkWhenDone, "shep.barkWhenDone")
        XCTAssertEqual(SettingsKey.barkVolume, "shep.barkVolume")
    }
}
