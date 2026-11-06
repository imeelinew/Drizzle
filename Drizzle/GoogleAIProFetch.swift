import Foundation
import Darwin

/// Adapted from CodexBar b9ba2da9a: AntigravityStatusProbe,
/// AntigravityQuotaSummaryParser and AntigravityCLIHTTPSFetchStrategy.
/// Consumer Google AI Pro quotas now come from Antigravity, not Gemini CLI.
enum GoogleAIProFetch {
    private struct Endpoint {
        let port: Int
        let token: String
        var scheme = "https"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
    }()

    static func fetch() async -> ProviderFetchResult {
        do {
            // Native app/IDE servers expose identity as well as model quota. Only probe
            // same-user Antigravity processes and their own listening sockets.
            if let result = try? await localUsage() { return result }
            return try await cliUsage()
        } catch {
            return ProviderFetchResult(
                provider: .googleaipro, plan: nil, windows: [],
                message: (error as? FetchError)?.localizedDescription
                    ?? "Google AI Pro 额度读取失败，请检查网络并重新运行 agy 登录后刷新",
                updatedAt: .now,
                retryable: error is URLError)
        }
    }

    private static func localUsage() async throws -> ProviderFetchResult {
        let output = try await command("/bin/ps", ["-axo", "pid=,uid=,comm=,args="], timeout: 3)
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        let deadline = Date.now.addingTimeInterval(10)
        for line in lines {
            try Task.checkCancellation()
            guard Date.now < deadline else { break }
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, let pid = Int(fields[0]), UInt32(fields[1]) == getuid() else { continue }
            let executable = String(fields[2]).lowercased()
            let arguments = String(fields[3])
            let isServer = executable.contains("language_server") || executable.contains("language-server")
            let isGoogleApp = ["/antigravity.app/", "/antigravity ide.app/", "/gemini.app/", "/antigravity/"]
                .contains { executable.contains($0) }
            let isCLI = ["agy", "antigravity-cli", "antigravity_cli"].contains((executable as NSString).lastPathComponent)
            guard (isServer && isGoogleApp) || isCLI else { continue }
            let token = flag("--csrf_token", in: arguments) ?? ""
            guard isCLI || !token.isEmpty else { continue }
            guard let sockets = try? await command(
                "/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], timeout: 2)
            else { continue }
            let ports = String(decoding: sockets, as: UTF8.self).split(separator: "\n").compactMap { line -> Int? in
                guard line.hasPrefix("n"), let raw = line.split(separator: ":").last,
                      let port = Int(raw), (1...65535).contains(port) else { return nil }
                return port
            }
            var endpoints = Set(ports).sorted().map { Endpoint(port: $0, token: token) }
            if !isCLI, let raw = flag("--extension_server_port", in: arguments), let port = Int(raw),
               (1...65535).contains(port) {
                endpoints.append(Endpoint(
                    port: port, token: flag("--extension_server_csrf_token", in: arguments) ?? token,
                    scheme: "http"))
            }
            for endpoint in endpoints {
                guard Date.now < deadline else { break }
                let identity = try? await request("GetUserStatus", body: ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]], endpoint: endpoint)
                if let raw = try? await request("RetrieveUserQuotaSummary", body: ["forceRefresh": true], endpoint: endpoint),
                   let result = try? summary(raw, plan: plan(identity)) { return result }
                if let identity, let result = try? models(identity) { return result }
            }
        }
        throw FetchError.unavailable("请打开 Antigravity 并登录，或运行 agy 登录后刷新")
    }

    private static func request(_ method: String, body: [String: Any], endpoint: Endpoint) async throws -> [String: Any] {
        let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.token.isEmpty { request.setValue(endpoint.token, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], validCode(json)
        else { throw FetchError.unavailable("Antigravity 本地额度暂不可用") }
        return json
    }

    private static func cliUsage() async throws -> ProviderFetchResult {
        let environment = ProcessInfo.processInfo.environment
        let binary: String
        if let explicit = environment["ANTIGRAVITY_CLI_PATH"] {
            guard !explicit.isEmpty, FileManager.default.isExecutableFile(atPath: explicit) else {
                throw FetchError.unavailable("ANTIGRAVITY_CLI_PATH 必须指向可执行的 agy")
            }
            binary = explicit
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            guard let found = paths.map({ $0 + "/agy" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw FetchError.unavailable("请安装 Antigravity CLI（agy 1.1.11 或更新版本）并运行 agy 登录，或打开已登录的 Antigravity 应用")
            }
            binary = found
        }
        var env = environment
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        let versionData = try await command(binary, ["--version"], environment: env, timeout: 3)
        let version = String(decoding: versionData, as: UTF8.self)
        guard let match = version.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#, options: .regularExpression),
              version[match].compare("1.1.11", options: .numeric) != .orderedAscending else {
            throw FetchError.unavailable("Google AI Pro 额度查询需要 agy 1.1.11 或更新版本")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drizzle-google-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // A passive refresh must never open browser sign-in or trigger CLI updates.
        for name in ["open", "xdg-open"] {
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: directory.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        env["PATH"] = directory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["BROWSER"] = directory.appendingPathComponent("open").path
        let data = try await command(
            binary, ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"],
            environment: env, directory: directory, timeout: 90)
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["status"] as? String == "SUCCESS",
              let command = report["command"] as? [String: Any], command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any] else {
            throw FetchError.unavailable("agy 未返回有效额度，请在终端运行 agy 检查登录与订阅")
        }
        return try summary(payload, plan: nil)
    }

    private static func summary(_ json: [String: Any], plan: String?) throws -> ProviderFetchResult {
        guard validCode(json) else { throw FetchError.unavailable("Google AI Pro 额度暂不可用") }
        let payload = json["response"] as? [String: Any] ?? json["summary"] as? [String: Any] ?? json
        let groups = payload["groups"] as? [[String: Any]] ?? []
        var rows: [(String, RateWindow, Int)] = []
        let sortedGroups = groups.sorted { groupRank($0) < groupRank($1) }
        for (groupIndex, group) in sortedGroups.enumerated() {
            let name = text(group, "displayName", "display_name", "name") ?? "Quota"
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let nested = bucket["remaining"] as? [String: Any]
                let fraction = number(bucket, "remainingFraction", "remaining_fraction")
                    ?? nested.flatMap { number($0, "remainingFraction", "remaining_fraction") }
                    ?? ((nested?["case"] as? String == "remainingFraction") ? number(nested ?? [:], "value") : nil)
                guard bucket["disabled"] as? Bool != true, let fraction, fraction.isFinite else { continue }
                let label = text(bucket, "displayName", "display_name", "name", "bucketId", "bucket_id", "id") ?? "Quota"
                let explicit = text(bucket, "window")
                let cadence = (explicit ?? ((text(bucket, "bucketId", "bucket_id", "id") ?? "") + " " + label))
                    .lowercased().replacingOccurrences(of: "_", with: "-")
                let minutes: Int? = ["session", "5h", "5-hour", "five-hour", "five hour"].contains(where: { cadence.contains($0) })
                    ? 300 : cadence.contains("weekly") ? 10080 : nil
                let title = displayGroup(name) + " " + (minutes == 300 ? "5-hour" : minutes == 10080 ? "weekly" : label)
                rows.append((title, RateWindow(
                    usedPercent: 100 - min(1, max(0, fraction)) * 100,
                    windowMinutes: minutes, resetsAt: date(text(bucket, "resetTime", "reset_time")),
                    resetDescription: nil), groupIndex))
            }
        }
        guard !rows.isEmpty else { throw FetchError.unavailable("Google AI Pro 暂未提供可用额度，请检查 Antigravity 登录与订阅") }
        // Keep the source's model groups together, with the shorter cadence first.
        rows.sort { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            let leftMinutes = lhs.1.windowMinutes ?? Int.max
            let rightMinutes = rhs.1.windowMinutes ?? Int.max
            if leftMinutes != rightMinutes { return leftMinutes < rightMinutes }
            return lhs.0 < rhs.0
        }
        return ProviderFetchResult(provider: .googleaipro, plan: plan, windows: rows.map(\.1), windowTitles: rows.map(\.0), message: nil, updatedAt: .now)
    }

    private static func displayGroup(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini"), !name.contains(where: \.isNumber) { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name
    }

    private static func groupRank(_ group: [String: Any]) -> String {
        let name = text(group, "displayName", "display_name", "name") ?? "Quota"
        let lower = name.lowercased()
        if lower.contains("gemini"), !name.contains(where: \.isNumber) { return "0" + name }
        if lower.contains("claude") || lower.contains("gpt") { return "1" + name }
        return "2" + name
    }

    private static func models(_ json: [String: Any]) throws -> ProviderFetchResult {
        let status = json["userStatus"] as? [String: Any] ?? [:]
        let config = status["cascadeModelConfigData"] as? [String: Any] ?? [:]
        var rows: [(String, RateWindow)] = []
        for model in config["clientModelConfigs"] as? [[String: Any]] ?? [] {
            guard let quota = model["quotaInfo"] as? [String: Any],
                  let remaining = number(quota, "remainingFraction"), remaining.isFinite,
                  let label = text(model, "label") else { continue }
            rows.append((label, RateWindow(usedPercent: 100 - min(1, max(0, remaining)) * 100,
                                          windowMinutes: nil, resetsAt: date(text(quota, "resetTime")), resetDescription: nil)))
        }
        guard !rows.isEmpty else { throw FetchError.unavailable("Antigravity 暂未返回模型额度") }
        return ProviderFetchResult(provider: .googleaipro, plan: plan(json), windows: rows.map(\.1), windowTitles: rows.map(\.0), message: nil, updatedAt: .now)
    }

    private static func plan(_ json: [String: Any]?) -> String? {
        let status = json?["userStatus"] as? [String: Any] ?? [:]
        if let tier = status["userTier"] as? [String: Any], let name = text(tier, "name") { return name }
        let planStatus = status["planStatus"] as? [String: Any]
        let info = planStatus?["planInfo"] as? [String: Any] ?? [:]
        return text(info, "planDisplayName", "displayName", "productName", "planName", "planShortName")
    }

    private static func text(_ json: [String: Any], _ keys: String...) -> String? {
        keys.compactMap { json[$0] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func number(_ json: [String: Any], _ keys: String...) -> Double? {
        keys.compactMap { json[$0] as? Double }.first
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? Double(text).map { Date(timeIntervalSince1970: $0) }
    }

    private static func validCode(_ json: [String: Any]) -> Bool {
        guard let code = json["code"] else { return true }
        return ["0", "ok", "success"].contains(String(describing: code).lowercased())
    }

    private static func flag(_ name: String, in arguments: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"[=\s]+([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
              let range = Range(match.range(at: 1), in: arguments) else { return nil }
        return String(arguments[range])
    }

    private enum FetchError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case let .unavailable(message): message }
        }
    }

    /// Bounded subprocesses with private files and a dedicated process group, so
    /// cancellation/timeout also stops child processes. Never expose raw CLI diagnostics.
    private static func command(
        _ binary: String, _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL? = nil, timeout: TimeInterval
    ) async throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drizzle-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let output = root.appendingPathComponent("stdout")
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if let directory {
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, directory.path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([binary] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, binary, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw FetchError.unavailable("无法启动 Google 额度查询，请检查 Antigravity 安装") }
        var reaped = false
        defer {
            kill(-pid, SIGKILL)
            if !reaped { var status: Int32 = 0; waitpid(pid, &status, 0) }
        }
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 1_048_576 else { throw FetchError.unavailable("Google 额度查询返回内容过大") }
            var status: Int32 = 0
            let finished = waitpid(pid, &status, WNOHANG)
            if finished == pid {
                reaped = true
                guard status == 0 else {
                    throw FetchError.unavailable("Google 额度查询失败，请在终端运行 agy 检查登录、订阅与网络后刷新")
                }
                let data = try Data(contentsOf: output)
                guard data.count <= 1_048_576 else { throw FetchError.unavailable("Google 额度查询返回内容过大") }
                return data
            }
            guard finished >= 0, Date.now < deadline else { throw FetchError.unavailable("Google 额度查询超时，请检查 Antigravity 登录与网络后刷新") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private final class LoopbackTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            trust(challenge)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            trust(challenge)
        }
        private func trust(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.host == "127.0.0.1",
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil // Keep local CSRF tokens on the discovered loopback endpoint.
        }
    }
}
