#if os(iOS)
import SwiftUI
import DaybriefCore

/// The three tabs: Today, Upcoming and Inbox.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showVoice = false

    var body: some View {
        TabView {
            TodayView(showSettings: $showSettings, showVoice: $showVoice)
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            UpcomingView(showSettings: $showSettings, showVoice: $showVoice)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
            InboxView(showSettings: $showSettings, showVoice: $showVoice)
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .badge(model.agenda.mail.count)
        }
        .sheet(isPresented: $showSettings) { SettingsView().tint(Theme.accent) }
        .sheet(isPresented: $showVoice) { VoiceSheet().tint(Theme.accent) }
        .task {
            if model.anyConnected { await model.askForNotifications() }
            await model.refreshIfStale()
        }
    }
}
#endif
