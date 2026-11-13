#if os(iOS)
import SwiftUI
import DaybriefCore

/// The next 30 days, with a strip of days to jump along.
struct UpcomingView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showVoice: Bool
    /// Show one source only (nil = everything).
    @State var filter: Source?
    @State var search = ""

    private struct DayGroup: Identifiable {
        let day: Date
        let items: [Item]
        var id: Date { day }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                list(proxy)
            }
            .navigationTitle("Upcoming")
            .searchable(text: $search, prompt: "Search upcoming")
            .toolbar { GearButton(show: $showSettings) }
            .micButton($showVoice)
        }
    }

    private func matches(_ item: Item, source: Source?, query: String) -> Bool {
        if let source = source, item.source != source { return false }
        if query.isEmpty { return true }
        return item.title.localizedStandardContains(query) || (item.detail ?? "").localizedStandardContains(query)
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let connected = Source.allCases.filter { model.isConnected($0) }
        // A filter for a source that was disconnected no longer applies.
        let selected = filter.flatMap { connected.contains($0) ? $0 : nil }
        let query = search.trimmingCharacters(in: .whitespaces)
        let agenda = Agenda(items: model.agenda.items.filter { matches($0, source: selected, query: query) }, calendar: cal)
        let days = (1...30).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let groups = days.map { DayGroup(day: $0, items: agenda.items(on: $0)) }.filter { !$0.items.isEmpty }
        let counts = Dictionary(groups.map { ($0.day, $0.items.count) }, uniquingKeysWith: { first, _ in first })

        return List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    DayStrip(days: Array(days.prefix(14)), counts: counts) { day in
                        // Jump to that day, or the next one that has something.
                        if let target = groups.first(where: { $0.day >= day })?.items.first {
                            withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                        }
                    }
                    if connected.count > 1 {
                        SourceChips(sources: connected, selected: selected) { filter = $0 }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if groups.isEmpty {
                Section {
                    EmptyNote(symbol: query.isEmpty ? "calendar" : "magnifyingglass",
                              title: query.isEmpty ? "Nothing coming up" : "No matches",
                              text: query.isEmpty ? "Events and tasks for the next 30 days show up here." : "")
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { ItemRow(item: $0, day: group.day) }
                } header: {
                    SectionTitle(title: group.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                                 detail: away(group.day, from: today, calendar: cal))
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private func away(_ day: Date, from today: Date, calendar: Calendar) -> String {
        let n = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        return n == 1 ? "Tomorrow" : "in \(n) days"
    }
}

/// Two weeks of days in a row. The dots show how much is on each day.
struct DayStrip: View {
    let days: [Date]
    let counts: [Date: Int]
    let pick: (Date) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    cell(day, count: counts[day] ?? 0)
                }
            }
        }
    }

    private func cell(_ day: Date, count: Int) -> some View {
        Button {
            pick(day)
        } label: {
            VStack(spacing: 5) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Calendar.current.isDateInWeekend(day) ? Color.red.opacity(0.8) : Color.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.primary)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index < count ? Theme.accent : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .frame(width: 48)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .opacity(count > 0 ? 1 : 0.55)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(count) items")
    }
}
#endif
