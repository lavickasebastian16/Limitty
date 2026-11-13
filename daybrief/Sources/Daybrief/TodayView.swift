#if os(iOS)
import SwiftUI
import DaybriefCore

/// Today at a glance: the numbers, what's next, then overdue, today and tomorrow.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showVoice: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.anyConnected {
                    // Redrawn every minute so "Next up" and the day stay right.
                    TimelineView(.everyMinute) { context in
                        list(now: context.date)
                    }
                } else {
                    Welcome(showSettings: $showSettings)
                }
            }
            .navigationTitle(Theme.greeting(Date()))
            .toolbar { GearButton(show: $showSettings) }
            .micButton($showVoice)
        }
    }

    private func list(now: Date) -> some View {
        let agenda = model.agenda
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        let todays = agenda.items(on: today)
        let tomorrows = agenda.items(on: tomorrow)
        let overdue = agenda.overdue(asOf: today)
        let next = todays.first { $0.hasTime && ($0.date ?? now) > now }
        let problems = Source.allCases.filter { model.errors[$0] != nil }

        return List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        StatTile(value: todays.count, label: "Today", color: Theme.accent)
                        StatTile(value: tomorrows.count, label: "Tomorrow", color: Color.teal)
                        StatTile(value: overdue.count, label: "Overdue", color: Color.red)
                    }
                    if let next = next {
                        NextUpCard(item: next, now: now)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

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
                            Label("Notifications are off, so the daily summary can't arrive. Tap to turn them on.", systemImage: "bell.slash.fill")
                                .font(.footnote)
                        }
                    }
                }
            }

            if !overdue.isEmpty {
                Section {
                    ForEach(overdue) { ItemRow(item: $0, showDay: true, late: true) }
                } header: {
                    SectionTitle(title: "Overdue", detail: "\(overdue.count)", color: Color.red)
                }
            }

            Section {
                if todays.isEmpty {
                    Label("Nothing planned today", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                }
                ForEach(todays) { ItemRow(item: $0, day: today) }
            } header: {
                SectionTitle(title: "Today", detail: BriefBuilder.counts(todays))
            }

            Section {
                if tomorrows.isEmpty {
                    Label("Nothing planned yet", systemImage: "moon.zzz.fill")
                        .foregroundStyle(.secondary)
                }
                ForEach(tomorrows) { ItemRow(item: $0, day: tomorrow) }
            } header: {
                SectionTitle(title: "Tomorrow", detail: tomorrow.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
            } footer: {
                HStack(spacing: 6) {
                    if model.refreshing {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…")
                    } else if let last = model.lastRefresh {
                        Text("Updated \(last.formatted(date: .omitted, time: .shortened)) · pull down to refresh")
                    } else {
                        Text("Pull down to refresh")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .refreshable { await model.refresh() }
    }
}

/// A number with a label: "3 Today".
struct StatTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(value == 0 ? Color.secondary : color)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

/// The next thing today that has a time, and how long until it starts.
struct NextUpCard: View {
    let item: Item
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NEXT UP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(item.color)
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(alignment: .leading) {
            Capsule().fill(item.color).frame(width: 4).padding(.vertical, 12).padding(.leading, 8)
        }
    }

    private var detail: String {
        guard let date = item.date else { return item.source.label }
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        var away = "in \(minutes) min"
        if minutes >= 60 {
            away = "in \(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
        }
        return "\(date.formatted(date: .omitted, time: .shortened)) · \(away) · \(item.source.label)"
    }
}

/// The first screen, before anything is connected.
struct Welcome: View {
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(LinearGradient(colors: [Color.orange, Color.yellow], startPoint: .top, endPoint: .bottom))
                    .padding(.top, 20)
                Text("Everything you have to do, in one place")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    ForEach(Source.allCases, id: \.self) { source in
                        HStack(spacing: 12) {
                            IconBadge(symbol: source.symbol, color: source.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.label).font(.body.weight(.medium))
                                Text(source.blurb).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        if source != Source.allCases.last {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                Button {
                    showSettings = true
                } label: {
                    Text("Connect your sources")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Text("You get a summary every morning and a heads-up the evening before. Or tap the microphone and just say a task.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }
}
#endif
