import Foundation

/// All items, grouped by day.
public struct Agenda: Sendable {
    public let items: [Item]
    public let calendar: Calendar

    public init(items: [Item], calendar: Calendar = .current) {
        self.items = items
        self.calendar = calendar
    }

    /// Events and tasks on that day: all-day first, then by time, then tasks without a time.
    public func items(on day: Date) -> [Item] {
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return items.filter { item in
            guard item.kind != .mail, let d = item.date else { return false }
            // An event over several days shows on each of them.
            if item.kind == .event, let e = item.end, e > d { return d < next && e > start }
            return d >= start && d < next
        }.sorted { a, b in
            let ka = sortKey(a, dayStart: start), kb = sortKey(b, dayStart: start)
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private func sortKey(_ item: Item, dayStart: Date) -> (Int, Date) {
        let date = item.date ?? dayStart
        // An event that started on an earlier day counts as all-day here.
        if item.kind == .event && (!item.hasTime || date < dayStart) { return (0, dayStart) }
        if item.hasTime { return (1, date) }
        return (2, dayStart)
    }

    /// Tasks that were due before that day.
    public func overdue(asOf day: Date) -> [Item] {
        let start = calendar.startOfDay(for: day)
        return items.filter { $0.kind == .task && ($0.date.map { $0 < start } ?? false) }
            .sorted { ($0.date ?? start) < ($1.date ?? start) }
    }

    /// Tasks without a date.
    public var undated: [Item] {
        items.filter { $0.kind == .task && $0.date == nil }
    }

    /// Emails, newest first.
    public var mail: [Item] {
        items.filter { $0.kind == .mail }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
