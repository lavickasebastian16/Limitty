import Foundation

/// Helpers for the loosely-typed JSON these endpoints return.
enum JSON {
    static func object(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// ISO-8601 (with or without fractional seconds), epoch seconds or epoch ms.
    static func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let n = Double(s) { return date(n) }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            // Microsecond precision (e.g. ".123456+00:00") trips the formatter: drop the fraction.
            if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
                return f.date(from: s.replacingCharacters(in: r, with: ""))
            }
            return nil
        }
        guard let n = number(v) else { return nil }
        return Date(timeIntervalSince1970: n < 1e12 ? n : n / 1000)
    }

    static func clampPercent(_ v: Double) -> Double { min(100, max(0, v)) }
}

public enum ClaudeParser {
    static let labels: [(key: String, label: String)] = [
        ("five_hour", "Session"),
        ("seven_day", "Weekly"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
    ]

    /// Parses claude.ai `/api/organizations/{id}/usage`.
    public static func windows(from data: Data) -> [LimitWindow] {
        guard let obj = JSON.object(data) as? [String: Any] else { return [] }
        var out: [LimitWindow] = []
        for (key, value) in obj {
            guard let w = value as? [String: Any], let used = JSON.number(w["utilization"]) else { continue }
            let label = labels.first { $0.key == key }?.label ?? key.replacingOccurrences(of: "_", with: " ")
            out.append(LimitWindow(id: key, label: label, usedPercent: JSON.clampPercent(used), resetsAt: JSON.date(w["resets_at"])))
        }
        let order = labels.map(\.key)
        return out.sorted {
            (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id)
        }
    }

    public struct Org: Equatable { public var uuid: String; public var plan: String? }

    /// Picks the chat organization from `/api/organizations`.
    public static func org(from data: Data) -> Org? {
        guard let arr = JSON.object(data) as? [[String: Any]], !arr.isEmpty else { return nil }
        let caps = { (o: [String: Any]) in (o["capabilities"] as? [String]) ?? [] }
        let o = arr.first { caps($0).contains("chat") } ?? arr[0]
        guard let uuid = o["uuid"] as? String else { return nil }
        let c = caps(o)
        let plan: String? = c.contains("claude_max") ? "Max" : c.contains("claude_pro") ? "Pro" : c.contains("raven") ? "Team" : nil
        return Org(uuid: uuid, plan: plan)
    }
}

public enum CodexParser {
    /// Parses chatgpt.com `/backend-api/wham/usage`.
    public static func snapshot(from data: Data, now: Date = Date()) -> (plan: String?, windows: [LimitWindow]) {
        guard let obj = JSON.object(data) as? [String: Any] else { return (nil, []) }
        let rl = obj["rate_limit"] as? [String: Any] ?? [:]
        func window(_ id: String, _ any: Any?) -> LimitWindow? {
            guard let w = any as? [String: Any], let used = JSON.number(w["used_percent"]) else { return nil }
            var reset = JSON.date(w["reset_at"])
            if reset == nil, let after = JSON.number(w["reset_after_seconds"]) { reset = now.addingTimeInterval(after) }
            return LimitWindow(id: id, label: label(seconds: JSON.number(w["limit_window_seconds"])),
                               usedPercent: JSON.clampPercent(used), resetsAt: reset)
        }
        let windows = [window("primary", rl["primary_window"]), window("secondary", rl["secondary_window"])].compactMap { $0 }
        let plan = (obj["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (plan, windows)
    }

    static func label(seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "Limit" }
        if s <= 86_400 { return "Session" }
        if abs(s / 86_400 - 7) < 0.1 { return "Weekly" }
        return "\(Int((s / 86_400).rounded()))-day"
    }

    /// Reads `accessToken` from chatgpt.com `/api/auth/session`.
    public static func accessToken(fromSession data: Data) -> String? {
        (JSON.object(data) as? [String: Any])?["accessToken"] as? String
    }
}

public enum JWT {
    /// Decodes a JWT payload without verifying it (only used to read the expiry and account ID).
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return JSON.object(data) as? [String: Any]
    }

    public static func expiry(_ token: String) -> Date? {
        claims(token).flatMap { JSON.number($0["exp"]) }.map { Date(timeIntervalSince1970: $0) }
    }

    public static func chatGPTAccountID(_ token: String) -> String? {
        (claims(token)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }
}
