#if os(iOS)
import Foundation
import UserNotifications
import BackgroundTasks
import DaybriefCore

/// Schedules the morning summary and the evening-before warning as local notifications.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshTaskID = "com.limitty.daybrief.refresh"

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once; later calls just report the answer.
    @discardableResult
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        return status == .authorized || status == .provisional
    }

    func isAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Replaces every scheduled summary with the new plan.
    func schedule(_ plan: [PlannedNotification]) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(NotificationPlanner.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        for p in plan {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            let c = content(p.title, p.body)
            if let badge = p.badge { c.badge = NSNumber(value: badge) }
            try? await center.add(UNNotificationRequest(identifier: p.id, content: c, trigger: trigger))
        }
    }

    /// The number on the app icon (0 removes it).
    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Shows a summary right away (the "Send a test summary" button).
    func post(_ brief: Brief) async {
        let request = UNNotificationRequest(identifier: "test-\(Int(Date().timeIntervalSince1970))",
                                            content: content(brief.title, brief.body), trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func content(_ title: String, _ body: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = "daybrief"
        return c
    }

    // Show banners while Daybrief is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Asks iOS to wake Daybrief now and then to refresh (iOS decides when).
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
