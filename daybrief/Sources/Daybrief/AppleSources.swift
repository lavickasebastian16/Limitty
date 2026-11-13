#if os(iOS)
import Foundation
import EventKit
import DaybriefCore

/// Apple Calendar and Reminders, through EventKit.
final class AppleSource: @unchecked Sendable {
    static let shared = AppleSource()
    private let store = EKEventStore()

    /// Asks for access (iOS shows its prompt the first time).
    func requestCalendar() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func requestReminders() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Events from today to `days` days ahead.
    func events(days: Int = 30) async throws -> [Item] {
        guard await requestCalendar() else {
            throw BriefError("Calendar access is off. Turn it on in Settings → Privacy & Security → Calendars → Daybrief (Full Access).")
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> Item? in
            if event.status == .canceled { return nil }
            guard let begin = event.startDate else { return nil }
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The same repeating event has one identifier, so the start time is added.
            let id = "calendar:\(event.eventIdentifier ?? title):\(Int(begin.timeIntervalSince1970))"
            return Item(id: id, source: .calendar, kind: .event, title: title.isEmpty ? "(no title)" : title,
                        detail: event.calendar?.title, date: begin, end: event.endDate, hasTime: !event.isAllDay,
                        link: "calshow:\(Int(begin.timeIntervalSinceReferenceDate))")
        }
    }

    /// Every reminder that isn't completed.
    func reminders() async throws -> [Item] {
        guard await requestReminders() else {
            throw BriefError("Reminders access is off. Turn it on in Settings → Privacy & Security → Reminders → Daybrief.")
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let cal = Calendar.current
        return await withCheckedContinuation { (done: CheckedContinuation<[Item], Never>) in
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map { r -> Item in
                    var date: Date?
                    var hasTime = false
                    if let due = r.dueDateComponents {
                        date = cal.date(from: due)
                        hasTime = due.hour != nil
                    }
                    let title = (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return Item(id: "reminders:\(r.calendarItemIdentifier)", source: .reminders, kind: .task,
                                title: title.isEmpty ? "(no title)" : title, detail: r.calendar?.title,
                                date: date, hasTime: hasTime, link: "x-apple-reminderkit://")
                }
                done.resume(returning: items)
            }
        }
    }

    /// Something added by voice, with what's needed to take it back.
    struct Added: Equatable {
        var task: SpokenTask
        var isEvent: Bool
        var identifier: String
    }

    /// Adds a spoken task to Reminders, or to the calendar when it is an event with a date.
    func add(_ task: SpokenTask) async throws -> Added {
        let cal = Calendar.current
        if task.isEvent, let start = task.date {
            guard await requestCalendar() else {
                throw BriefError("Calendar access is off. Turn it on in Settings → Privacy & Security → Calendars → Daybrief (Full Access).")
            }
            guard let calendar = store.defaultCalendarForNewEvents else { throw BriefError("There is no calendar to add events to.") }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = task.title
            event.startDate = start
            event.isAllDay = !task.hasTime
            event.endDate = task.hasTime ? start.addingTimeInterval(3600) : start
            try store.save(event, span: .thisEvent, commit: true)
            return Added(task: task, isEvent: true, identifier: event.eventIdentifier ?? "")
        }

        guard await requestReminders() else {
            throw BriefError("Reminders access is off. Turn it on in Settings → Privacy & Security → Reminders → Daybrief.")
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw BriefError("There is no Reminders list to add to.") }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = task.title
        if let due = task.date {
            reminder.dueDateComponents = cal.dateComponents(task.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
            // Reminders alerts you itself at that time.
            if task.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        return Added(task: task, isEvent: false, identifier: reminder.calendarItemIdentifier)
    }

    /// Takes back something just added by voice.
    func remove(_ added: Added) throws {
        if added.isEvent {
            if let event = store.event(withIdentifier: added.identifier) { try store.remove(event, span: .thisEvent, commit: true) }
        } else if let reminder = store.calendarItem(withIdentifier: added.identifier) as? EKReminder {
            try store.remove(reminder, commit: true)
        }
    }

    /// Marks a reminder as done in the Reminders app.
    func complete(_ item: Item) throws {
        let id = String(item.id.dropFirst("reminders:".count))
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BriefError("That reminder is no longer there.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }
}
#endif
