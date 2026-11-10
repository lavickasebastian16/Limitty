#if os(iOS)
import SwiftUI
import UserNotifications
import AVFoundation
import AudioToolbox
import BackgroundTasks
import LimittyCore

/// Posts Limitty's own notifications (with its own sounds) and plays sound previews.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()
    static let refreshTaskID = "com.limitty.app.refresh"

    private var player: AVAudioPlayer?
    private(set) var authorized = false

    private var soundsDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    func setUp() {
        LocalSound.install(in: soundsDir)
        UNUserNotificationCenter.current().delegate = self
        Task { authorized = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized }
    }

    /// Asks once; later calls just report the answer.
    @discardableResult
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        } else {
            authorized = status == .authorized || status == .provisional
        }
        return authorized
    }

    func notificationSound(_ name: String) -> UNNotificationSound {
        guard let s = LocalSound(rawValue: name), s != .system else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(s.fileName))
    }

    func post(_ alert: AgentAlert, settings: PhoneSettings) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = notificationSound(alert.kind == .attention ? settings.notify.localSounds.attention : settings.notify.localSounds.done)
        content.threadIdentifier = alert.kind == .attention ? "needs-you" : "done"
        content.interruptionLevel = .active
        content.userInfo = ["url": alert.isTask ? "limitty://tasks" : "limitty://agents"]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func preview(_ name: String) {
        guard let s = LocalSound(rawValue: name), s != .system else {
            AudioServicesPlaySystemSound(1007) // the standard notification sound
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        player = try? AVAudioPlayer(contentsOf: soundsDir.appendingPathComponent(s.fileName))
        player?.play()
    }

    // Show banners with sound while Limitty is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Asks iOS to wake Limitty now and then to check on your agents (iOS decides when).
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Settings → Notifications.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pasteError: String?
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Notifications", isOn: binding(\.notify.enabled))
                    if model.phone.notify.enabled {
                        Toggle("When an agent is done", isOn: binding(\.notify.finished))
                        Toggle("When a task is done or fails", isOn: binding(\.notify.tasks))
                    }
                } footer: {
                    Text("You always get an alert when an agent needs your permission or has a question.")
                }

                if model.phone.notify.enabled {
                    barkSection
                    soundsSection
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await AlertCenter.shared.requestPermission() }
        }
    }

    private var usingBark: Bool { model.phone.notify.bark != nil }

    @ViewBuilder
    private var soundsSection: some View {
        Section {
            if usingBark {
                soundPicker("Needs permission", \.notify.sounds.attention, BarkSound.all, BarkSound.label)
                soundPicker("Done", \.notify.sounds.done, BarkSound.all, BarkSound.label)
            } else {
                soundPicker("Needs permission", \.notify.localSounds.attention, LocalSound.allCases.map(\.rawValue)) { LocalSound(rawValue: $0)?.label ?? $0 }
                soundPicker("Done", \.notify.localSounds.done, LocalSound.allCases.map(\.rawValue)) { LocalSound(rawValue: $0)?.label ?? $0 }
            }
        } header: {
            Text("Sounds")
        } footer: {
            Text(usingBark
                 ? "Bark plays these. Tap Send test alerts above to hear both."
                 : "Tap ▶︎ to hear a sound.")
        }
    }

    @ViewBuilder
    private var barkSection: some View {
        Section {
            if let bark = model.phone.notify.bark {
                LabeledContent("Instant alerts", value: "On")
                LabeledContent("Bark key", value: "…" + String(bark.key.suffix(4)))
                Button {
                    sendTests(bark)
                } label: {
                    HStack { Text("Send test alerts"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(testing)
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                Button("Turn off Bark", role: .destructive) { model.updatePhone { $0.notify.bark = nil } }
            } else {
                Button("1. Get Bark (free) from the App Store") {
                    openURL(URL(string: "https://apps.apple.com/app/id1403753865")!)
                }
                Text("2. Open Bark, allow notifications, and tap the copy button next to the first example link.")
                    .font(.footnote)
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in usePasted(strings.first ?? "") }
                }
                if let pasteError { Text(pasteError).font(.footnote).foregroundStyle(.red) }
            }
            if model.github == nil {
                Text("Bark alerts come from your PC, so sign in with GitHub (Agents on your PC) first.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let err = model.phoneSyncError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Instant alerts, even when Limitty is closed")
        } footer: {
            Text(usingBark
                 ? "Your PC sends each alert straight to Bark: one sound when an agent needs permission, another when it's done."
                 : "Without Bark, Limitty alerts you while it's open, and now and then in the background when iOS lets it. iPhone apps installed without a paid developer account can't get instant pushes themselves, so Bark delivers them.")
        }
    }

    private func usePasted(_ text: String) {
        guard let bark = BarkLink.parse(text) else {
            pasteError = "That doesn't look like a Bark link. In Bark, tap the copy button next to an example link, then try again."
            return
        }
        pasteError = nil
        model.updatePhone { $0.notify.bark = bark }
        sendTests(bark)
    }

    private func sendTests(_ bark: PhoneSettings.Bark) {
        testing = true
        testResult = nil
        let sounds = model.phone.notify.sounds
        Task {
            do {
                try await BarkLink.send(bark, title: "Limitty: an agent needs you", body: "This is the “needs permission” sound.", sound: sounds.attention, kind: .attention)
                try await Task.sleep(for: .seconds(4))
                try await BarkLink.send(bark, title: "Limitty: an agent is done", body: "This is the “done” sound.", sound: sounds.done, kind: .done)
                testResult = "Sent two test alerts. You should hear two different sounds."
            } catch let e as LimitError {
                testResult = e.message
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func binding(_ path: WritableKeyPath<PhoneSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.phone[keyPath: path] }, set: { v in model.updatePhone { $0[keyPath: path] = v } })
    }

    private func soundPicker(_ title: String, _ path: WritableKeyPath<PhoneSettings, String>, _ options: [String], _ label: @escaping (String) -> String) -> some View {
        HStack {
            Picker(title, selection: Binding(get: { model.phone[keyPath: path] }, set: { v in
                model.updatePhone { $0[keyPath: path] = v }
                if !usingBark { AlertCenter.shared.preview(v) }
            })) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            if !usingBark {
                Button {
                    AlertCenter.shared.preview(model.phone[keyPath: path])
                } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// The row on the main screen.
struct NotificationsRow: View {
    @Environment(AppModel.self) private var model
    @Binding var show: Bool

    var body: some View {
        Section {
            Button {
                show = true
            } label: {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(summary).foregroundStyle(.secondary).font(.footnote)
                }
            }
        } footer: {
            Text("Different sounds for “needs permission” and “done”.")
        }
    }

    private var summary: String {
        let n = model.phone.notify
        if !n.enabled { return "Off" }
        return n.bark != nil ? "Instant (Bark)" : "In Limitty"
    }
}
#endif
