import AppKit
import Darwin

struct DrizzleConfiguration: Equatable, Sendable {
    struct MenuBar: Equatable, Sendable {
        static let keys: Set<String> = ["provider", "metric", "percentMode"]

        var provider = "codex"
        var metric = "session"
        var percentMode = "remaining"
    }

    struct Credentials: Equatable, Sendable {
        static let keys: Set<String> = [
            "cursorCookie", "zaiKey", "zaiRegion", "openRouterKey",
            "openCodeGoKey", "openCodeGoCookie", "openCodeGoWorkspaceID", "deepSeekKey",
        ]

        var cursorCookie = ""
        var zaiKey = ""
        var zaiRegion = "global"
        var openRouterKey = ""
        var openCodeGoKey = ""
        var openCodeGoCookie = ""
        var openCodeGoWorkspaceID = ""
        var deepSeekKey = ""
    }

    static let keys: Set<String> = [
        "launchAtLogin", "refreshIntervalSeconds", "refreshOnOpen",
        "enabledProviders", "providerOrder", "menuBar", "credentials",
    ]

    var launchAtLogin = false
    var refreshIntervalSeconds = 60
    var refreshOnOpen = true
    var enabledProviders = ["codex", "claude", "cursor", "zai", "openrouter", "opencodego", "deepseek"]
    /// Switcher tab and quota card order. Providers left out keep their default position, so the
    /// list can be shortened or extended without listing every provider.
    var providerOrder = ["codex", "claude", "cursor", "zai", "openrouter", "opencodego", "deepseek"]
    var menuBar = MenuBar()
    var credentials = Credentials()

    init() {}

    /// Reads a configuration out of a parsed file. A missing field keeps its default, and a field
    /// the app does not know is reported in `warnings` instead of failing the whole file.
    init(toml: TOMLTable, warnings: inout [String]) throws {
        self.init()
        var unknownFields: [TOMLField<String>] = []
        if let field = try toml.boolean("launchAtLogin") { self.launchAtLogin = field.value }
        if let field = try toml.integer("refreshIntervalSeconds") {
            guard RefreshInterval(rawValue: field.value) != nil else {
                throw TOMLParseError(line: field.line, message: "refreshIntervalSeconds 必须为 0、60、300、900 或 1800")
            }
            self.refreshIntervalSeconds = field.value
        }
        if let field = try toml.boolean("refreshOnOpen") { self.refreshOnOpen = field.value }
        if let field = try toml.stringArray("enabledProviders") {
            try Self.checkProviders(field.value, name: "enabledProviders", line: field.line)
            self.enabledProviders = field.value
        }
        if let field = try toml.stringArray("providerOrder") {
            try Self.checkProviders(field.value, name: "providerOrder", line: field.line)
            self.providerOrder = field.value
        }
        if let field = try toml.table("menuBar") {
            try self.readMenuBar(field.value, unknownFields: &unknownFields)
        }
        if let field = try toml.table("credentials") {
            try self.readCredentials(field.value, unknownFields: &unknownFields)
        }
        unknownFields += toml.unknownKeys(Self.keys)
        // Sorted by line so the warnings read top to bottom like the file does.
        warnings += unknownFields
            .sorted { ($0.line, $0.value) < ($1.line, $1.value) }
            .map { Self.warning(for: $0) }
    }

    private mutating func readMenuBar(_ table: TOMLTable, unknownFields: inout [TOMLField<String>]) throws {
        if let field = try table.string("provider") {
            guard UsageProvider(rawValue: field.value) != nil else {
                throw TOMLParseError(line: field.line, message: "menuBar.provider 无效，可选值：\(Self.providerNames)")
            }
            self.menuBar.provider = field.value
        }
        if let field = try table.string("metric") {
            // The metric is only meaningful for the provider it belongs to, so it is checked
            // against the provider read above.
            guard let provider = UsageProvider(rawValue: self.menuBar.provider) else {
                throw TOMLParseError(line: field.line, message: "menuBar.provider 无效，可选值：\(Self.providerNames)")
            }
            guard let metric = MenuBarMetric(rawValue: field.value),
                  MenuBarMetric.options(for: provider).contains(metric) else {
                let options = MenuBarMetric.options(for: provider).map(\.rawValue).joined(separator: "、")
                throw TOMLParseError(line: field.line, message: "menuBar.metric 不适用于 \(provider.rawValue)，可选值：\(options)")
            }
            self.menuBar.metric = field.value
        }
        if let field = try table.string("percentMode") {
            guard MenuBarPercentMode(rawValue: field.value) != nil else {
                throw TOMLParseError(line: field.line, message: "menuBar.percentMode 必须为 remaining 或 used")
            }
            self.menuBar.percentMode = field.value
        }
        unknownFields += table.unknownKeys(MenuBar.keys, prefix: "menuBar.")
    }

    private mutating func readCredentials(_ table: TOMLTable, unknownFields: inout [TOMLField<String>]) throws {
        if let field = try table.string("cursorCookie") { self.credentials.cursorCookie = field.value }
        if let field = try table.string("zaiKey") { self.credentials.zaiKey = field.value }
        if let field = try table.string("zaiRegion") {
            guard ["global", "bigmodel-cn"].contains(field.value) else {
                throw TOMLParseError(line: field.line, message: "credentials.zaiRegion 必须为 global 或 bigmodel-cn")
            }
            self.credentials.zaiRegion = field.value
        }
        if let field = try table.string("openRouterKey") { self.credentials.openRouterKey = field.value }
        if let field = try table.string("openCodeGoKey") { self.credentials.openCodeGoKey = field.value }
        if let field = try table.string("openCodeGoCookie") { self.credentials.openCodeGoCookie = field.value }
        if let field = try table.string("openCodeGoWorkspaceID") { self.credentials.openCodeGoWorkspaceID = field.value }
        if let field = try table.string("deepSeekKey") { self.credentials.deepSeekKey = field.value }
        unknownFields += table.unknownKeys(Credentials.keys, prefix: "credentials.")
    }

    private static func checkProviders(_ values: [String], name: String, line: Int) throws {
        guard values.allSatisfy({ UsageProvider(rawValue: $0) != nil }) else {
            throw TOMLParseError(line: line, message: "\(name) 包含未知的供应商，可选值：\(Self.providerNames)")
        }
        guard Set(values).count == values.count else {
            throw TOMLParseError(line: line, message: "\(name) 包含重复的供应商")
        }
    }

    private static var providerNames: String {
        UsageProvider.allCases.map(\.rawValue).joined(separator: "、")
    }

    private static func warning(for field: TOMLField<String>) -> String {
        field.line > 0
            ? "第 \(field.line) 行已忽略未知字段 \(field.value)"
            : "已忽略未知字段 \(field.value)"
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

extension DrizzleConfiguration {
    /// The commented file written when no configuration file exists yet. Every field the app
    /// understands appears with its current value, so the file itself is the reference for what
    /// can be set.
    var tomlFile: String {
        var text = ""
        func add(_ line: String = "") { text += line + "\n" }

        add("# Drizzle 配置文件")
        add("# 保存后立即生效，无需重启；写错时继续使用上一次的有效配置，并在菜单里显示原因")
        add("# 每一行都可以删掉，删掉的字段使用默认值")
        add()
        add("# 登录时自动启动")
        add("launchAtLogin = \(self.launchAtLogin)")
        add()
        add("# 自动刷新间隔（秒），可选 0（手动）、60、300、900、1800")
        add("refreshIntervalSeconds = \(self.refreshIntervalSeconds)")
        add()
        add("# 打开菜单时是否立即刷新")
        add("refreshOnOpen = \(self.refreshOnOpen)")
        add()
        add("# 开启的供应商，空数组表示全部关闭")
        add("enabledProviders = \(Self.quoted(self.enabledProviders))")
        add()
        add("# 菜单中供应商从上到下的顺序，未列出的已开启供应商按默认顺序排在后面")
        add("providerOrder = \(Self.quoted(self.providerOrder))")
        add()
        add("[menuBar]")
        add("# 菜单栏显示哪个供应商")
        add("provider = \(Self.quoted(self.menuBar.provider))")
        add("# 显示哪项额度：codex、claude、zai 用 session 或 weekly")
        add("# cursor 用 total、cursor、thirdParty、grokBot，openrouter 用 keyLimit")
        add("# opencodego 用 session、weekly、monthly，deepseek 用 balance")
        add("metric = \(Self.quoted(self.menuBar.metric))")
        add("# remaining 显示剩余，used 显示已使用")
        add("percentMode = \(Self.quoted(self.menuBar.percentMode))")
        add()
        add("[credentials]")
        add("# Cursor Cookie，留空则读取 Cursor 本地登录")
        add("cursorCookie = \(Self.quoted(self.credentials.cursorCookie))")
        add("# z.ai API key")
        add("zaiKey = \(Self.quoted(self.credentials.zaiKey))")
        add("# global 或 bigmodel-cn")
        add("zaiRegion = \(Self.quoted(self.credentials.zaiRegion))")
        add("# OpenRouter API key")
        add("openRouterKey = \(Self.quoted(self.credentials.openRouterKey))")
        add("# OpenCode Go：填 key 走 API，留空则读取 OPENCODE_API_KEY")
        add("openCodeGoKey = \(Self.quoted(self.credentials.openCodeGoKey))")
        add("# OpenCode Go：填 Cookie 走 Console，与上面的 key 同时填写时优先使用 Cookie")
        add("openCodeGoCookie = \(Self.quoted(self.credentials.openCodeGoCookie))")
        add("# 可选，org_… 或 wrk_…，留空使用第一个工作区")
        add("openCodeGoWorkspaceID = \(Self.quoted(self.credentials.openCodeGoWorkspaceID))")
        add("# DeepSeek API key，留空则读取 DEEPSEEK_API_KEY 或 DEEPSEEK_KEY")
        add("deepSeekKey = \(Self.quoted(self.credentials.deepSeekKey))")
        return text
    }

    private static func quoted(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    private static func quoted(_ values: [String]) -> String {
        "[" + values.map { Self.quoted($0) }.joined(separator: ", ") + "]"
    }

    /// Reads the JSON object this app used as its configuration file before the format changed.
    /// Unknown keys behave like they do in a TOML file, so an old file still migrates after the
    /// format changed.
    static func tomlTable(fromJSON value: Any) -> TOMLTable? {
        guard let object = value as? [String: Any] else { return nil }
        var table = TOMLTable()
        for (key, raw) in object {
            guard let entry = Self.tomlValue(fromJSON: raw) else { continue }
            _ = try? table.insert(entry, for: key, line: 0)
        }
        return table
    }

    private static func tomlValue(fromJSON value: Any) -> TOMLValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let array as [Any]:
            var elements: [TOMLValue] = []
            for element in array {
                guard let converted = Self.tomlValue(fromJSON: element) else { return nil }
                elements.append(converted)
            }
            return .array(elements)
        case let object as [String: Any]:
            guard let table = Self.tomlTable(fromJSON: object) else { return nil }
            return .table(table)
        case let number as NSNumber:
            return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
                ? .boolean(number.boolValue) : .integer(number.intValue)
        default:
            // `null` and anything else reads like a missing field.
            return nil
        }
    }
}

/// Watches the directory for replacement saves, and the file for in-place writes.
/// Only the last decoded configuration is retained, with no polling or response history.
@MainActor
final class ConfigurationController {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Drizzle/config.toml")
    /// The JSON file this app read before the format changed. It is migrated once, then removed.
    private static let legacyFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Drizzle/config.json")
    /// CotEditor, which is where the configuration file opens.
    private static let editorBundleIdentifier = "com.coteditor.CotEditor"
    private let store: DrizzleStore
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var didLoadConfiguration = false
    private(set) var errorMessage: String? {
        didSet {
            if self.errorMessage != oldValue { self.onStatusChange?() }
        }
    }
    /// Unknown fields are ignored rather than fatal, and listed here so the typo is still visible.
    private(set) var warningMessage: String? {
        didSet {
            if self.warningMessage != oldValue { self.onStatusChange?() }
        }
    }
    var onStatusChange: (() -> Void)?

    init(store: DrizzleStore) { self.store = store }

    func start() {
        do {
            if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                try self.write(Self.migratedConfiguration())
                self.removeLegacyFile()
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
            // CotEditor when it is installed, otherwise the user's TOML association, then TextEdit.
            let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.editorBundleIdentifier)
                ?? NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    self?.errorMessage = "无法打开配置文件，请在文本编辑器中打开 config.toml"
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
        try Data(configuration.tomlFile.utf8).write(to: Self.fileURL, options: .atomic)
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
                throw TOMLParseError(line: 0, message: "配置文件不能超过 256 KB")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw TOMLParseError(line: 0, message: "配置文件必须是 UTF-8 编码")
            }
            var warnings: [String] = []
            let configuration = try DrizzleConfiguration(toml: TOMLParser.parse(text), warnings: &warnings)
            // Apply the login item only on first load or when its configured value changes.
            if !self.didLoadConfiguration || configuration.launchAtLogin != self.store.configuration.launchAtLogin {
                try LoginItemController.setEnabled(configuration.launchAtLogin)
            }
            self.store.apply(configuration)
            self.didLoadConfiguration = true
            self.errorMessage = nil
            self.warningMessage = Self.summarize(warnings)
        } catch let error as TOMLParseError {
            self.errorMessage = "配置错误：\(error.localizedDescription)"
            self.warningMessage = nil
        } catch {
            self.errorMessage = "无法读取配置或应用登录启动设置"
            self.warningMessage = nil
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
        guard descriptor >= 0 else { throw TOMLParseError(line: 0, message: "无法监听配置文件夹") }
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

    /// The menu item cannot wrap, so only the first few unknown fields are listed.
    private static func summarize(_ warnings: [String]) -> String? {
        guard !warnings.isEmpty else { return nil }
        let listed = warnings.prefix(3).joined(separator: "；")
        let rest = warnings.count > 3 ? "（共 \(warnings.count) 处）" : ""
        return "配置警告：\(listed)\(rest)"
    }

    /// The configuration for a first run: the previous JSON file when there is one, otherwise the
    /// settings the app used to keep in user defaults.
    private static func migratedConfiguration() -> DrizzleConfiguration {
        if let table = Self.legacyTable() {
            var warnings: [String] = []
            if let configuration = try? DrizzleConfiguration(toml: table, warnings: &warnings) {
                return configuration
            }
        }
        return DrizzleConfiguration.migrate()
    }

    private static func legacyTable() -> TOMLTable? {
        guard let data = try? Data(contentsOf: Self.legacyFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return DrizzleConfiguration.tomlTable(fromJSON: object)
    }

    /// Drops the previous JSON file once its contents are in the new one, so there is no second
    /// file to keep in step or to edit by mistake.
    private func removeLegacyFile() {
        try? FileManager.default.removeItem(at: Self.legacyFileURL)
    }
}
