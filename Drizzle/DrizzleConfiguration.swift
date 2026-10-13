import AppKit
import Darwin

struct DrizzleConfiguration: Codable, Equatable, Sendable {
    struct MenuBar: Codable, Equatable, Sendable {
        var provider = "codex"
        var metric = "session"
        var percentMode = "remaining"

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            self.provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? self.provider
            self.metric = try values.decodeIfPresent(String.self, forKey: .metric) ?? self.metric
            self.percentMode = try values.decodeIfPresent(String.self, forKey: .percentMode) ?? self.percentMode
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case provider, metric, percentMode
        }
    }

    struct Credentials: Codable, Equatable, Sendable {
        var cursorCookie = ""
        var zaiKey = ""
        var zaiRegion = "global"
        var openRouterKey = ""
        var openCodeGoKey = ""
        var openCodeGoCookie = ""
        var openCodeGoWorkspaceID = ""
        var deepSeekKey = ""

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            self.cursorCookie = try values.decodeIfPresent(String.self, forKey: .cursorCookie) ?? self.cursorCookie
            self.zaiKey = try values.decodeIfPresent(String.self, forKey: .zaiKey) ?? self.zaiKey
            self.zaiRegion = try values.decodeIfPresent(String.self, forKey: .zaiRegion) ?? self.zaiRegion
            self.openRouterKey = try values.decodeIfPresent(String.self, forKey: .openRouterKey) ?? self.openRouterKey
            self.openCodeGoKey = try values.decodeIfPresent(String.self, forKey: .openCodeGoKey) ?? self.openCodeGoKey
            self.openCodeGoCookie = try values.decodeIfPresent(String.self, forKey: .openCodeGoCookie) ?? self.openCodeGoCookie
            self.openCodeGoWorkspaceID = try values.decodeIfPresent(String.self, forKey: .openCodeGoWorkspaceID) ?? self.openCodeGoWorkspaceID
            self.deepSeekKey = try values.decodeIfPresent(String.self, forKey: .deepSeekKey) ?? self.deepSeekKey
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case cursorCookie, zaiKey, zaiRegion, openRouterKey, openCodeGoKey, openCodeGoCookie, openCodeGoWorkspaceID, deepSeekKey
        }
    }

    var launchAtLogin = false
    var refreshIntervalSeconds = 60
    var refreshOnOpen = true
    var enabledProviders = ["codex", "claude", "cursor", "zai", "openrouter", "opencodego", "deepseek"]
    var menuBar = MenuBar()
    var credentials = Credentials()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        self.launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? self.launchAtLogin
        self.refreshIntervalSeconds = try values.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? self.refreshIntervalSeconds
        self.refreshOnOpen = try values.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? self.refreshOnOpen
        self.enabledProviders = try values.decodeIfPresent([String].self, forKey: .enabledProviders) ?? self.enabledProviders
        self.menuBar = try values.decodeIfPresent(MenuBar.self, forKey: .menuBar) ?? self.menuBar
        self.credentials = try values.decodeIfPresent(Credentials.self, forKey: .credentials) ?? self.credentials
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case launchAtLogin, refreshIntervalSeconds, refreshOnOpen, enabledProviders, menuBar, credentials
    }

    func validate() throws {
        guard RefreshInterval(rawValue: self.refreshIntervalSeconds) != nil else {
            throw ConfigurationError.invalid("refreshIntervalSeconds 必须为 0、60、300、900 或 1800")
        }
        guard self.enabledProviders.allSatisfy({ UsageProvider(rawValue: $0) != nil }),
              Set(self.enabledProviders).count == self.enabledProviders.count else {
            throw ConfigurationError.invalid("enabledProviders 包含未知或重复的供应商")
        }
        guard let provider = UsageProvider(rawValue: self.menuBar.provider) else {
            throw ConfigurationError.invalid("menuBar.provider 无效")
        }
        guard let metric = MenuBarMetric(rawValue: self.menuBar.metric),
              MenuBarMetric.options(for: provider).contains(metric) else {
            throw ConfigurationError.invalid("menuBar.metric 不适用于当前供应商")
        }
        guard MenuBarPercentMode(rawValue: self.menuBar.percentMode) != nil else {
            throw ConfigurationError.invalid("menuBar.percentMode 必须为 remaining 或 used")
        }
        guard ["global", "bigmodel-cn"].contains(self.credentials.zaiRegion) else {
            throw ConfigurationError.invalid("credentials.zaiRegion 必须为 global 或 bigmodel-cn")
        }
    }

    @MainActor
    static func migrate(_ defaults: UserDefaults = .standard) -> Self {
        var configuration = Self()
        configuration.launchAtLogin = LoginItemController.isEnabled
        if let value = defaults.object(forKey: "refreshInterval") as? Int,
           RefreshInterval(rawValue: value) != nil {
            configuration.refreshIntervalSeconds = value
        }
        configuration.refreshOnOpen = defaults.object(forKey: "refreshOnOpen") as? Bool ?? true
        if let saved = defaults.stringArray(forKey: "enabledProviders") {
            configuration.enabledProviders = UsageProvider.allCases.filter { saved.contains($0.rawValue) }.map(\.rawValue)
        }
        let provider = UsageProvider(rawValue: defaults.string(forKey: "menuBarProvider") ?? "") ?? .codex
        configuration.menuBar.provider = provider.rawValue
        let metric = MenuBarMetric(rawValue: defaults.string(forKey: "menuBarMetric") ?? "") ?? .session
        configuration.menuBar.metric = MenuBarMetric.options(for: provider).contains(metric)
            ? metric.rawValue : MenuBarMetric.options(for: provider)[0].rawValue
        configuration.menuBar.percentMode = MenuBarPercentMode(rawValue: defaults.string(forKey: "menuBarPercentMode") ?? "")?.rawValue ?? "remaining"
        configuration.credentials.cursorCookie = defaults.string(forKey: "drizzle.cursorCookie") ?? ""
        configuration.credentials.zaiKey = defaults.string(forKey: "drizzle.zaiKey") ?? ""
        let region = defaults.string(forKey: "drizzle.zaiRegion") ?? "global"
        configuration.credentials.zaiRegion = ["global", "bigmodel-cn"].contains(region) ? region : "global"
        configuration.credentials.openRouterKey = defaults.string(forKey: "drizzle.openrouterKey") ?? ""
        configuration.credentials.openCodeGoKey = defaults.string(forKey: "drizzle.openCodeGoKey") ?? ""
        configuration.credentials.deepSeekKey = defaults.string(forKey: "drizzle.deepSeekKey") ?? ""
        return configuration
    }
}

private struct ConfigurationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys(_ decoder: Decoder, allowed: [String]) throws {
    let values = try decoder.container(keyedBy: ConfigurationKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw ConfigurationError.invalid("配置包含未知字段，请检查字段名称")
    }
}

private enum ConfigurationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

/// Watches the directory for replacement saves, and the file for in-place writes.
/// Only the last decoded configuration is retained, with no polling or response history.
@MainActor
final class ConfigurationController {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Drizzle/config.json")
    private let store: DrizzleStore
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var didLoadConfiguration = false
    private(set) var errorMessage: String? {
        didSet {
            if self.errorMessage != oldValue { self.onErrorChange?() }
        }
    }
    var onErrorChange: (() -> Void)?

    init(store: DrizzleStore) { self.store = store }

    func start() {
        do {
            if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                let migrated = DrizzleConfiguration.migrate()
                self.store.apply(migrated)
                try self.write(migrated)
            }
            self.reload()
            try self.watchDirectory()
        } catch {
            self.errorMessage = "无法创建或读取配置文件"
        }
    }

    func open() {
        do {
            if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                try self.write(self.store.configuration)
            }
            if self.directorySource == nil { try self.watchDirectory() }
            self.reload()
            let url = Self.fileURL
            // Use the user's JSON file association, with TextEdit as the fallback.
            let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    self?.errorMessage = "无法打开配置文件，请在文本编辑器中打开 config.json"
                }
            }
        } catch {
            self.errorMessage = "无法创建或打开配置文件"
        }
    }

    func stop() {
        self.pendingReload?.cancel()
        self.pendingReload = nil
        self.fileSource?.cancel()
        self.fileSource = nil
        self.directorySource?.cancel()
        self.directorySource = nil
    }

    private func write(_ configuration: DrizzleConfiguration) throws {
        let directory = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    private func reload() {
        self.watchFile()
        do {
            let file = try FileHandle(forReadingFrom: Self.fileURL)
            defer { try? file.close() }
            let limit = 256 * 1024
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                throw ConfigurationError.invalid("配置文件不能超过 256 KB")
            }
            let configuration = try JSONDecoder().decode(DrizzleConfiguration.self, from: data)
            try configuration.validate()
            // Apply the login item only on first load or when its configured value changes.
            if !self.didLoadConfiguration || configuration.launchAtLogin != self.store.configuration.launchAtLogin {
                try LoginItemController.setEnabled(configuration.launchAtLogin)
            }
            self.store.apply(configuration)
            self.didLoadConfiguration = true
            self.errorMessage = nil
        } catch let error as ConfigurationError {
            self.errorMessage = "配置错误：\(error.localizedDescription)"
        } catch is DecodingError {
            self.errorMessage = "配置错误：JSON 格式或字段类型无效"
        } catch {
            self.errorMessage = "无法读取配置或应用登录启动设置"
        }
    }

    private func scheduleReload() {
        self.pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        self.pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func watchDirectory() throws {
        let descriptor = Darwin.open(Self.fileURL.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConfigurationError.invalid("无法监听配置文件夹") }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.directorySource = source
        source.resume()
    }

    private func watchFile() {
        self.fileSource?.cancel()
        self.fileSource = nil
        let descriptor = Darwin.open(Self.fileURL.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.fileSource = source
        source.resume()
    }
}
