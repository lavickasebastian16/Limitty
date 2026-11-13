import Foundation

/// Where an item comes from.
public enum Source: String, Codable, CaseIterable, Sendable {
    case calendar, reminders, obsidian, edupage, gmail

    public var label: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .obsidian: return "Obsidian"
        case .edupage: return "EduPage"
        case .gmail: return "Gmail"
        }
    }
}

public enum ItemKind: String, Codable, Sendable {
    /// Happens at a time (a calendar event, an exam).
    case event
    /// Something to do, with or without a due date.
    case task
    /// An email waiting for you.
    case mail
}

/// One thing you have to do or attend.
public struct Item: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: Source
    public var kind: ItemKind
    public var title: String
    /// Calendar name, note name, sender…
    public var detail: String?
    /// Start or due date. Nil for tasks without a date.
    public var date: Date?
    public var end: Date?
    /// False for all-day events and date-only tasks.
    public var hasTime: Bool
    /// Opens the item in its own app.
    public var link: String?

    public init(id: String, source: Source, kind: ItemKind, title: String, detail: String? = nil,
                date: Date? = nil, end: Date? = nil, hasTime: Bool = false, link: String? = nil) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.end = end
        self.hasTime = hasTime
        self.link = link
    }
}

/// An error with a message that is ready to show.
public struct BriefError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// When the two daily notifications arrive.
public struct BriefSchedule: Codable, Equatable, Sendable {
    public var morningEnabled = true
    public var morningHour = 7
    public var morningMinute = 0
    public var eveningEnabled = true
    public var eveningHour = 18
    public var eveningMinute = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        morningEnabled = try c.decodeIfPresent(Bool.self, forKey: .morningEnabled) ?? true
        morningHour = try c.decodeIfPresent(Int.self, forKey: .morningHour) ?? 7
        morningMinute = try c.decodeIfPresent(Int.self, forKey: .morningMinute) ?? 0
        eveningEnabled = try c.decodeIfPresent(Bool.self, forKey: .eveningEnabled) ?? true
        eveningHour = try c.decodeIfPresent(Int.self, forKey: .eveningHour) ?? 18
        eveningMinute = try c.decodeIfPresent(Int.self, forKey: .eveningMinute) ?? 0
    }
}

/// What you chose in Connections. Passwords are kept in the Keychain, not here.
public struct AppSettings: Codable, Equatable, Sendable {
    public var calendar = false
    public var reminders = false
    public var obsidianVault: String?
    public var eduSchool = ""
    public var eduUser = ""
    public var gmailUser = ""
    public var gmailQuery = AppSettings.defaultGmailQuery
    public var schedule = BriefSchedule()

    /// Starred mail, plus unread mail from the last week in the Primary tab.
    public static let defaultGmailQuery = "is:starred OR (category:primary is:unread newer_than:7d)"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendar = try c.decodeIfPresent(Bool.self, forKey: .calendar) ?? false
        reminders = try c.decodeIfPresent(Bool.self, forKey: .reminders) ?? false
        obsidianVault = try c.decodeIfPresent(String.self, forKey: .obsidianVault)
        eduSchool = try c.decodeIfPresent(String.self, forKey: .eduSchool) ?? ""
        eduUser = try c.decodeIfPresent(String.self, forKey: .eduUser) ?? ""
        gmailUser = try c.decodeIfPresent(String.self, forKey: .gmailUser) ?? ""
        gmailQuery = try c.decodeIfPresent(String.self, forKey: .gmailQuery) ?? AppSettings.defaultGmailQuery
        schedule = try c.decodeIfPresent(BriefSchedule.self, forKey: .schedule) ?? BriefSchedule()
    }
}
