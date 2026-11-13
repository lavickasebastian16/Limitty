import Foundation
import XCTest
@testable import DaybriefCore

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    return c
}()

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

final class ObsidianTests: XCTestCase {
    func testReadsOpenTasksAndDueDates() {
        let note = """
        # Plan
        - [ ] Buy milk
        - [x] Already done 📅 2026-11-14
        - [-] Cancelled
        * [ ] Essay for [[History|history class]] 📅 2026-11-14 ⏫ #task
        1. [ ] Call [the dentist](tel:123) [due:: 2026-11-15]
        - [/] Half done @due(2026-11-16)
        ```
        - [ ] not a task, it's code
        ```
        - [ ] Later ⏳ 2026-11-20 🔁 every week
        Just text [ ] here
        """
        let items = ObsidianParser.tasks(in: note, file: "School/Plan.md", vault: "My Vault", calendar: cal)
        XCTAssertEqual(items.map(\.title), ["Buy milk", "Essay for history class", "Call the dentist", "Half done", "Later"])
        XCTAssertEqual(items.map(\.date), [nil, at(2026, 11, 14), at(2026, 11, 15), at(2026, 11, 16), at(2026, 11, 20)])
        XCTAssertEqual(items[0].id, "obsidian:School/Plan.md:2")
        XCTAssertEqual(items[0].detail, "Plan")
        XCTAssertEqual(items[0].link, "obsidian://open?vault=My%20Vault&file=School%2FPlan.md")
        XCTAssertTrue(items.allSatisfy { $0.kind == .task && !$0.hasTime })
    }

    func testDailyNoteGivesTheDateAndTimes() {
        let note = "- [ ] 09:30 - 10:00 Stand-up\n- [ ] Tidy desk\n- [ ] Moved 📅 2026-12-01\r\n"
        let items = ObsidianParser.tasks(in: note, file: "Daily/2026-11-14.md", vault: "V", calendar: cal)
        XCTAssertEqual(items.map(\.title), ["Stand-up", "Tidy desk", "Moved"])
        XCTAssertEqual(items[0].date, at(2026, 11, 14, 9, 30))
        XCTAssertTrue(items[0].hasTime)
        XCTAssertEqual(items[1].date, at(2026, 11, 14))
        XCTAssertFalse(items[1].hasTime)
        XCTAssertEqual(items[2].date, at(2026, 12, 1))
    }

    func testIgnoresDatesThatDoNotExist() {
        let items = ObsidianParser.tasks(in: "- [ ] Odd 📅 2026-02-31", file: "a.md", vault: "V", calendar: cal)
        XCTAssertEqual(items.map(\.title), ["Odd"])
        XCTAssertNil(items[0].date)
    }
}

final class AgendaTests: XCTestCase {
    private let items = [
        Item(id: "1", source: .calendar, kind: .event, title: "Dentist", date: at(2026, 11, 14, 14, 30), end: at(2026, 11, 14, 15), hasTime: true),
        Item(id: "2", source: .calendar, kind: .event, title: "Trip", date: at(2026, 11, 13), end: at(2026, 11, 15, 23, 59), hasTime: false),
        Item(id: "3", source: .reminders, kind: .task, title: "Buy milk", date: at(2026, 11, 14), hasTime: false),
        Item(id: "4", source: .edupage, kind: .event, title: "Maths exam", date: at(2026, 11, 14, 9), hasTime: true),
        Item(id: "5", source: .obsidian, kind: .task, title: "Old essay", date: at(2026, 11, 10)),
        Item(id: "6", source: .obsidian, kind: .task, title: "Someday"),
        Item(id: "7", source: .gmail, kind: .mail, title: "Invoice", date: at(2026, 11, 14, 8), hasTime: true),
        Item(id: "8", source: .calendar, kind: .event, title: "Late film", date: at(2026, 11, 13, 22), end: at(2026, 11, 14), hasTime: true),
    ]

    func testGroupsByDay() {
        let agenda = Agenda(items: items, calendar: cal)
        XCTAssertEqual(agenda.items(on: at(2026, 11, 14, 12)).map(\.title), ["Trip", "Maths exam", "Dentist", "Buy milk"])
        XCTAssertEqual(agenda.items(on: at(2026, 11, 13)).map(\.title), ["Trip", "Late film"])
        XCTAssertEqual(agenda.items(on: at(2026, 11, 16)).map(\.title), [])
        XCTAssertEqual(agenda.overdue(asOf: at(2026, 11, 14)).map(\.title), ["Old essay"])
        XCTAssertEqual(agenda.undated.map(\.title), ["Someday"])
        XCTAssertEqual(agenda.mail.map(\.title), ["Invoice"])
    }

    func testDaySummary() {
        let agenda = Agenda(items: items, calendar: cal)
        let brief = BriefBuilder.day(at(2026, 11, 14), agenda: agenda)
        XCTAssertEqual(brief.title, "Today: 3 events, 1 task")
        XCTAssertEqual(brief.lines, ["• Trip", "09:00 Maths exam", "14:30 Dentist", "• Buy milk", "Also: 1 overdue, 1 email"])

        let quiet = BriefBuilder.day(at(2026, 11, 20), agenda: Agenda(items: [], calendar: cal))
        XCTAssertEqual(quiet.title, "Today: nothing planned")
        XCTAssertEqual(quiet.lines, [])
    }

    func testLongDaysAreCut() {
        let many = (1...9).map { Item(id: "\($0)", source: .reminders, kind: .task, title: "Task \($0)", date: at(2026, 11, 14)) }
        let brief = BriefBuilder.dayBefore(at(2026, 11, 14), agenda: Agenda(items: many, calendar: cal))
        XCTAssertEqual(brief?.title, "Tomorrow: 9 tasks")
        XCTAssertEqual(brief?.lines.count, 7)
        XCTAssertEqual(brief?.lines.last, "+3 more")
    }

    func testPlanSendsEveryMorningAndOnlyBusyEvenings() {
        let agenda = Agenda(items: items, calendar: cal)
        // Friday 13 Nov, 12:00: this morning's summary has passed.
        let plan = NotificationPlanner.plan(agenda: agenda, now: at(2026, 11, 13, 12), schedule: BriefSchedule(), days: 3)
        XCTAssertEqual(plan.map(\.id), ["brief-evening-2026-11-13", "brief-morning-2026-11-14", "brief-evening-2026-11-14", "brief-morning-2026-11-15"])
        XCTAssertEqual(plan[0].fireDate, at(2026, 11, 13, 18))
        XCTAssertEqual(plan[0].title, "Tomorrow: 3 events, 1 task")
        XCTAssertEqual(plan[1].fireDate, at(2026, 11, 14, 7))
        XCTAssertEqual(plan[1].title, "Today: 3 events, 1 task")
        XCTAssertTrue(plan[1].body.contains("1 email"))
        // Saturday evening warns about Sunday (the trip is still on).
        XCTAssertEqual(plan[2].title, "Tomorrow: 1 event")
        // Only the nearest morning counts the emails.
        XCTAssertEqual(plan[3].body, "• Trip\nAlso: 2 overdue")

        var off = BriefSchedule()
        off.eveningEnabled = false
        off.morningHour = 6
        off.morningMinute = 45
        let mornings = NotificationPlanner.plan(agenda: agenda, now: at(2026, 11, 13, 6), schedule: off, days: 2)
        XCTAssertEqual(mornings.map(\.fireDate), [at(2026, 11, 13, 6, 45), at(2026, 11, 14, 6, 45)])
    }

    func testSettingsSurviveMissingFields() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"calendar":true,"schedule":{"morningHour":8}}"#.utf8))
        XCTAssertTrue(s.calendar)
        XCTAssertEqual(s.schedule.morningHour, 8)
        XCTAssertEqual(s.schedule.eveningHour, 18)
        XCTAssertEqual(s.gmailQuery, AppSettings.defaultGmailQuery)
    }
}
