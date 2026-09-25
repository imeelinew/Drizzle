import AppKit
import SwiftUI

func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale(identifier: "zh_CN"), arguments: arguments)
}

enum WorkdayTickAppearance: String {
    case hidden
    case subtle
    case highContrast
}

enum UsageProvider: String, CaseIterable, Hashable {
    case codex
    case claude
    case cursor
    case zai
    case openrouter

    var instanceID: ProviderInstanceID {
        ProviderInstanceID(firstPartyProvider: self)
    }
}

struct ProviderInstanceID: Hashable {
    let rawValue: String

    init(firstPartyProvider provider: UsageProvider) {
        self.rawValue = provider.rawValue
    }

    var firstPartyProvider: UsageProvider? {
        UsageProvider(rawValue: self.rawValue)
    }
}

struct ProviderColor {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUI: Color {
        Color(red: self.red, green: self.green, blue: self.blue)
    }
}

struct RateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
    var nextRegenPercent: Double? = nil
    var isSyntheticPlaceholder = false

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

enum UsageDataConfidence {
    case exact
    case estimated
    case percentOnly
    case unknown
}

struct SessionEquivalentForecast {
    var estimatedWindowsToExhaustWeekly: Double
    var windowsUntilReset: Int
}

func codexBarLocalizedLocale() -> Locale { Locale(identifier: "zh_CN") }
func codexBarLocalizedResourceLocale() -> Locale { Locale(identifier: "zh_CN") }
func codexBarLocalizedInteger(_ value: Int) -> String { String(value) }

struct ProviderMetadata {
    let displayName: String
    let sessionLabel: String
    let weeklyLabel: String
    let iconResourceName: String
    let color: ProviderColor
}

enum ProviderAccentPalette {
    static func color(for provider: UsageProvider) -> ProviderColor {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.color
    }
}

enum ProviderDescriptorRegistry {
    struct Descriptor {
        let metadata: ProviderMetadata
        let pace: ProviderPaceCapability
    }

    static func descriptor(for provider: UsageProvider) -> Descriptor {
        switch provider {
        case .codex:
            Descriptor(
                metadata: ProviderMetadata(
                    displayName: "Codex",
                    sessionLabel: "Session",
                    weeklyLabel: "Weekly",
                    iconResourceName: "ProviderIcon-codex",
                    color: ProviderColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255)),
                pace: ProviderPaceCapability(
                    primary: .session(maximumMinutes: 300),
                    secondary: .weekly,
                    showsHeadroomHint: true,
                    sessionPaceWindowRule: .custom { window, _ in
                        guard let minutes = window.windowMinutes else { return true }
                        return minutes != 7 * 24 * 60 && minutes != 30 * 24 * 60
                    }))
        case .claude:
            Descriptor(
                metadata: ProviderMetadata(
                    displayName: "Claude",
                    sessionLabel: "Session",
                    weeklyLabel: "Weekly",
                    iconResourceName: "ProviderIcon-claude",
                    color: ProviderColor(red: 204 / 255, green: 124 / 255, blue: 94 / 255)),
                pace: ProviderPaceCapability(
                    primary: .session(maximumMinutes: 300),
                    secondary: .weekly,
                    tertiary: .weekly,
                    sessionPaceWindowRule: .custom { _, _ in true }))
        case .cursor:
            Descriptor(
                metadata: ProviderMetadata(
                    displayName: "Cursor",
                    sessionLabel: "Total",
                    weeklyLabel: "Cursor",
                    iconResourceName: "ProviderIcon-cursor",
                    color: ProviderColor(red: 0 / 255, green: 191 / 255, blue: 165 / 255)),
                pace: ProviderPaceCapability(resetWindowPace: .windowDurationPresent))
        case .zai:
            Descriptor(
                metadata: ProviderMetadata(
                    displayName: "z.ai / GLM",
                    sessionLabel: "5-hour",
                    weeklyLabel: "Weekly",
                    iconResourceName: "ProviderIcon-zai",
                    color: ProviderColor(red: 232 / 255, green: 90 / 255, blue: 106 / 255)),
                pace: ProviderPaceCapability(
                    resetWindowPace: .custom { window, _ in
                        window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
                            && window.resetDescription == "MCP"
                    },
                    primary: .exact(kind: .session, minutes: 5 * 60),
                    secondary: .exact(kind: .weekly, minutes: 7 * 24 * 60),
                    sessionPaceWindowRule: .windowDuration(minutes: 5 * 60)))
        case .openrouter:
            Descriptor(
                metadata: ProviderMetadata(
                    displayName: "OpenRouter",
                    sessionLabel: "Credits",
                    weeklyLabel: "Usage",
                    iconResourceName: "ProviderIcon-openrouter",
                    color: ProviderColor(red: 100 / 255, green: 103 / 255, blue: 242 / 255)),
                pace: .unsupported)
        }
    }
}
