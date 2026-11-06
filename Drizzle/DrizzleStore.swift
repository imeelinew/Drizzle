import Foundation
import CryptoKit

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
    case quota

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
        case .quota: "最低剩余额度"
        }
    }

    static func options(for provider: UsageProvider) -> [Self] {
        switch provider {
        case .codex, .claude, .zai: [.session, .weekly]
        case .cursor: [.total, .cursor, .thirdParty, .grokBot]
        case .openrouter: [.keyLimit]
        case .opencodego: [.session, .weekly, .monthly]
        case .deepseek: [.balance]
        case .googleaipro: [.quota, .session, .weekly]
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

    private struct Snapshot: Codable {
        var credentialID: String
        var results: [ProviderFetchResult]
    }

    private static var snapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drizzle/latest-usage.json")
    }

    private var credentialID: String {
        SHA256.hash(data: Data(String(reflecting: self.configuration.credentials).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    init() {
        self.restoreSnapshot()
    }

    private func restoreSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.credentialID == self.credentialID else { return }
        for var result in snapshot.results where self.isEnabled(result.provider) {
            result.message = "显示上次成功数据，等待更新"
            result.retryable = true
            self.results[result.provider] = result
        }
    }

    private func saveSnapshot() {
        let results = self.results.values.filter { !$0.windows.isEmpty || $0.balance != nil }
            .map { result in
                var result = result
                result.message = nil
                return result
            }
        guard let data = try? JSONEncoder().encode(
            Snapshot(credentialID: self.credentialID, results: results)) else { return }
        let url = Self.snapshotURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A cache write must never interfere with live quota updates.
        }
    }

    var hasRefreshFailures: Bool {
        self.visibleProviders.contains { self.results[$0]?.retryable == true }
    }

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
            if previous.credentials != configuration.credentials {
                self.results.removeAll()
                self.restoreSnapshot()
            }
            self.results = self.results.filter { self.isEnabled($0.key) }
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
        let enabled = self.enabledProviders
        // `providerOrder` wins; enabled providers it leaves out follow in the default registry order.
        var ordered: [UsageProvider] = []
        for rawValue in self.configuration.providerOrder {
            guard let provider = UsageProvider(rawValue: rawValue),
                  enabled.contains(provider),
                  !ordered.contains(provider)
            else { continue }
            ordered.append(provider)
        }
        ordered.append(contentsOf: UsageProvider.allCases.filter { enabled.contains($0) && !ordered.contains($0) })
        return ordered
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
                    if let message = result.message, result.windows.isEmpty, result.balance == nil,
                       var previous = self.results[result.provider],
                       !previous.windows.isEmpty || previous.balance != nil {
                        previous.retryable = result.retryable
                        previous.message = "更新失败，显示上次成功数据：\(message)"
                        self.results[result.provider] = previous
                    } else {
                        self.results[result.provider] = result
                    }
                }
                self.saveSnapshot()
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
            window = result.windows.filter { $0.windowMinutes == 300 }.max { $0.usedPercent < $1.usedPercent }
        case .weekly:
            window = result.windows.filter { $0.windowMinutes == 7 * 24 * 60 }.max { $0.usedPercent < $1.usedPercent }
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
        case .quota:
            window = result.windows.max { $0.usedPercent < $1.usedPercent }
        case .keyLimit:
            window = result.windows.first
        }
        guard let window else { return nil }
        return self.menuBarPercentMode == .remaining ? window.remainingPercent : window.usedPercent
    }
}
