#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import DaybriefCore

/// Settings: the sources, the daily summary, and the list.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.settings.calendar }, set: { on in
                        model.update { $0.calendar = on }
                        Task { await model.refresh(only: [.calendar]) }
                    })) { SourceLabel(source: .calendar) }
                    Toggle(isOn: Binding(get: { model.settings.reminders }, set: { on in
                        model.update { $0.reminders = on }
                        Task { await model.refresh(only: [.reminders]) }
                    })) { SourceLabel(source: .reminders) }
                    NavigationLink {
                        ObsidianSettings()
                    } label: {
                        SourceLabel(source: .obsidian)
                    }
                    NavigationLink {
                        EduPageSettings()
                    } label: {
                        SourceLabel(source: .edupage)
                    }
                    NavigationLink {
                        GmailSettings()
                    } label: {
                        SourceLabel(source: .gmail)
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("iOS asks for permission the first time you turn on Calendar or Reminders. Daybrief only reads them, except when you tick a task off, move it, or add one by voice.")
                }

                summary

                Section {
                    Toggle("Count on the app icon", isOn: Binding(get: { model.settings.badge }, set: { on in
                        model.update { $0.badge = on }
                        Task { await model.reschedule() }
                    }))
                    if !model.hidden.isEmpty {
                        Button("Show \(model.hidden.count) hidden \(model.hidden.count == 1 ? "item" : "items") again") { model.showHidden() }
                    }
                } header: {
                    Text("List")
                } footer: {
                    Text("The count is today's items plus overdue tasks.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear {
                // The first connection is a good moment to ask for notifications.
                Task {
                    if model.anyConnected { await model.askForNotifications() } else { await model.reschedule() }
                }
            }
        }
    }

    private var summary: some View {
        Section {
            Toggle("Morning summary", isOn: Binding(get: { model.settings.schedule.morningEnabled }, set: { on in
                model.update { $0.schedule.morningEnabled = on }
                if on { Task { await model.askForNotifications() } }
            }))
            if model.settings.schedule.morningEnabled {
                DatePicker("Time", selection: time(\.morningHour, \.morningMinute), displayedComponents: .hourAndMinute)
            }
            Toggle("Evening before, if there's something tomorrow", isOn: Binding(get: { model.settings.schedule.eveningEnabled }, set: { on in
                model.update { $0.schedule.eveningEnabled = on }
                if on { Task { await model.askForNotifications() } }
            }))
            if model.settings.schedule.eveningEnabled {
                DatePicker("Time", selection: time(\.eveningHour, \.eveningMinute), displayedComponents: .hourAndMinute)
            }
            Button("Send a test summary now") {
                Task { await model.sendTest() }
            }
            if !model.notificationsAllowed {
                Label("Notifications are off for Daybrief in the iPhone's Settings.", systemImage: "bell.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Daily summary")
        } footer: {
            Text("Summaries for the next 7 days are scheduled each time Daybrief refreshes: when you open it, and now and then in the background when iOS allows. Open Daybrief every few days so they stay up to date.")
        }
    }

    /// A time-of-day picker bound to an hour and a minute in the schedule.
    private func time(_ hour: WritableKeyPath<BriefSchedule, Int>, _ minute: WritableKeyPath<BriefSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let s = model.settings.schedule
            return Calendar.current.date(bySettingHour: s[keyPath: hour], minute: s[keyPath: minute], second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.update {
                $0.schedule[keyPath: hour] = parts.hour ?? 7
                $0.schedule[keyPath: minute] = parts.minute ?? 0
            }
        })
    }
}

/// A source's icon and name, with how it is doing underneath.
struct SourceLabel: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: source.symbol, color: source.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(model.errors[source] != nil ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var status: String {
        if let error = model.errors[source] { return error }
        guard model.isConnected(source) else { return "Not connected" }
        let count = model.items[source]?.count ?? 0
        return "Connected · \(count) \(count == 1 ? "item" : "items")"
    }
}

/// The line under a source's form: what went wrong, or that it works.
struct SourceStatus: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        if let error = model.errors[source] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if model.isConnected(source) {
            Label(model.refreshing ? "Checking…" : "Connected · \(model.items[source]?.count ?? 0) found", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        }
    }
}

struct ObsidianSettings: View {
    @Environment(AppModel.self) private var model
    @State private var pickFolder = false

    var body: some View {
        Form {
            Section {
                if model.obsidianConnected {
                    LabeledContent("Vault", value: model.settings.obsidianVault ?? "")
                    SourceStatus(source: .obsidian)
                    Button("Disconnect", role: .destructive) {
                        model.disconnectObsidian()
                        Task { await model.refresh(only: [.obsidian]) }
                    }
                } else {
                    Button("Choose vault folder…") { pickFolder = true }
                    SourceStatus(source: .obsidian)
                }
            } footer: {
                Text("Pick the vault folder itself: On My iPhone → Obsidian → your vault, or iCloud Drive → Obsidian → your vault.")
            }
            Section {
                Text("- [ ] Buy milk\n- [ ] Essay 📅 2026-11-14\n- [ ] Call the dentist [due:: 2026-11-15]")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("What is read")
            } footer: {
                Text("Open tasks and their dates. A task in a daily note (2026-11-14.md) counts as due that day. Ticking a task in Daybrief ticks it in the note.")
            }
        }
        .navigationTitle("Obsidian")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                model.connectObsidian(folder)
                Task { await model.refresh(only: [.obsidian]) }
            }
        }
    }
}

struct EduPageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var school = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if model.isConnected(.edupage) {
                    LabeledContent("School", value: model.settings.eduSchool)
                    LabeledContent("User", value: model.settings.eduUser)
                    SourceStatus(source: .edupage)
                    Button("Disconnect", role: .destructive) {
                        model.disconnectEduPage()
                        password = ""
                        Task { await model.refresh(only: [.edupage]) }
                    }
                } else {
                    TextField("School (e.g. myschool)", text: $school)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button("Connect") {
                        model.connectEduPage(school: school, user: user, password: password)
                        Task { await model.refresh(only: [.edupage]) }
                    }
                    .disabled(school.isEmpty || user.isEmpty || password.isEmpty)
                    SourceStatus(source: .edupage)
                }
            } footer: {
                Text("The school is the first part of your EduPage address (myschool.edupage.org). Daybrief shows homework, exams and school events. Your password stays in this iPhone's Keychain and is only sent to EduPage.")
            }
        }
        .navigationTitle("EduPage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            school = model.settings.eduSchool
            user = model.settings.eduUser
        }
    }
}

struct GmailSettings: View {
    @Environment(AppModel.self) private var model
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if model.isConnected(.gmail) {
                    LabeledContent("Account", value: model.settings.gmailUser)
                    SourceStatus(source: .gmail)
                    Button("Disconnect", role: .destructive) {
                        model.disconnectGmail()
                        password = ""
                        Task { await model.refresh(only: [.gmail]) }
                    }
                } else {
                    TextField("you@gmail.com", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("App password (16 letters)", text: $password)
                    Link("Create an app password", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                    Button("Connect") {
                        model.connectGmail(user: user, password: password)
                        Task { await model.refresh(only: [.gmail]) }
                    }
                    .disabled(user.isEmpty || password.isEmpty)
                    SourceStatus(source: .gmail)
                }
            } footer: {
                Text("Gmail needs an app password, not your normal one: turn on 2-Step Verification in your Google account, then create an app password and paste it here. Nothing is marked as read.")
            }
            if model.isConnected(.gmail) {
                Section {
                    TextField("Search", text: Binding(get: { model.settings.gmailQuery }, set: { query in model.update { $0.gmailQuery = query } }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .onSubmit { Task { await model.refresh(only: [.gmail]) } }
                    Button("Use the usual search") {
                        model.update { $0.gmailQuery = AppSettings.defaultGmailQuery }
                        Task { await model.refresh(only: [.gmail]) }
                    }
                } header: {
                    Text("Which mail to show")
                } footer: {
                    Text("Uses Gmail's search words, in your inbox. The usual search shows starred mail and unread mail from the last week in the Primary tab.")
                }
            }
        }
        .navigationTitle("Gmail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { user = model.settings.gmailUser }
    }
}
#endif
