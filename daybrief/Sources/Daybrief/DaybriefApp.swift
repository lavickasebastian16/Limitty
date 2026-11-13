#if os(iOS)
import SwiftUI
import DaybriefCore

@main
struct DaybriefApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        Notifier.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await model.refreshIfStale() } }
                    if now == .background { Notifier.shared.scheduleBackgroundRefresh() }
                }
        }
        // iOS wakes Daybrief now and then; each refresh reschedules the summaries.
        .backgroundTask(.appRefresh(Notifier.refreshTaskID)) {
            await Notifier.shared.scheduleBackgroundRefresh()
            await model.refresh()
        }
    }
}
#endif
