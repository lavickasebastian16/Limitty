import Foundation

/// Small regular-expression helpers.
struct Rx {
    let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // Patterns are fixed strings in this module, so a bad one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// The capture groups of the first match (index 0 is the whole match).
    func groups(in text: String) -> [String?]? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    func replace(in text: String, with template: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

enum DayParser {
    /// "2026-11-14" → the start of that day.
    static func date(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2],
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        guard let date = calendar.date(from: c) else { return nil }
        // Rejects days that don't exist, such as 31 February.
        return calendar.component(.day, from: date) == d ? date : nil
    }

    /// "2026-11-14 08:30:00" → that moment in the calendar's time zone.
    static func dateTime(_ text: String, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        let halves = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = halves.first, let day = date(first, calendar: calendar) else { return nil }
        guard halves.count == 2 else { return (day, false) }
        let t = halves[1].split(separator: ":").map { Int($0) }
        guard t.count >= 2, let h = t[0], let min = t[1], (0...23).contains(h), (0...59).contains(min) else { return (day, false) }
        if h == 0 && min == 0 { return (day, false) }
        guard let date = calendar.date(bySettingHour: h, minute: min, second: 0, of: day) else { return (day, false) }
        return (date, true)
    }
}
