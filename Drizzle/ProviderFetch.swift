import Foundation

struct ProviderFetchResult {
    var provider: UsageProvider
    var plan: String?
    var windows: [RateWindow]
    var message: String?
    var updatedAt: Date
    var balance: String? = nil
}

enum ProviderFetch {
    static func fetch(_ providers: [UsageProvider]) async -> [ProviderFetchResult] {
        await withTaskGroup(of: ProviderFetchResult.self) { group in
            for provider in providers {
                group.addTask {
                    switch provider {
                    case .codex: await self.codex()
                    case .claude: await self.claude()
                    case .cursor: await self.cursor()
                    case .zai: await self.zai()
                    case .openrouter: await self.openrouter()
                    }
                }
            }
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
        let cookie = DrizzleSecrets.cursorCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            return self.failure(.cursor, "在设置里粘贴 Cursor 的 Cookie")
        }
        do {
            var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let json = try await self.json(request)
            let individual = json["individualUsage"] as? [String: Any]
            let plan = individual?["plan"] as? [String: Any]
            let overall = individual?["overall"] as? [String: Any]
            let reset = self.date(json["billingCycleEnd"])
            let auto = self.percent(plan?["autoPercentUsed"])
            let api = self.percent(plan?["apiPercentUsed"])
            let percent: Double? = self.percent(plan?["totalPercentUsed"])
                ?? self.ratio(used: plan?["used"], limit: plan?["limit"])
                ?? self.ratio(used: overall?["used"], limit: overall?["limit"])
                ?? {
                    if let auto, let api { return (auto + api) / 2 }
                    return auto ?? api
                }()
            guard let percent else {
                return self.failure(.cursor, "Cursor 没有返回套餐额度")
            }
            return ProviderFetchResult(
                provider: .cursor,
                plan: (json["membershipType"] as? String)?.capitalized,
                windows: [RateWindow(
                    usedPercent: min(100, max(0, percent)),
                    windowMinutes: 30 * 24 * 60,
                    resetsAt: reset,
                    resetDescription: nil)],
                message: nil,
                updatedAt: .now)
        } catch {
            return self.failure(.cursor, error.localizedDescription)
        }
    }

    static func zai() async -> ProviderFetchResult {
        let apiKey = DrizzleSecrets.zaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return self.failure(.zai, "在设置里填写 z.ai API key")
        }
        let base = DrizzleSecrets.zaiRegion == "bigmodel-cn" ? "https://open.bigmodel.cn" : "https://api.z.ai"
        do {
            var request = URLRequest(url: URL(string: "\(base)/api/monitor/usage/quota/limit")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let json = try await self.json(request)
            let data = json["data"] as? [String: Any]
            let limits = data?["limits"] as? [[String: Any]] ?? []
            let windows = limits.compactMap(self.zaiWindow).sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
            guard !windows.isEmpty else {
                return self.failure(.zai, "z.ai 没有返回会话或周额度")
            }
            let plan = (data?["planName"] as? String) ?? (data?["level"] as? String)
            return ProviderFetchResult(provider: .zai, plan: plan, windows: windows, message: nil, updatedAt: .now)
        } catch {
            return self.failure(.zai, error.localizedDescription)
        }
    }

    static func openrouter() async -> ProviderFetchResult {
        let apiKey = DrizzleSecrets.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return self.failure(.openrouter, "在设置里填写 OpenRouter API key")
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var creditsRequest = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        creditsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        creditsRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        // The two endpoints supply independent parts of the current account state
        let keyPayload = try? await self.json(request)
        let creditsPayload = try? await self.json(creditsRequest)
        guard keyPayload != nil || creditsPayload != nil else {
            return self.failure(.openrouter, "OpenRouter 请求失败")
        }
        let data = keyPayload?["data"] as? [String: Any]
        let creditsData = creditsPayload?["data"] as? [String: Any]
        let limit = self.percent(data?["limit"])
        let usage = self.percent(data?["usage"])
            ?? {
                guard let limit, let remaining = self.percent(data?["limit_remaining"]) else { return nil }
                return limit - remaining
            }()
        let windows: [RateWindow]
        if let limit, limit > 0, let usage {
            windows = [RateWindow(
                usedPercent: min(100, max(0, usage / limit * 100)),
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil)]
        } else {
            windows = []
        }
        let balance: String? = {
            guard let total = self.percent(creditsData?["total_credits"]),
                  let used = self.percent(creditsData?["total_usage"]),
                  total.isFinite, used.isFinite else { return nil }
            return String(format: "$%.2f", max(0, total - used))
        }()
        return ProviderFetchResult(
            provider: .openrouter,
            plan: nil,
            windows: windows,
            message: windows.isEmpty && balance == nil ? "没有可用的额度或余额" : nil,
            updatedAt: .now,
            balance: balance)
    }

    private static func percent(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
    }

    private static func ratio(used: Any?, limit: Any?) -> Double? {
        guard let used = self.percent(used), let limit = self.percent(limit), limit > 0 else { return nil }
        return used / limit * 100
    }

    private static func zaiWindow(_ raw: [String: Any]) -> RateWindow? {
        guard let type = raw["type"] as? String, type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT",
              let reportedPercent = self.percent(raw["percentage"])
        else { return nil }
        let unit = raw["unit"] as? Int ?? 0
        let number = raw["number"] as? Int ?? 0
        let multipliers = [1: 1440, 3: 60, 5: 1, 6: 10080]
        guard let multiplier = multipliers[unit], number > 0 else { return nil }
        let minutes = number * multiplier
        guard minutes == 300 || minutes == 10080 else { return nil }
        let reset = self.percent(raw["nextResetTime"])
        let total = self.percent(raw["usage"])
        let current = self.percent(raw["currentValue"])
        let remaining = self.percent(raw["remaining"])
        let percent: Double
        if let total, total > 0 {
            let used = max(current ?? 0, remaining.map { total - $0 } ?? 0)
            percent = (current != nil || remaining != nil) ? used / total * 100 : reportedPercent
        } else {
            percent = reportedPercent
        }
        return RateWindow(
            usedPercent: min(100, max(0, percent)),
            windowMinutes: minutes,
            resetsAt: reset.map { Date(timeIntervalSince1970: $0 / 1000) },
            resetDescription: nil)
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
