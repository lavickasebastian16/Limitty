import Foundation
import XCTest
@testable import DaybriefCore

final class SpokenTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Friday 13 November 2026, 12:00.
    private func parse(_ text: String) -> SpokenTask {
        SpokenParser.parse(text, now: at(2026, 11, 13, 12), calendar: cal)
    }

    func testEnglish() {
        XCTAssertEqual(parse("Remind me to buy milk tomorrow at 5 PM."),
                       SpokenTask(title: "Buy milk", date: at(2026, 11, 14, 17), hasTime: true, isEvent: false))
        XCTAssertEqual(parse("Call grandma on Monday"),
                       SpokenTask(title: "Call grandma", date: at(2026, 11, 16), hasTime: false, isEvent: false))
        XCTAssertEqual(parse("Buy bread"), SpokenTask(title: "Buy bread", date: nil, hasTime: false, isEvent: false))
        XCTAssertEqual(parse("Take out the trash at 6"),
                       SpokenTask(title: "Take out the trash", date: at(2026, 11, 13, 18), hasTime: true, isEvent: false))
        XCTAssertEqual(parse("in 2 hours stretch"),
                       SpokenTask(title: "Stretch", date: at(2026, 11, 13, 14), hasTime: true, isEvent: false))
        XCTAssertEqual(parse("Dentist appointment on November 20th at 3:30 pm"),
                       SpokenTask(title: "Dentist appointment", date: at(2026, 11, 20, 15, 30), hasTime: true, isEvent: true))
        XCTAssertEqual(parse("Add task finish the essay tomorrow evening"),
                       SpokenTask(title: "Finish the essay", date: at(2026, 11, 14, 19), hasTime: true, isEvent: false))
        XCTAssertEqual(parse("New event school trip on the 3rd of March"),
                       SpokenTask(title: "School trip", date: at(2027, 3, 3), hasTime: false, isEvent: true))
        XCTAssertEqual(parse("Remind me tomorrow to water the plants at 9:15"),
                       SpokenTask(title: "Water the plants", date: at(2026, 11, 14, 9, 15), hasTime: true, isEvent: false))
    }

    func testSlovakAndCzech() {
        XCTAssertEqual(parse("Pripomeň mi kúpiť chlieb zajtra o 8"),
                       SpokenTask(title: "Kúpiť chlieb", date: at(2026, 11, 14, 8), hasTime: true, isEvent: false))
        // Said on a Friday: the next Friday.
        XCTAssertEqual(parse("Odovzdať projekt v piatok"),
                       SpokenTask(title: "Odovzdať projekt", date: at(2026, 11, 20), hasTime: false, isEvent: false))
        XCTAssertEqual(parse("Stretnutie s Janou 20.11. o 14:30"),
                       SpokenTask(title: "Stretnutie s Janou", date: at(2026, 11, 20, 14, 30), hasTime: true, isEvent: true))
        XCTAssertEqual(parse("Pridaj úlohu napísať referát pozajtra"),
                       SpokenTask(title: "Napísať referát", date: at(2026, 11, 15), hasTime: false, isEvent: false))
        XCTAssertEqual(parse("Zavolať mame dnes večer o 7"),
                       SpokenTask(title: "Zavolať mame", date: at(2026, 11, 13, 19), hasTime: true, isEvent: false))
        XCTAssertEqual(parse("Písomka z matematiky 5. decembra"),
                       SpokenTask(title: "Písomka z matematiky", date: at(2026, 12, 5), hasTime: false, isEvent: false))
        XCTAssertEqual(parse("Připomeň mi úkol z fyziky zítra"),
                       SpokenTask(title: "Úkol z fyziky", date: at(2026, 11, 14), hasTime: false, isEvent: false))
    }
}
