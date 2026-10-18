import XCTest

final class PreferencesTests: XCTestCase {
    @MainActor func testResetPreferences() {
        let name = "org.VonKleistL.OptiFlow.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.reset()
        XCTAssertEqual(preferences.flagNames, ["CTRL", "CMD"])
        preferences.setModifier("CTRL", enabled: false)
        XCTAssertEqual(preferences.flagNames, ["CMD"])
        preferences.reset()
        XCTAssertEqual(preferences.flagNames, ["CTRL", "CMD"])
    }
    @MainActor func testExistingSettingsAndDisabledAppsArePreserved() {
        let name = "org.VonKleistL.OptiFlow.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(" alt, SHIFT ", forKey: "ModifierFlags")
        defaults.set(true, forKey: "MiddleClickResize")
        defaults.set(["example.app": "Example"], forKey: "DisabledApps")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.options.modifiers, [.maskAlternate, .maskShift])
        XCTAssertTrue(preferences.middleClickResize)
        XCTAssertEqual(preferences.disabledApps, ["example.app": "Example"])
        preferences.setModifier("ALT", enabled: false); preferences.setModifier("SHIFT", enabled: false)
        XCTAssertTrue(preferences.options.modifiers.isEmpty)
        preferences.setDisabled("example.app", name: nil, disabled: false)
        XCTAssertTrue(preferences.disabledApps.isEmpty)
    }
}
