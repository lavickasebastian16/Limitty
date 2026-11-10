#if os(iOS)
import SwiftUI
import WebKit
import WidgetKit
import LimittyCore

@main
struct LimittyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(model)
        }
    }
}

@Observable
@MainActor
final class AppModel {
    private(set) var snapshots: [Provider: ProviderSnapshot] = [:]
    private(set) var signedIn: Set<Provider> = []
    private(set) var refreshing = false
    let store = SharedStore.shared
    private let service = LimitsService()

    init() {
        signedIn = Set(service.signedIn)
        for s in service.cached() { snapshots[s.provider] = s }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let results = await service.refreshAll()
        snapshots = Dictionary(uniqueKeysWithValues: results.map { ($0.provider, $0) })
        WidgetCenter.shared.reloadAllTimelines()
    }

    func save(_ credential: Credential, for provider: Provider) {
        store.setCredential(credential, for: provider)
        signedIn.insert(provider)
        Task { await refresh() }
    }

    func signOut(_ provider: Provider) {
        store.setCredential(nil, for: provider)
        store.removeSnapshot(provider)
        signedIn.remove(provider)
        snapshots[provider] = nil
        Task { await clearCookies(for: provider) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Removes the in-app browser's cookies for a provider, so the next sign-in starts fresh.
@MainActor
func clearCookies(for provider: Provider) async {
    let cookieStore = WKWebsiteDataStore.default().httpCookieStore
    for cookie in await cookieStore.allCookies() where cookie.domain.hasSuffix(provider.cookieDomain) {
        await cookieStore.deleteCookie(cookie)
    }
}
#endif
