#if os(iOS)
import SwiftUI
import DaybriefCore

@Observable
@MainActor
final class AppModel {
    private(set) var items: [Source: [Item]] = [:]
    private(set) var errors: [Source: String] = [:]
    private(set) var refreshing = false
    private(set) var lastRefresh: Date?
    private(set) var settings = AppSettings()
    /// Whether an Obsidian vault folder is chosen.
    private(set) var obsidianConnected = ObsidianSource.isConnected
    /// Whether iOS lets Daybrief show notifications.
    private(set) var notificationsAllowed = true

    private var eduPage = EduPageClient()
    private static let settingsKey = "settings"
    static let eduPasswordKey = "edupage-password"
    static let gmailPasswordKey = "gmail-password"

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("items.json")
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        }
        // The last result, so the list isn't empty while the first refresh runs.
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [Item]].self, from: data) {
            for (key, value) in cached {
                if let source = Source(rawValue: key) { items[source] = value }
            }
        }
    }

    var agenda: Agenda { Agenda(items: Source.allCases.flatMap { items[$0] ?? [] }) }

    func isConnected(_ source: Source) -> Bool {
        switch source {
        case .calendar: return settings.calendar
        case .reminders: return settings.reminders
        case .obsidian: return obsidianConnected
        case .edupage: return !settings.eduSchool.isEmpty && !settings.eduUser.isEmpty && Keychain.get(Self.eduPasswordKey) != nil
        case .gmail: return !settings.gmailUser.isEmpty && Keychain.get(Self.gmailPasswordKey) != nil
        }
    }

    var anyConnected: Bool { Source.allCases.contains(where: isConnected) }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: connecting

    func connectObsidian(_ folder: URL) {
        do {
            let name = try ObsidianSource.connect(folder)
            update { $0.obsidianVault = name }
            obsidianConnected = true
            errors[.obsidian] = nil
        } catch {
            errors[.obsidian] = "Couldn't remember that folder. Try choosing it again."
        }
    }

    func disconnectObsidian() {
        ObsidianSource.disconnect()
        update { $0.obsidianVault = nil }
        obsidianConnected = false
    }

    func connectEduPage(school: String, user: String, password: String) {
        update {
            $0.eduSchool = school.trimmingCharacters(in: .whitespaces)
            $0.eduUser = user.trimmingCharacters(in: .whitespaces)
        }
        Keychain.set(password, for: Self.eduPasswordKey)
        eduPage = EduPageClient() // a fresh sign-in for the new account
    }

    func disconnectEduPage() {
        update { $0.eduSchool = ""; $0.eduUser = "" }
        Keychain.set(nil, for: Self.eduPasswordKey)
        eduPage = EduPageClient()
    }

    func connectGmail(user: String, password: String) {
        update { $0.gmailUser = user.trimmingCharacters(in: .whitespaces) }
        Keychain.set(password, for: Self.gmailPasswordKey)
    }

    func disconnectGmail() {
        update { $0.gmailUser = "" }
        Keychain.set(nil, for: Self.gmailPasswordKey)
    }

    // MARK: refreshing

    /// Refreshes when the app comes to the front, unless it just did.
    func refreshIfStale() async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < 10 * 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let settings = self.settings
        let eduPage = self.eduPage
        let eduPassword = Keychain.get(Self.eduPasswordKey) ?? ""
        let gmailPassword = Keychain.get(Self.gmailPasswordKey) ?? ""
        let connected = Source.allCases.filter(isConnected)

        // All sources at once; one that fails keeps its last items and shows why.
        let results = await withTaskGroup(of: (Source, Result<[Item], Error>).self) { group -> [(Source, Result<[Item], Error>)] in
            for source in connected {
                group.addTask {
                    do {
                        switch source {
                        case .calendar: return (source, .success(try await AppleSource.shared.events()))
                        case .reminders: return (source, .success(try await AppleSource.shared.reminders()))
                        case .obsidian: return (source, .success(try await ObsidianSource.tasks()))
                        case .edupage:
                            return (source, .success(try await eduPage.items(school: settings.eduSchool, username: settings.eduUser, password: eduPassword)))
                        case .gmail:
                            return (source, .success(try await GmailSource.mail(user: settings.gmailUser, password: gmailPassword, query: settings.gmailQuery)))
                        }
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            var all: [(Source, Result<[Item], Error>)] = []
            for await result in group { all.append(result) }
            return all
        }

        for source in Source.allCases where !connected.contains(source) {
            items[source] = nil
            errors[source] = nil
        }
        for (source, result) in results {
            switch result {
            case .success(let found):
                items[source] = found
                errors[source] = nil
            case .failure(let error):
                if let e = error as? BriefError {
                    errors[source] = e.message
                } else if error is URLError {
                    errors[source] = "Can't reach \(source.label). Check your connection."
                } else {
                    errors[source] = error.localizedDescription
                }
            }
        }
        lastRefresh = Date()
        saveCache()
        await reschedule()
    }

    private func saveCache() {
        var out: [String: [Item]] = [:]
        for (source, list) in items { out[source.rawValue] = list }
        if let data = try? JSONEncoder().encode(out) {
            try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: notifications

    /// Schedules the next week's summaries from what is known now.
    func reschedule() async {
        notificationsAllowed = await Notifier.shared.isAllowed()
        let plan = NotificationPlanner.plan(agenda: agenda, now: Date(), schedule: settings.schedule)
        await Notifier.shared.schedule(plan)
    }

    func askForNotifications() async {
        notificationsAllowed = await Notifier.shared.requestPermission()
        await reschedule()
    }

    func sendTest() async {
        await askForNotifications()
        await Notifier.shared.post(BriefBuilder.day(Date(), agenda: agenda))
    }

    // MARK: actions

    func complete(_ item: Item) {
        guard item.source == .reminders else { return }
        do {
            try AppleSource.shared.complete(item)
            items[.reminders]?.removeAll { $0.id == item.id }
            saveCache()
            Task { await reschedule() }
        } catch {
            errors[.reminders] = (error as? BriefError)?.message ?? error.localizedDescription
        }
    }
}
#endif
