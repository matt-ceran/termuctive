import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    fileprivate var appKitAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

enum TerminalTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var foregroundColor: NSColor {
        switch self {
        case .light:
            NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        case .dark:
            NSColor(calibratedWhite: 0.94, alpha: 1)
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(calibratedWhite: 0.99, alpha: 1)
        case .dark:
            NSColor(
                calibratedRed: 0.055,
                green: 0.059,
                blue: 0.067,
                alpha: 1
            )
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .light:
            NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.94, alpha: 0.45)
        case .dark:
            NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.86, alpha: 0.55)
        }
    }

    var dividerColor: NSColor {
        switch self {
        case .light:
            NSColor(calibratedWhite: 0.42, alpha: 0.28)
        case .dark:
            NSColor(calibratedWhite: 0.72, alpha: 0.18)
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let appThemeKey = "appearance.appTheme"
    static let terminalThemeKey = "appearance.terminalTheme"

    @Published var appTheme: AppTheme {
        didSet {
            defaults.set(appTheme.rawValue, forKey: Self.appThemeKey)
            applyAppAppearance()
        }
    }

    @Published var terminalTheme: TerminalTheme {
        didSet {
            defaults.set(terminalTheme.rawValue, forKey: Self.terminalThemeKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appTheme =
            defaults.string(forKey: Self.appThemeKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .dark
        terminalTheme =
            defaults.string(forKey: Self.terminalThemeKey)
            .flatMap(TerminalTheme.init(rawValue:)) ?? .light
        applyAppAppearance()
    }

    private func applyAppAppearance() {
        NSApplication.shared.appearance = appTheme.appKitAppearance
    }
}
