import Foundation

enum ProviderPaceWindowRule: Sendable {
    case unsupported
    case resetDatePresent
    case windowDurationPresent
    case windowDuration(minutes: Int)
    case custom(@Sendable (_ window: RateWindow, _ now: Date) -> Bool)

    func matches(window: RateWindow, now: Date) -> Bool {
        switch self {
        case .unsupported:
            false
        case .resetDatePresent:
            window.resetsAt != nil
        case .windowDurationPresent:
            window.windowMinutes != nil
        case let .windowDuration(minutes):
            window.windowMinutes == minutes
        case let .custom(predicate):
            predicate(window, now)
        }
    }
}

enum ProviderPaceDurationRule: Sendable {
    case unsupported
    case windowDurationMissing
    case windowDuration(minutes: Int)
    case custom(@Sendable (_ window: RateWindow) -> Bool)

    func matches(window: RateWindow) -> Bool {
        switch self {
        case .unsupported:
            false
        case .windowDurationMissing:
            window.windowMinutes == nil
        case let .windowDuration(minutes):
            window.windowMinutes == minutes
        case let .custom(predicate):
            predicate(window)
        }
    }
}

enum ProviderPaceKind: Sendable {
    case session
    case weekly

    var defaultWindowMinutes: Int {
        switch self {
        case .session: 300
        case .weekly: 10080
        }
    }
}

enum ProviderPaceSlot: Sendable {
    case primary
    case secondary
    case tertiary
}

struct ProviderStandardPaceLane: Sendable {
    let kind: ProviderPaceKind
    let windowRule: ProviderPaceWindowRule

    init(kind: ProviderPaceKind, windowRule: ProviderPaceWindowRule) {
        self.kind = kind
        self.windowRule = windowRule
    }

    static func session(maximumMinutes: Int, requiresDuration: Bool = false) -> Self {
        Self(kind: .session, windowRule: .custom { window, _ in
            guard let minutes = window.windowMinutes else { return !requiresDuration }
            return minutes <= maximumMinutes
        })
    }

    static var weekly: Self {
        Self(kind: .weekly, windowRule: .custom { _, _ in true })
    }

    static var weeklyWithDuration: Self {
        Self(kind: .weekly, windowRule: .windowDurationPresent)
    }

    static func exact(kind: ProviderPaceKind, minutes: Int) -> Self {
        Self(kind: kind, windowRule: .windowDuration(minutes: minutes))
    }
}

struct ProviderPaceCapability: Sendable {
    static let monthlyWindowSentinelMinutes = 30 * 24 * 60
    static let unsupported = ProviderPaceCapability()
    static let calendarMonthResetWindow = ProviderPaceCapability(
        resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
        inferredMonthlyDuration: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes))

    let resetWindowPace: ProviderPaceWindowRule
    let inferredMonthlyDuration: ProviderPaceDurationRule
    let primary: ProviderStandardPaceLane?
    let secondary: ProviderStandardPaceLane?
    let tertiary: ProviderStandardPaceLane?
    let showsHeadroomHint: Bool
    let sessionPaceWindowRule: ProviderPaceWindowRule
    let allowsEstimatedUsage: Bool

    init(
        resetWindowPace: ProviderPaceWindowRule = .unsupported,
        inferredMonthlyDuration: ProviderPaceDurationRule = .unsupported,
        primary: ProviderStandardPaceLane? = nil,
        secondary: ProviderStandardPaceLane? = nil,
        tertiary: ProviderStandardPaceLane? = nil,
        showsHeadroomHint: Bool = false,
        sessionPaceWindowRule: ProviderPaceWindowRule = .unsupported,
        allowsEstimatedUsage: Bool = true)
    {
        self.resetWindowPace = resetWindowPace
        self.inferredMonthlyDuration = inferredMonthlyDuration
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.showsHeadroomHint = showsHeadroomHint
        self.sessionPaceWindowRule = sessionPaceWindowRule
        self.allowsEstimatedUsage = allowsEstimatedUsage
    }

    func allowsPace(dataConfidence: UsageDataConfidence) -> Bool {
        self.allowsEstimatedUsage || dataConfidence != .estimated
    }

    func supportsResetWindowPace(window: RateWindow, now: Date) -> Bool {
        self.resetWindowPace.matches(window: window, now: now)
    }

    func usesInferredMonthlyDuration(window: RateWindow) -> Bool {
        self.inferredMonthlyDuration.matches(window: window)
    }

    func resolvedResetWindowForPace(_ window: RateWindow) -> RateWindow {
        guard self.usesInferredMonthlyDuration(window: window),
              let resetsAt = window.resetsAt,
              let minutes = Self.inferredMonthlyWindowMinutes(endingAt: resetsAt)
        else { return window }
        return RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: minutes,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            nextRegenPercent: window.nextRegenPercent,
            isSyntheticPlaceholder: window.isSyntheticPlaceholder)
    }

    func resolvedKind(slot: ProviderPaceSlot, window: RateWindow, now: Date) -> ProviderPaceKind? {
        if self.supportsResetWindowPace(window: window, now: now) {
            return .weekly
        }
        let lane = switch slot {
        case .primary: self.primary
        case .secondary: self.secondary
        case .tertiary: self.tertiary
        }
        guard let lane, lane.windowRule.matches(window: window, now: now) else { return nil }
        return lane.kind
    }

    func supportsSessionPace(window: RateWindow, now: Date) -> Bool {
        self.sessionPaceWindowRule.matches(window: window, now: now)
    }

    private static func inferredMonthlyWindowMinutes(endingAt resetsAt: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let startsAt = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        let minutes = resetsAt.timeIntervalSince(startsAt) / 60
        guard minutes.isFinite, minutes > 0 else { return nil }
        return Int(exactly: minutes.rounded())
    }
}
