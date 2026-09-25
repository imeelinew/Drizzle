import Foundation

enum ResetTimeDisplayStyle: String {
    case countdown
    case absolute
}

enum UsageFormatter {
    private static func localized(_ key: String) -> String {
        L(key)
    }

    private static func localized(_ key: String, _ args: CVarArg...) -> String {
        String(format: L(key), locale: Locale(identifier: "zh_CN"), arguments: args)
    }

    public static func percentText(_ percent: Double, suffix: String) -> String {
        let clamped = min(100, max(0, percent))
        if clamped > 0, clamped < 1 {
            return self.localized("<1%% %@", suffix)
        }
        return self.localized("%.0f%% %@", clamped, suffix)
    }

    public static func usageLine(remaining: Double, used: Double, showUsed: Bool) -> String {
        let percent = showUsed ? used : remaining
        let suffix = showUsed
            ? self.localized("usage_percent_suffix_used")
            : self.localized("usage_percent_suffix_left")
        return self.percentText(percent, suffix: suffix)
    }

    public static func percentString(_ percent: Double) -> String {
        let clamped = min(100, max(0, percent))
        if clamped > 0, clamped < 1 { return "<1%" }
        return String(format: "%.0f%%", clamped)
    }

    public static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        guard let totalMinutes = self.resetCountdownMinutes(from: date, now: now) else {
            return self.localized("Unknown")
        }
        if totalMinutes == 0 { return "now" }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return "in \(days)天\(hours)小时" }
            if minutes > 0 { return "in \(days)天\(minutes)分钟" }
            return "in \(days)天"
        }
        if hours > 0 {
            if minutes > 0 { return "in \(hours)小时\(minutes)分钟" }
            return "in \(hours)小时"
        }
        return "in \(totalMinutes)分钟"
    }

    private static func resetCountdownMinutes(from date: Date, now: Date) -> Int? {
        let seconds = date.timeIntervalSince(now)
        guard let minutes = Int(exactly: ceil(seconds / 60)) else { return nil }
        return seconds < 1 ? 0 : max(1, minutes)
    }

    public static func resetDescription(from date: Date, now: Date = .init()) -> String {
        // Human-friendly phrasing: today / tomorrow / date+time.
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            let timeStr = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
            return self.localized("reset_tomorrow_format", timeStr)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    public static func resetLine(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date = .init()) -> String?
    {
        if let date = window.resetsAt, self.resetCountdownMinutes(from: date, now: now) != nil {
            if style == .countdown {
                let countdown = self.resetCountdownDescription(from: date, now: now)
                if countdown == "now" {
                    return self.localized("Resets now")
                }
                if countdown.hasPrefix("in ") {
                    return self.localized("Resets in %@", String(countdown.dropFirst(3)))
                }
                return self.localized("Resets %@", countdown)
            }
            let text = self.resetDescription(from: date, now: now)
            return self.localized("Resets %@", text)
        }

        if let desc = window.resetDescription {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lowercased = trimmed.lowercased()
            for prefix in ["resets in ", "reset in "] where lowercased.hasPrefix(prefix) {
                return self.localized("Resets in %@", String(trimmed.dropFirst(prefix.count)))
            }
            for prefix in ["resets ", "reset "] where lowercased.hasPrefix(prefix) {
                return self.localized("Resets %@", String(trimmed.dropFirst(prefix.count)))
            }
            return self.localized("Resets %@", trimmed)
        }
        return nil
    }

    static func updatedString(from date: Date, now: Date = .init()) -> String {
        let delta = now.timeIntervalSince(date)
        guard let elapsedSeconds = Int(exactly: delta.rounded(.towardZero)) else {
            return self.localized("Updated absolute %@", self.localized("Unknown"))
        }
        if elapsedSeconds > -60, elapsedSeconds < 60 {
            return self.localized("Updated just now")
        }
        if let hours = Calendar.current.dateComponents([.hour], from: date, to: now).hour, hours < 24 {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "zh_CN")
            rel.unitsStyle = .abbreviated
            return self.localized("Updated relative %@", rel.localizedString(for: date, relativeTo: now))
        }
        return self.localized("Updated absolute %@", date.formatted(date: .abbreviated, time: .omitted))
    }
}
