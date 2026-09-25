import Foundation

struct ProviderFetchResult {
    var provider: UsageProvider
    var plan: String?
    var windows: [RateWindow]
    var message: String?
    var updatedAt: Date
}

enum ProviderFetch {
    static func fetchAll() async -> [ProviderFetchResult] {
        await withTaskGroup(of: ProviderFetchResult.self) { group in
            group.addTask { await self.codex() }
            group.addTask { await self.claude() }
            group.addTask { await self.cursor() }
            group.addTask { await self.zai() }
            group.addTask { await self.deepseek() }
            group.addTask { await self.openrouter() }
            var results: [ProviderFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    static func codex() async -> ProviderFetchResult {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tokens = json?["tokens"] as? [String: Any]
            guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty else {
                throw ProviderFetchError.missing("找不到 Codex 登录，先运行 codex login")
            }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let accountID = tokens?["account_id"] as? String {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            let body = try await self.json(request)
            let rateLimit = body["rate_limit"] as? [String: Any]
            let windows = ["primary_window", "secondary_window"].compactMap { key in
                self.codexWindow(rateLimit?[key] as? [String: Any])
            }
            guard !windows.isEmpty else {
                throw ProviderFetchError.missing("Codex 没有返回会话或周额度")
            }
            return ProviderFetchResult(
                provider: .codex,
                plan: self.codexPlan(tokens?["id_token"] as? String),
                windows: windows,
                message: nil,
                updatedAt: .now)
        } catch {
            return self.failure(.codex, error.localizedDescription)
        }
    }

    static func claude() async -> ProviderFetchResult {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let oauth = json?["claudeAiOauth"] as? [String: Any]
            guard let accessToken = oauth?["accessToken"] as? String, !accessToken.isEmpty else {
                throw ProviderFetchError.missing("找不到 Claude Code 登录，先运行 claude login")
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            let body = try await self.json(request)
            var windows: [RateWindow] = []
            if let session = self.claudeWindow(body["five_hour"], minutes: 5 * 60) {
                windows.append(session)
            }
            if let weekly = self.claudeWindow(body["seven_day"], minutes: 7 * 24 * 60) {
                windows.append(weekly)
            }
            guard !windows.isEmpty else {
                throw ProviderFetchError.missing("Claude Code 没有返回会话或周额度")
            }
            return ProviderFetchResult(
                provider: .claude,
                plan: (oauth?["subscriptionType"] as? String)?.capitalized,
                windows: windows,
                message: nil,
                updatedAt: .now)
        } catch {
            return self.failure(.claude, error.localizedDescription)
        }
    }

    static func cursor() async -> ProviderFetchResult {
        self.failure(.cursor, "Cursor 需要浏览器 Cookie，设置稍后再接")
    }

    static func zai() async -> ProviderFetchResult {
        self.failure(.zai, "z.ai 需要 API key，设置稍后再接")
    }

    static func deepseek() async -> ProviderFetchResult {
        ProviderFetchResult(
            provider: .deepseek,
            plan: nil,
            windows: [],
            message: "DeepSeek 只有余额和花费，没有会话或周额度",
            updatedAt: .now)
    }

    static func openrouter() async -> ProviderFetchResult {
        self.failure(.openrouter, "OpenRouter 需要 API key，设置稍后再接")
    }

    private static func failure(_ provider: UsageProvider, _ message: String) -> ProviderFetchResult {
        ProviderFetchResult(provider: provider, plan: nil, windows: [], message: message, updatedAt: .now)
    }

    private static func codexWindow(_ raw: [String: Any]?) -> RateWindow? {
        guard let raw,
              let used = raw["used_percent"] as? Double ?? (raw["used_percent"] as? Int).map(Double.init),
              let seconds = raw["limit_window_seconds"] as? Double
                ?? (raw["limit_window_seconds"] as? Int).map(Double.init)
        else { return nil }
        let reset = (raw["reset_at"] as? Double) ?? (raw["reset_at"] as? Int).map(Double.init)
        return RateWindow(
            usedPercent: used,
            windowMinutes: Int(seconds / 60),
            resetsAt: reset.map { Date(timeIntervalSince1970: $0) },
            resetDescription: nil)
    }

    private static func claudeWindow(_ value: Any?, minutes: Int) -> RateWindow? {
        guard let object = value as? [String: Any], let used = object["utilization"] as? Double else { return nil }
        let percent = used <= 1 ? used * 100 : used
        return RateWindow(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: self.date(object["resets_at"]),
            resetDescription: nil)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func json(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw ProviderFetchError.http(status)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.missing("返回内容无法解析")
        }
        return object
    }

    private static func codexPlan(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        let raw = (auth?["chatgpt_plan_type"] as? String) ?? (json["chatgpt_plan_type"] as? String)
        return switch raw?.lowercased() {
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "free": "Free"
        default: raw?.capitalized
        }
    }
}

enum ProviderFetchError: LocalizedError {
    case http(Int)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .http(status): "请求失败（HTTP \(status)）"
        case let .missing(message): message
        }
    }
}
