import XCTest
@testable import ShepCore

final class WakeWordSettingsTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "shep.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testKeyName() { XCTAssertEqual(SettingsKey.wakeWord, "shep.wakeWord") }

    func testOffByDefault() {
        XCTAssertFalse(ShepSettings.defaults.wakeWord)
        XCTAssertFalse(SettingsStore(defaults: defaults).load().wakeWord)
    }

    func testRoundTripsUnderItsKey() {
        let store = SettingsStore(defaults: defaults)
        var s = ShepSettings.defaults
        s.wakeWord = true
        store.save(s)
        XCTAssertEqual(defaults.object(forKey: "shep.wakeWord") as? Bool, true)
        XCTAssertTrue(store.load().wakeWord)
        s.wakeWord = false
        store.save(s)
        XCTAssertFalse(store.load().wakeWord)
    }

    func testAJunkValueFallsBackToOff() {
        defaults.set("yes please", forKey: "shep.wakeWord")
        XCTAssertFalse(SettingsStore(defaults: defaults).load().wakeWord)
    }
}
