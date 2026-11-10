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
                    Section {
                        soundPicker("Needs permission", \.notify.localSounds.attention)
                        soundPicker("Done", \.notify.localSounds.done)
                    } header: {
                        Text("Sounds")
                    } footer: {
                        Text("Tap ▶︎ to hear a sound.")
                    }
                    Section {
                        Button("Open iPhone notification settings") {
                            openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                        }
                    } footer: {
                        Text("Limitty checks on your agents while it's open, and now and then in the background when iOS allows it. iPhone apps installed without a paid Apple developer account can't receive instant pushes, so alerts can arrive late, or only when you open Limitty.")
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await AlertCenter.shared.requestPermission() }
        }
    }

    private func binding(_ path: WritableKeyPath<PhoneSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.phone[keyPath: path] }, set: { v in model.updatePhone { $0[keyPath: path] = v } })
    }

    private func soundPicker(_ title: String, _ path: WritableKeyPath<PhoneSettings, String>) -> some View {
        HStack {
            Picker(title, selection: Binding(get: { model.phone[keyPath: path] }, set: { v in
                model.updatePhone { $0[keyPath: path] = v }
                AlertCenter.shared.preview(v)
            })) {
                ForEach(LocalSound.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Button {
                AlertCenter.shared.preview(model.phone[keyPath: path])
            } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
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
                    Text(model.phone.notify.enabled ? "On" : "Off").foregroundStyle(.secondary).font(.footnote)
                }
            }
        } footer: {
            Text("Different sounds for “needs permission” and “done”.")
        }
    }
}
#endif
