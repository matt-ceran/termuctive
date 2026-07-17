import AppKit
import XCTest

@testable import Termuctive

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testNewInstallDefaultsToDarkAppAndLightTerminals() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            NSApplication.shared.appearance = nil
        }

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(settings.appTheme, .dark)
        XCTAssertEqual(settings.terminalTheme, .light)
    }

    func testAppAndTerminalThemesPersistIndependently() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            NSApplication.shared.appearance = nil
        }
        let settings = AppearanceSettings(defaults: defaults)

        settings.appTheme = .light
        settings.terminalTheme = .dark
        let reloadedSettings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(reloadedSettings.appTheme, .light)
        XCTAssertEqual(reloadedSettings.terminalTheme, .dark)
    }

    private var defaultsSuiteName: String {
        "TermuctiveTests.AppearanceSettings"
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
