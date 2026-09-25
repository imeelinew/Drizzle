import Foundation
import Observation

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

enum DrizzleSecrets {
    static let openRouterKeyName = "drizzle.openrouterKey"
    static let zaiKeyName = "drizzle.zaiKey"
    static let zaiRegionName = "drizzle.zaiRegion"
    static let cursorCookieName = "drizzle.cursorCookie"

    static var openRouterKey: String {
        UserDefaults.standard.string(forKey: self.openRouterKeyName) ?? ""
    }

    static var zaiKey: String {
        UserDefaults.standard.string(forKey: self.zaiKeyName) ?? ""
    }

    static var zaiRegion: String {
        UserDefaults.standard.string(forKey: self.zaiRegionName) ?? "global"
    }

    static var cursorCookie: String {
        UserDefaults.standard.string(forKey: self.cursorCookieName) ?? ""
    }
}

@MainActor
@Observable
final class DrizzleStore {
    var results: [UsageProvider: ProviderFetchResult] = [:]
    var selection: ProviderSwitcherSelection = .overview
    var isRefreshing = false
    var openRouterKey = DrizzleSecrets.openRouterKey
    var zaiKey = DrizzleSecrets.zaiKey
    var zaiRegion = DrizzleSecrets.zaiRegion
    var cursorCookie = DrizzleSecrets.cursorCookie
    var onChange: (() -> Void)?
    var onRefreshIntervalChange: (() -> Void)?
    var enabledProviders: Set<UsageProvider> = {
        guard let saved = UserDefaults.standard.stringArray(forKey: "enabledProviders") else {
            return Set(UsageProvider.allCases)
        }
        return Set(saved.compactMap(UsageProvider.init(rawValue:)))
    }()
    var refreshInterval: RefreshInterval = {
        guard let raw = UserDefaults.standard.object(forKey: "refreshInterval") as? Int else { return .oneMinute }
        return RefreshInterval(rawValue: raw) ?? .oneMinute
    }()
    var refreshOnOpen = UserDefaults.standard.object(forKey: "refreshOnOpen") as? Bool ?? true

    var visibleProviders: [UsageProvider] {
        UsageProvider.allCases.filter { self.enabledProviders.contains($0) }
    }

    func isEnabled(_ provider: UsageProvider) -> Bool {
        self.enabledProviders.contains(provider)
    }

    func setEnabled(_ enabled: Bool, for provider: UsageProvider) {
        if enabled {
            self.enabledProviders.insert(provider)
        } else {
            self.enabledProviders.remove(provider)
            self.results.removeValue(forKey: provider)
            if self.selection == .provider(provider.instanceID) { self.selection = .overview }
        }
        UserDefaults.standard.set(self.visibleProviders.map(\.rawValue), forKey: "enabledProviders")
        self.onChange?()
        if enabled { Task { await self.refresh(provider: provider) } }
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        self.refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "refreshInterval")
        self.onRefreshIntervalChange?()
    }

    func setRefreshOnOpen(_ enabled: Bool) {
        self.refreshOnOpen = enabled
        UserDefaults.standard.set(enabled, forKey: "refreshOnOpen")
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

    func saveSecrets() {
        UserDefaults.standard.set(self.openRouterKey, forKey: DrizzleSecrets.openRouterKeyName)
        UserDefaults.standard.set(self.zaiKey, forKey: DrizzleSecrets.zaiKeyName)
        UserDefaults.standard.set(self.zaiRegion, forKey: DrizzleSecrets.zaiRegionName)
        UserDefaults.standard.set(self.cursorCookie, forKey: DrizzleSecrets.cursorCookieName)
    }

    func refresh() async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer {
            self.isRefreshing = false
            self.onChange?()
        }
        let fetched = await ProviderFetch.fetch(self.visibleProviders)
        for result in fetched {
            if self.isEnabled(result.provider) { self.results[result.provider] = result }
        }
    }

    func refresh(provider: UsageProvider) async {
        guard self.isEnabled(provider) else { return }
        let fetched = await ProviderFetch.fetch([provider])
        guard self.isEnabled(provider), let result = fetched.first else { return }
        self.results[provider] = result
        self.onChange?()
    }

    var iconWindows: (session: Double?, weekly: Double?) {
        let provider = self.iconProvider
        let windows = self.windows(for: provider)
        let session = windows.first.map { 100 - $0.usedPercent }
        let weekly = (provider == .cursor ? self.cursorAutoWindow : windows.dropFirst().first)
            .map { 100 - $0.usedPercent }
        return (session, weekly ?? (windows.count == 1 ? nil : weekly))
    }

    var iconProvider: UsageProvider {
        if case let .provider(id) = self.selection, let provider = id.firstPartyProvider,
           self.isEnabled(provider),
           !self.windows(for: provider).isEmpty
        {
            return provider
        }
        return self.visibleProviders.first { !self.windows(for: $0).isEmpty }
            ?? self.visibleProviders.first ?? .codex
    }
}
