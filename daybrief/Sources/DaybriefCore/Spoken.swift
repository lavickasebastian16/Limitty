import Foundation

/// What a spoken sentence asks to add.
public struct SpokenTask: Equatable, Sendable {
    public var title: String
    public var date: Date?
    public var hasTime: Bool
    /// True for "event…" or a meeting/appointment: goes to the calendar instead of Reminders.
    public var isEvent: Bool
}

/// Turns "Remind me to buy milk tomorrow at 5 pm" into a task with a date.
/// Understands English, Slovak and Czech words for days and times.
public enum SpokenParser {
    private static let notWordBefore = "(?<![\\p{L}\\d])"
    private static let notWordAfter = "(?![\\p{L}\\d])"

    private static let weekdays: [(String, Int)] = [
        ("sunday|nedeľu|nedeľa|neděli|neděle", 1), ("monday|pondelok|pondělí", 2), ("tuesday|utorok|úterý", 3),
        ("wednesday|stredu|streda|středu|středa", 4), ("thursday|štvrtok|čtvrtek", 5), ("friday|piatok|pátek", 6),
        ("saturday|sobotu|sobota", 7),
    ]
    private static let months: [String] = [
        "january|januára|ledna", "february|februára|února", "march|marca|března", "april|apríla|dubna",
        "may|mája|května", "june|júna|června", "july|júla|července", "august|augusta|srpna",
        "september|septembra|září", "october|októbra|října", "november|novembra|listopadu", "december|decembra|prosince",
    ]

    /// The text being read; each recognised piece is cut out, and what is left is the title.
    private struct Work {
        var text: String

        /// Cuts out the first match and returns its groups.
        mutating func take(_ pattern: String, whole: Bool = true) -> [String?]? {
            let full = whole ? notWordBefore + "(?:" + pattern + ")" + notWordAfter : pattern
            guard let rx = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) else { return nil }
            let ns = text as NSString
            guard let m = rx.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
            let groups: [String?] = (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            text = ns.replacingCharacters(in: m.range, with: " ")
            return groups
        }
    }

    public static func parse(_ spoken: String, now: Date, calendar: Calendar = .current) -> SpokenTask {
        var work = Work(text: spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = work.take("[.!?…]+$", whole: false)
        let today = calendar.startOfDay(for: now)

        // What kind of thing, and the words that only introduce it.
        var isEvent = work.take("^\\s*(?:(?:add|create|new|schedule|pridaj|vytvor|nová|přidej|vytvoř)\\s+)?(?:an?\\s+)?(?:calendar\\s+)?(?:event|udalosť|událost)(?![\\p{L}])[:,]?\\s*", whole: false) != nil
        if !isEvent {
            _ = work.take("^\\s*(?:please\\s+)?(?:remind me(?: to| about| that)?|add (?:a |new )?(?:task|reminder|to-?do)(?: to| that)?|new (?:task|reminder)|i (?:need|have) to|don['’]?t forget to|task|todo|pripomeň mi(?:,? (?:aby som|že))?|pridaj (?:úlohu|pripomienku)|nová úloha|úloha|nezabudni|musím|připomeň mi(?:,? (?:abych|že))?|přidej úkol|úkol|add|pridaj|přidej)(?![\\p{L}])[:,]?\\s*", whole: false)
        }
        if work.text.range(of: "meeting|appointment|stretnutie|schôdzk|schůzk", options: [.regularExpression, .caseInsensitive]) != nil { isEvent = true }

        var day: Date?
        var exact: Date? // "in 2 hours"
        var evening = false
        var defaultHour: Int?

        // Days.
        if work.take("day after tomorrow|pozajtra|pozítří") != nil { day = calendar.date(byAdding: .day, value: 2, to: today) }
        else if work.take("tomorrow|zajtra|zítra") != nil { day = calendar.date(byAdding: .day, value: 1, to: today) }
        else if work.take("tonight") != nil { day = today; evening = true; defaultHour = 19 }
        else if work.take("today|dnes") != nil { day = today }
        else if work.take("next week|budúci týždeň|příští týden") != nil { day = calendar.date(byAdding: .day, value: 7, to: today) }
        else if let g = work.take("(?:in|o|za)\\s+(\\d{1,3})\\s+(minut\\p{L}*|minút\\p{L}*|hour\\p{L}*|hod\\p{L}*|day\\p{L}*|dn\\p{L}*|dň\\p{L}*|deň|week\\p{L}*|týžd\\p{L}*|týd\\p{L}*)"),
                let n = g[1].flatMap({ Int($0) }), let unit = g[2]?.lowercased() {
            if unit.hasPrefix("min") { exact = calendar.date(byAdding: .minute, value: n, to: now) }
            else if unit.hasPrefix("ho") { exact = calendar.date(byAdding: .hour, value: n, to: now) }
            else if unit.hasPrefix("d") { day = calendar.date(byAdding: .day, value: n, to: today) }
            else { day = calendar.date(byAdding: .day, value: 7 * n, to: today) }
        }

        if day == nil && exact == nil {
            for (names, number) in weekdays {
                guard work.take("(?:(?:on|next|this|v|vo|ve|na|budúci|budúcu|příští)\\s+)?(?:\(names))") != nil else { continue }
                let current = calendar.component(.weekday, from: today)
                let ahead = (number - current + 7) % 7
                day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: today)
                break
            }
        }

        if day == nil && exact == nil {
            var monthDay: (Int, Int, Int?)?
            if let g = work.take("(?:on\\s+)?(\\d{1,2})\\.\\s?(\\d{1,2})\\.(?:\\s?(\\d{4}))?", whole: false),
               let d = g[1].flatMap({ Int($0) }), let m = g[2].flatMap({ Int($0) }) {
                monthDay = (m, d, g[3].flatMap { Int($0) })
            } else {
                for (index, names) in months.enumerated() {
                    if let g = work.take("(?:on\\s+)?(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th|\\.)?(?:\\s+of)?\\s+(?:\(names))"), let d = g[1].flatMap({ Int($0) }) {
                        monthDay = (index + 1, d, nil)
                    } else if let g = work.take("(?:on\\s+)?(?:\(names))\\s+(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?"), let d = g[1].flatMap({ Int($0) }) {
                        monthDay = (index + 1, d, nil)
                    }
                    if monthDay != nil { break }
                }
            }
            if let (m, d, y) = monthDay {
                let year = y ?? calendar.component(.year, from: today)
                var found = DayParser.date("\(year)-\(m)-\(d)", calendar: calendar)
                // A date that has passed means next year.
                if y == nil, let f = found, f < today { found = DayParser.date("\(year + 1)-\(m)-\(d)", calendar: calendar) }
                day = found
            }
        }

        // Times.
        var hour: Int?
        var minute = 0
        var meridiem: String?
        if let g = work.take("(?:(?:at|o|v|ve)\\s+)?([01]?\\d|2[0-3]):([0-5]\\d)(?:\\s*(a\\.?m\\.?|p\\.?m\\.?))?", whole: false) {
            hour = g[1].flatMap { Int($0) }
            minute = g[2].flatMap { Int($0) } ?? 0
            meridiem = g[3]
        } else if let g = work.take("(?:at\\s+)?(1[0-2]|0?[1-9])\\s*(a\\.?m\\.?|p\\.?m\\.?)") {
            hour = g[1].flatMap { Int($0) }
            meridiem = g[2]
        } else if work.take("(?:at\\s+)?noon|na obed|v poledne") != nil {
            hour = 12
            meridiem = "none"
        } else if let g = work.take("(?:at|o)\\s+([01]?\\d|2[0-3])(?:\\s+(?:o['’]?clock|hod\\p{L}*\\.?))?") {
            hour = g[1].flatMap { Int($0) }
        }
        if work.take("(?:in the\\s+)?morning|ráno") != nil { defaultHour = 8 }
        else if work.take("(?:in the\\s+)?afternoon|poobede|popoludní|odpoledne") != nil { defaultHour = 15; evening = true }
        else if work.take("(?:in the\\s+)?evening|večer") != nil { defaultHour = 19; evening = true }

        if var h = hour {
            let m = meridiem?.lowercased() ?? ""
            if m.hasPrefix("p"), h < 12 { h += 12 }
            if m.hasPrefix("a"), h == 12 { h = 0 }
            if meridiem == nil, evening, h < 12 { h += 12 }
            hour = h
        } else {
            hour = defaultHour
        }

        var date = exact ?? day
        var hasTime = exact != nil
        if exact == nil, let h = hour {
            if let d = day {
                date = calendar.date(bySettingHour: h, minute: minute, second: 0, of: d)
            } else {
                // No day: the next time the clock shows it. "at 6" said at midday means this evening.
                var candidate = calendar.date(bySettingHour: h, minute: minute, second: 0, of: today)
                if let c = candidate, c <= now {
                    let later = calendar.date(byAdding: .hour, value: 12, to: c)
                    if meridiem == nil, h < 12, let l = later, l > now { candidate = l }
                    else { candidate = calendar.date(byAdding: .day, value: 1, to: c) }
                }
                date = candidate
            }
            hasTime = date != nil
        }

        return SpokenTask(title: title(work.text), date: date, hasTime: hasTime, isEvent: isEvent)
    }

    private static func title(_ rest: String) -> String {
        var t = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        var work = Work(text: t)
        // Linking words left hanging where a date was cut out.
        while work.take("(?:^|[\\s,]+)(?:on|at|in|by|for|v|vo|ve|o|na|do|and|a)\\s*$", whole: false) != nil {}
        _ = work.take("^\\s*(?:to|that|aby som|abych|že)\\s+", whole: false)
        t = work.text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–.").union(.whitespacesAndNewlines))
        t = t.split(separator: " ").joined(separator: " ")
        guard let first = t.first else { return "New task" }
        return first.uppercased() + t.dropFirst()
    }
}
