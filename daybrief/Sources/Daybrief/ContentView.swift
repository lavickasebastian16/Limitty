#if os(iOS)
import SwiftUI
import DaybriefCore

extension Source {
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .obsidian: return "note.text"
        case .edupage: return "graduationcap"
        case .gmail: return "envelope"
        }
    }

    var color: Color {
        switch self {
        case .calendar: return .red
        case .reminders: return .orange
        case .obsidian: return .purple
        case .edupage: return .blue
        case .gmail: return .green
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showConnections = false
    @State private var showAllUndated = false
    @State private var showVoice = false

    var body: some View {
        NavigationStack {
            Group {
                if model.anyConnected {
                    list
                } else {
                    ContentUnavailableView {
                        Label("Nothing connected yet", systemImage: "tray")
                    } description: {
                        Text("Connect your calendar, reminders, Obsidian, EduPage and Gmail to see everything you have to do in one place.")
                    } actions: {
                        Button("Connect") { showConnections = true }
                            .buttonStyle(.borderedProminent)
                        Text("Or tap the microphone and say a task.").font(.footnote)
                    }
                }
            }
            .navigationTitle("Daybrief")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showConnections = true
                    } label: {
                        Label("Connections", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showConnections) { ConnectionsView() }
            .sheet(isPresented: $showVoice) { VoiceSheet() }
            .safeAreaInset(edge: .bottom) {
                // Speak to add a task.
                Button {
                    showVoice = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(radius: 4, y: 2)
                }
                .accessibilityLabel("Add a task by voice")
                .padding(.bottom, 8)
            }
            .task {
                if model.anyConnected { await model.askForNotifications() }
                await model.refreshIfStale()
            }
        }
    }

    private var list: some View {
        let agenda = model.agenda
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let overdue = agenda.overdue(asOf: today)
        let undated = agenda.undated
        let mail = agenda.mail

        return List {
            Section {
                SummaryCard(brief: BriefBuilder.day(today, agenda: agenda), refreshing: model.refreshing, lastRefresh: model.lastRefresh)
            }

            let problems = Source.allCases.filter { model.errors[$0] != nil }
            if !problems.isEmpty || !model.notificationsAllowed {
                Section {
                    ForEach(problems, id: \.self) { source in
                        Label {
                            Text("\(source.label): \(model.errors[source] ?? "")").font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if !model.notificationsAllowed {
                        Button {
                            Task { await model.askForNotifications() }
                        } label: {
                            Label("Notifications are off, so the daily summary can't arrive. Tap to turn them on.", systemImage: "bell.slash")
                                .font(.footnote)
                        }
                    }
                }
            }

            if !overdue.isEmpty {
                Section("Overdue") {
                    ForEach(overdue) { ItemRow(item: $0, showDay: true) }
                }
            }

            ForEach(days, id: \.self) { day in
                let items = agenda.items(on: day)
                // Today and tomorrow always show, so "nothing" is visible too.
                if !items.isEmpty || day == today || day == days.dropFirst().first {
                    Section(header(for: day, today: today, calendar: cal)) {
                        if items.isEmpty {
                            Text("Nothing planned").foregroundStyle(.secondary)
                        }
                        ForEach(items) { ItemRow(item: $0, day: day) }
                    }
                }
            }

            if !mail.isEmpty {
                Section("Email") {
                    ForEach(mail) { ItemRow(item: $0, showDay: true) }
                }
            }

            if !undated.isEmpty {
                Section("No date") {
                    ForEach(showAllUndated ? undated : Array(undated.prefix(8))) { ItemRow(item: $0) }
                    if undated.count > 8 && !showAllUndated {
                        Button("Show all \(undated.count)") { showAllUndated = true }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private func header(for day: Date, today: Date, calendar: Calendar) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        if day == today { return "Today · \(date)" }
        if calendar.isDate(day, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today) ?? today) { return "Tomorrow · \(date)" }
        return date
    }
}

/// The summary at the top: the same words the morning notification uses.
struct SummaryCard: View {
    let brief: Brief
    let refreshing: Bool
    let lastRefresh: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(brief.title).font(.headline)
            if let extra = brief.lines.last, extra.hasPrefix("Also: ") || brief.title.hasSuffix("nothing planned") {
                Text(extra.replacingOccurrences(of: "Also: ", with: "")).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if refreshing {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…")
                } else if let lastRefresh = lastRefresh {
                    Text("Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Pull down to refresh")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: Item
    /// The day this row is listed under.
    var day: Date?
    /// Show the date as well as the time (for overdue items and email).
    var showDay = false

    var body: some View {
        Button {
            open()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.source.symbol)
                    .foregroundStyle(item.source.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).foregroundStyle(.primary).lineLimit(3)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let when = when {
                    Text(when).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if item.source == .reminders {
                Button {
                    model.complete(item)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
    }

    private var subtitle: String {
        [item.source.label, item.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "14:30", "all day", or the date for overdue items and email.
    private var when: String? {
        guard let date = item.date else { return nil }
        if showDay {
            return Calendar.current.isDateInToday(date) && item.hasTime
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.day().month(.abbreviated))
        }
        if let day, item.kind == .event, !item.hasTime || date < Calendar.current.startOfDay(for: day) { return "all day" }
        return item.hasTime ? date.formatted(date: .omitted, time: .shortened) : nil
    }

    private func open() {
        guard let link = item.link, let url = URL(string: link) else { return }
        openURL(url) { opened in
            // No Gmail app: open Gmail in the browser instead.
            if !opened, item.source == .gmail, let web = URL(string: "https://mail.google.com/") { openURL(web) }
        }
    }
}
#endif
