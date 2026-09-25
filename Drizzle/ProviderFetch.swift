import Foundation
import SQLite3

struct ProviderFetchResult {
    var provider: UsageProvider
    var plan: String?
    var windows: [RateWindow]
    var windowTitles: [String] = []
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
        do {
            let cookie = try CursorCredential.cookieHeader(manual: DrizzleSecrets.cursorCookie)
            var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let json = try await self.json(request)
            let individual = json["individualUsage"] as? [String: Any]
            let plan = individual?["plan"] as? [String: Any]
            let overall = individual?["overall"] as? [String: Any]
            let team = json["teamUsage"] as? [String: Any]
            let pooled = team?["pooled"] as? [String: Any]
            let cycleStart = self.date(json["billingCycleStart"])
            let reset = self.date(json["billingCycleEnd"])
            let cycleMinutes = self.windowMinutes(start: cycleStart, end: reset)
            let auto = self.percent(plan?["autoPercentUsed"])
            let api = self.percent(plan?["apiPercentUsed"])
            let splitPercent: Double?
            if let auto, let api {
                splitPercent = (auto + api) / 2
            } else {
                splitPercent = auto ?? api
            }
            let percent: Double? = self.percent(plan?["totalPercentUsed"])
                ?? splitPercent
                ?? self.ratio(used: plan?["used"], limit: plan?["limit"])
                ?? self.ratio(used: overall?["used"], limit: overall?["limit"])
                ?? self.ratio(used: pooled?["used"], limit: pooled?["limit"])
            guard let percent else {
                return self.failure(.cursor, "Cursor 没有返回套餐额度")
            }
            var windows = [RateWindow(
                usedPercent: min(100, max(0, percent)),
                windowMinutes: cycleMinutes,
                resetsAt: reset,
                resetDescription: nil)]
            var titles = ["Total"]
            if let auto {
                windows.append(RateWindow(
                    usedPercent: min(100, max(0, auto)),
                    windowMinutes: cycleMinutes,
                    resetsAt: reset,
                    resetDescription: nil))
                titles.append("Cursor")
            }
            if let api {
                windows.append(RateWindow(
                    usedPercent: min(100, max(0, api)),
                    windowMinutes: cycleMinutes,
                    resetsAt: reset,
                    resetDescription: nil))
                titles.append("Third Party")
            }
            if let sand = await self.cursorSandWindow(cookie: cookie) {
                windows.append(sand)
                titles.append("Grok Bot")
            }
            return ProviderFetchResult(
                provider: .cursor,
                plan: self.cursorPlan(json["membershipType"] as? String),
                windows: windows,
                windowTitles: titles,
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

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    private static func cursorPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let name: String = switch raw.lowercased() {
        case "free": "Free"
        case "free_trial": "Pro Trial"
        case "hobby": "Hobby"
        case "pro", "pro_student": "Pro"
        case "pro_plus": "Pro+"
        case "team": "Team"
        case "enterprise": "Enterprise"
        case "ultra": "Ultra"
        default: raw.capitalized
        }
        return "Cursor \(name)"
    }

    private static func cursorSandWindow(cookie: String) async -> RateWindow? {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let hasLimit = (json["includedLimitZero"] as? Bool).map { !$0 }
            ?? (json["hasNonZeroIncludedLimit"] as? Bool)
        let trialEnd = self.date(json["sandTrialExpiresAt"])
        let hasTrial = hasLimit != true && trialEnd.map { $0 > .now } == true
        guard hasLimit == true || hasTrial,
              let percent = self.percent(json["usagePercent"])
        else { return nil }
        let reset = hasTrial ? nil : self.date(json["nextResetTimestampUtc"])
        return RateWindow(
            usedPercent: min(100, max(0, percent)),
            windowMinutes: self.windowMinutes(start: self.date(json["currentPeriodStart"]), end: reset),
            resetsAt: reset,
            resetDescription: nil)
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

private enum CursorCredential {
    private static let databasePath = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private static let headerPatterns = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
    ]

    static func cookieHeader(manual: String) throws -> String {
        if let header = self.normalize(manual) {
            guard header.contains("=") else {
                throw ProviderFetchError.missing("Cursor Cookie 格式无效")
            }
            return header
        }
        guard let token = self.loadAppToken() else {
            throw ProviderFetchError.missing("找不到 Cursor 登录，请在 Cursor 登录或在设置里粘贴 Cookie")
        }
        return try self.cookieHeader(accessToken: token)
    }

    private static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for pattern in self.headerPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: value,
                      range: NSRange(value.startIndex..<value.endIndex, in: value)),
                  let range = Range(match.range(at: 1), in: value)
            else { continue }
            value = String(value[range])
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func loadAppToken() -> String? {
        guard FileManager.default.fileExists(atPath: self.databasePath) else { return nil }
        if let token = self.readToken(immutable: false) { return token }
        guard !FileManager.default.fileExists(atPath: self.databasePath + "-wal"),
              !FileManager.default.fileExists(atPath: self.databasePath + "-shm")
        else { return nil }
        return self.readToken(immutable: true)
    }

    private static func readToken(immutable: Bool) -> String? {
        var database: OpaquePointer?
        let url = URL(fileURLWithPath: self.databasePath)
        let path = immutable ? url.absoluteString + "?immutable=1" : self.databasePath
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if data.count.isMultiple(of: 2),
               stride(from: 0, to: data.count, by: 2).allSatisfy({
                   (1..<128).contains(data[$0]) && data[$0 + 1] == 0
               }),
               let value = String(data: data, encoding: .utf16LittleEndian)
            {
                return value
            }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }

    private static func cookieHeader(accessToken: String) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw ProviderFetchError.missing("Cursor 登录令牌无效，请重新登录")
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String,
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last,
              !userID.isEmpty,
              userID.unicodeScalars.allSatisfy(
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains),
              let expiration = json["exp"] as? NSNumber
        else {
            throw ProviderFetchError.missing("Cursor 登录令牌无效，请重新登录")
        }
        guard Date(timeIntervalSince1970: expiration.doubleValue).timeIntervalSinceNow > 60 else {
            throw ProviderFetchError.missing("Cursor 登录已过期，请重新登录")
        }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }
}
