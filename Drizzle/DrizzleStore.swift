import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { self.rawValue }

    var title: String {
        switch self {
        case .manual: "手动"
        case .oneMinute: "每分钟"
        case .fiveMinutes: "每 5 分钟"
        case .fifteenMinutes: "每 15 分钟"
        case .thirtyMinutes: "每 30 分钟"
        }
    }
}

enum MenuBarMetric: String, Identifiable {
    case session
    case weekly
    case total
    case cursor
    case thirdParty
    case grokBot
    case keyLimit
    case monthly
    case balance

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .session: "会话额度"
        case .weekly: "周额度"
        case .total: "总计"
        case .cursor: "Cursor"
        case .thirdParty: "Third Party"
        case .grokBot: "Grok Bot"
        case .keyLimit: "密钥额度"
        case .monthly: "月额度"
        case .balance: "余额"
        }
    }

    static func options(for provider: UsageProvider) -> [Self] {
        switch provider {
        case .codex, .claude, .zai: [.session, .weekly]
        case .cursor: [.total, .cursor, .thirdParty, .grokBot]
        case .openrouter: [.keyLimit]
        case .opencodego: [.session, .weekly, .monthly]
        case .deepseek: [.balance]
        }
    }
}

enum MenuBarPercentMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .remaining: "剩余"
        case .used: "已使用"
        }
    }
}

@MainActor
final class DrizzleStore {
    var results: [UsageProvider: ProviderFetchResult] = [:]
    var selection: ProviderSwitcherSelection = .overview
    private(set) var isRefreshing = false
    private(set) var configuration = DrizzleConfiguration()
    var onChange: (() -> Void)?
    var onConfigurationChange: (() -> Void)?
    var onRefreshIntervalChange: (() -> Void)?
    private var inFlight: [UsageProvider: Task<ProviderFetchResult, Never>] = [:]
    private var generation = 0
    private var refreshingGeneration = 0
    private var refreshAgain = false

    var enabledProviders: Set<UsageProvider> {
        Set(self.configuration.enabledProviders.compactMap(UsageProvider.init(rawValue:)))
    }

    var refreshInterval: RefreshInterval {
        RefreshInterval(rawValue: self.configuration.refreshIntervalSeconds) ?? .oneMinute
    }

    var refreshOnOpen: Bool { self.configuration.refreshOnOpen }
    var menuBarProvider: UsageProvider { UsageProvider(rawValue: self.configuration.menuBar.provider) ?? .codex }
    var menuBarMetric: MenuBarMetric { MenuBarMetric(rawValue: self.configuration.menuBar.metric) ?? .session }
    var menuBarPercentMode: MenuBarPercentMode {
        MenuBarPercentMode(rawValue: self.configuration.menuBar.percentMode) ?? .remaining
    }

    func apply(_ configuration: DrizzleConfiguration) {
        guard configuration != self.configuration else { return }
        let previous = self.configuration
        let needsRefresh = previous.credentials != configuration.credentials
            || Set(previous.enabledProviders) != Set(configuration.enabledProviders)
        self.configuration = configuration
        if needsRefresh {
            self.generation += 1
            for task in self.inFlight.values { task.cancel() }
            self.inFlight.removeAll()
            self.results.removeAll()
        }
        if case let .provider(id) = self.selection,
           let provider = id.firstPartyProvider, !self.isEnabled(provider) {
            self.selection = .overview
        }
        self.onConfigurationChange?()
        let intervalChanged = previous.refreshIntervalSeconds != configuration.refreshIntervalSeconds
        if intervalChanged { self.onRefreshIntervalChange?() }
        // An automatic interval starts its own immediate refresh after a change.
        if needsRefresh && (!intervalChanged || self.refreshInterval == .manual), self.onChange != nil {
            Task { await self.refresh() }
        }
    }

    var visibleProviders: [UsageProvider] {
        UsageProvider.allCases.filter { self.enabledProviders.contains($0) }
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        self.enabledProviders.contains(provider)
    }

    func windows(for provider: UsageProvider) -> [RateWindow] {
        self.results[provider]?.windows ?? []
    }

    var cursorAutoWindow: RateWindow? {
        guard let result = self.results[.cursor],
              let index = result.windowTitles.firstIndex(of: "Cursor"),
              result.windows.indices.contains(index)
        else { return nil }
        return result.windows[index]
    }

    func refresh() async {
        guard !self.isRefreshing else {
            if self.refreshingGeneration != self.generation { self.refreshAgain = true }
            return
        }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        repeat {
            self.refreshAgain = false
            let generation = self.generation
            self.refreshingGeneration = generation
            let fetched = await self.fetch(self.visibleProviders)
            if generation == self.generation {
                for result in fetched where self.isEnabled(result.provider) {
                    self.results[result.provider] = result
                }
                self.onChange?()
            }
        } while self.refreshAgain
    }

    private func fetch(_ providers: [UsageProvider]) async -> [ProviderFetchResult] {
        // Automatic refresh, menu opening, and settings can ask for the same quota.
        // Share only active requests; completed tasks and their response data are released.
        let tasks = providers.map { provider in
            if let task = self.inFlight[provider] { return task }
            let credentials = self.configuration.credentials
            let generation = self.generation
            let task = Task {
                let result = await ProviderFetch.fetch(provider, credentials: credentials)
                if generation == self.generation { self.inFlight[provider] = nil }
                return result
            }
            self.inFlight[provider] = task
            return task
        }
        var fetched: [ProviderFetchResult] = []
        for task in tasks {
            fetched.append(await task.value)
        }
        return fetched
    }

    var menuBarPercent: Double? {
        guard self.isEnabled(self.menuBarProvider),
              let result = self.results[self.menuBarProvider]
        else { return nil }
        let window: RateWindow?
        switch self.menuBarMetric {
        case .session:
            window = result.windows.first { $0.windowMinutes == 300 }
        case .weekly:
            window = result.windows.first { $0.windowMinutes == 7 * 24 * 60 }
        case .monthly:
            window = result.windows.first { $0.windowMinutes == 30 * 24 * 60 }
        case .balance:
            return nil
        case .total, .cursor, .thirdParty, .grokBot:
            let title: String = switch self.menuBarMetric {
            case .total: "Total"
            case .cursor: "Cursor"
            case .thirdParty: "Third Party"
            case .grokBot: "Grok Bot"
            default: ""
            }
            window = result.windowTitles.firstIndex(of: title)
                .flatMap { result.windows.indices.contains($0) ? result.windows[$0] : nil }
        case .keyLimit:
            window = result.windows.first
        }
        guard let window else { return nil }
        return self.menuBarPercentMode == .remaining ? window.remainingPercent : window.usedPercent
    }
}
