#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import DaybriefCore

/// Where you connect each source and choose when the summaries arrive.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickFolder = false
    @State private var busy = false

    @State private var eduSchool = ""
    @State private var eduUser = ""
    @State private var eduPassword = ""
    @State private var gmailUser = ""
    @State private var gmailPassword = ""

    var body: some View {
        NavigationStack {
            Form {
                apple
                obsidian
                eduPage
                gmail
                schedule
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result {
                    model.connectObsidian(folder)
                    refresh()
                }
            }
            .onAppear {
                eduSchool = model.settings.eduSchool
                eduUser = model.settings.eduUser
                gmailUser = model.settings.gmailUser
            }
            .onDisappear {
                // The first connection is a good moment to ask for notifications.
                Task {
                    if model.anyConnected { await model.askForNotifications() } else { await model.reschedule() }
                }
            }
        }
    }

    private func refresh() {
        Task {
            busy = true
            await model.refresh()
            busy = false
        }
    }

    @ViewBuilder
    private func status(_ source: Source) -> some View {
        if let error = model.errors[source] {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
        } else if model.isConnected(source) {
            Label(busy ? "Checking…" : "Connected · \(model.items[source]?.count ?? 0) found", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.green)
        }
    }

    private var apple: some View {
        Section {
            Toggle("Apple Calendar", isOn: Binding(get: { model.settings.calendar }, set: { on in
                model.update { $0.calendar = on }
                refresh()
            }))
            status(.calendar)
            Toggle("Apple Reminders", isOn: Binding(get: { model.settings.reminders }, set: { on in
                model.update { $0.reminders = on }
                refresh()
            }))
            status(.reminders)
        } header: {
            Text("Apple")
        } footer: {
            Text("iOS asks for permission the first time. Daybrief only reads, except when you swipe a reminder to mark it done.")
        }
    }

    private var obsidian: some View {
        Section {
            if model.obsidianConnected {
                LabeledContent("Vault", value: model.settings.obsidianVault ?? "")
                status(.obsidian)
                Button("Disconnect", role: .destructive) {
                    model.disconnectObsidian()
                    refresh()
                }
            } else {
                Button("Choose vault folder…") { pickFolder = true }
                status(.obsidian)
            }
        } header: {
            Text("Obsidian")
        } footer: {
            Text("Pick the vault folder itself: On My iPhone → Obsidian → your vault, or iCloud Drive → Obsidian → your vault. Daybrief reads open tasks (- [ ]) and their dates: 📅 2026-11-14, [due:: 2026-11-14], or the date of a daily note.")
        }
    }

    private var eduPage: some View {
        Section {
            if model.isConnected(.edupage) {
                LabeledContent("School", value: model.settings.eduSchool)
                LabeledContent("User", value: model.settings.eduUser)
                status(.edupage)
                Button("Disconnect", role: .destructive) {
                    model.disconnectEduPage()
                    eduPassword = ""
                    refresh()
                }
            } else {
                TextField("School (e.g. myschool)", text: $eduSchool)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $eduUser)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $eduPassword)
                Button("Connect") {
                    model.connectEduPage(school: eduSchool, user: eduUser, password: eduPassword)
                    refresh()
                }
                .disabled(eduSchool.isEmpty || eduUser.isEmpty || eduPassword.isEmpty)
                status(.edupage)
            }
        } header: {
            Text("EduPage")
        } footer: {
            Text("The school is the first part of your EduPage address (myschool.edupage.org). Daybrief shows homework, exams and school events. Your password stays in this iPhone's Keychain and is only sent to EduPage.")
        }
    }

    private var gmail: some View {
        Section {
            if model.isConnected(.gmail) {
                LabeledContent("Account", value: model.settings.gmailUser)
                TextField("Search", text: Binding(get: { model.settings.gmailQuery }, set: { q in model.update { $0.gmailQuery = q } }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.footnote)
                    .onSubmit { refresh() }
                status(.gmail)
                Button("Disconnect", role: .destructive) {
                    model.disconnectGmail()
                    gmailPassword = ""
                    refresh()
                }
            } else {
                TextField("you@gmail.com", text: $gmailUser)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("App password (16 letters)", text: $gmailPassword)
                Link("Create an app password", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                Button("Connect") {
                    model.connectGmail(user: gmailUser, password: gmailPassword)
                    refresh()
                }
                .disabled(gmailUser.isEmpty || gmailPassword.isEmpty)
                status(.gmail)
            }
        } header: {
            Text("Gmail")
        } footer: {
            Text("Gmail needs an app password, not your normal one: turn on 2-Step Verification in your Google account, then create an app password and paste it here. Daybrief shows starred mail and unread mail from the last week; you can change the search (it uses Gmail's search words). Nothing is marked as read.")
        }
    }

    private var schedule: some View {
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
            Toggle("Count on the app icon", isOn: Binding(get: { model.settings.badge }, set: { on in
                model.update { $0.badge = on }
                Task { await model.reschedule() }
            }))
            if !model.hidden.isEmpty {
                Button("Show \(model.hidden.count) hidden \(model.hidden.count == 1 ? "item" : "items") again") { model.showHidden() }
            }
            Button("Send a test summary now") {
                Task { await model.sendTest() }
            }
            if !model.notificationsAllowed {
                Label("Notifications are off for Daybrief in the iPhone's Settings.", systemImage: "bell.slash")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Daily summary")
        } footer: {
            Text("The count on the app icon is today's items plus overdue tasks. Summaries for the next 7 days are scheduled each time Daybrief refreshes: when you open it, and now and then in the background when iOS allows. Open Daybrief every few days so they stay up to date.")
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
#endif
