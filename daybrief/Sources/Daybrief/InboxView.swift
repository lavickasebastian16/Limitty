#if os(iOS)
import SwiftUI
import DaybriefCore

/// Things without a day: waiting email and tasks that have no date.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showVoice: Bool
    @State var search = ""

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Inbox")
                .searchable(text: $search, prompt: "Search inbox")
                .toolbar { GearButton(show: $showSettings) }
                .micButton($showVoice)
        }
    }

    private func matches(_ item: Item, _ query: String) -> Bool {
        query.isEmpty || item.title.localizedStandardContains(query) || (item.detail ?? "").localizedStandardContains(query)
    }

    private var list: some View {
        let agenda = model.agenda
        let query = search.trimmingCharacters(in: .whitespaces)
        let mail = agenda.mail.filter { matches($0, query) }
        let undated = agenda.undated.filter { matches($0, query) }

        return List {
            if mail.isEmpty && undated.isEmpty {
                Section {
                    EmptyNote(symbol: query.isEmpty ? "tray" : "magnifyingglass",
                              title: query.isEmpty ? "Nothing waiting" : "No matches",
                              text: query.isEmpty ? "Email to deal with and tasks without a date show up here." : "")
                }
            }
            if !mail.isEmpty {
                Section {
                    ForEach(mail) { ItemRow(item: $0, showDay: true) }
                } header: {
                    SectionTitle(title: "Email", detail: "\(mail.count)")
                }
            }
            if !undated.isEmpty {
                Section {
                    ForEach(undated) { ItemRow(item: $0) }
                } header: {
                    SectionTitle(title: "No date", detail: "\(undated.count)")
                }
            }
        }
        .refreshable { await model.refresh() }
    }
}
#endif
