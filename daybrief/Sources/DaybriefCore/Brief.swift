import Foundation

/// A short summary: one title line and a few detail lines.
public struct Brief: Equatable, Sendable {
    public var title: String
    public var lines: [String]
    public var body: String { lines.joined(separator: "\n") }

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

public enum BriefBuilder {
    /// Lines shown before "+N more".
    public static let maxLines = 6

    /// "2 events, 3 tasks".
    public static func counts(_ items: [Item]) -> String {
        let events = items.filter { $0.kind == .event }.count
        let tasks = items.filter { $0.kind == .task }.count
        var parts: [String] = []
        if events > 0 { parts.append(plural(events, "event")) }
        if tasks > 0 { parts.append(plural(tasks, "task")) }
        return parts.joined(separator: ", ")
    }

    public static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    /// "09:00 Maths exam" for timed items, "• Buy milk" for the rest.
    public static func line(for item: Item, on day: Date, calendar: Calendar) -> String {
        let dayStart = calendar.startOfDay(for: day)
        if item.hasTime, let d = item.date, d >= dayStart {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            let hour = c.hour ?? 0, minute = c.minute ?? 0
            return "\(hour < 10 ? "0" : "")\(hour):\(minute < 10 ? "0" : "")\(minute) \(item.title)"
        }
        return "• \(item.title)"
    }

    private static func itemLines(_ items: [Item], day: Date, calendar: Calendar) -> [String] {
        var lines = items.prefix(maxLines).map { line(for: $0, on: day, calendar: calendar) }
        if items.count > maxLines { lines.append("+\(items.count - maxLines) more") }
        return lines
    }

    /// The summary for a day. `label` is "Today" or a weekday name.
    public static func day(_ day: Date, label: String = "Today", agenda: Agenda, includeMail: Bool = true) -> Brief {
        let items = agenda.items(on: day)
        var lines = itemLines(items, day: day, calendar: agenda.calendar)
        var extras: [String] = []
        let overdue = agenda.overdue(asOf: day).count
        if overdue > 0 { extras.append("\(overdue) overdue") }
        let mail = agenda.mail.count
        if includeMail && mail > 0 { extras.append(plural(mail, "email")) }
        if !extras.isEmpty { lines.append((items.isEmpty ? "" : "Also: ") + extras.joined(separator: ", ")) }
        let title = items.isEmpty ? "\(label): nothing planned" : "\(label): \(counts(items))"
        return Brief(title: title, lines: lines)
    }

    /// The evening-before warning. Nil when there is nothing on that day.
    public static func dayBefore(_ tomorrow: Date, agenda: Agenda) -> Brief? {
        let items = agenda.items(on: tomorrow)
        guard !items.isEmpty else { return nil }
        return Brief(title: "Tomorrow: \(counts(items))", lines: itemLines(items, day: tomorrow, calendar: agenda.calendar))
    }
}

/// A local notification to schedule.
public struct PlannedNotification: Equatable, Sendable {
    public var id: String
    public var fireDate: Date
    public var title: String
    public var body: String
}

public enum NotificationPlanner {
    /// Every notification id starts with this, so old ones can be replaced.
    public static let idPrefix = "brief-"

    /// The notifications for the next `days` days, from what is known now.
    /// iOS can't be relied on to wake the app each morning, so they are all
    /// scheduled ahead and replaced on every refresh.
    public static func plan(agenda: Agenda, now: Date, schedule: BriefSchedule, days: Int = 7) -> [PlannedNotification] {
        let cal = agenda.calendar
        let today = cal.startOfDay(for: now)
        var out: [PlannedNotification] = []
        var firstMorning = true
        for offset in 0..<max(days, 0) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let key = dayKey(day, calendar: cal)

            if schedule.morningEnabled,
               let fire = cal.date(bySettingHour: schedule.morningHour, minute: schedule.morningMinute, second: 0, of: day),
               fire > now {
                // The email count is only right for the nearest morning.
                let brief = BriefBuilder.day(day, agenda: agenda, includeMail: firstMorning)
                firstMorning = false
                out.append(PlannedNotification(id: "\(idPrefix)morning-\(key)", fireDate: fire, title: brief.title, body: brief.body))
            }

            if schedule.eveningEnabled,
               let fire = cal.date(bySettingHour: schedule.eveningHour, minute: schedule.eveningMinute, second: 0, of: day),
               fire > now,
               let brief = BriefBuilder.dayBefore(next, agenda: agenda) {
                out.append(PlannedNotification(id: "\(idPrefix)evening-\(key)", fireDate: fire, title: brief.title, body: brief.body))
            }
        }
        return out
    }

    static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let m = c.month ?? 0, d = c.day ?? 0
        return "\(c.year ?? 0)-\(m < 10 ? "0" : "")\(m)-\(d < 10 ? "0" : "")\(d)"
    }
}
