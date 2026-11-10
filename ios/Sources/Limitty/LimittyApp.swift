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

    // Agent status relayed from the PC companion.
    private(set) var pairing: AgentPairing?
    private(set) var agentStatus: AgentStatus?
    private(set) var agentError: String?
    private(set) var github: GitHubAccount?
    private let feed = AgentFeed()
    private let githubFeed = GitHubStatusFeed()

    var agentsConnected: Bool { github != nil || pairing != nil }
    /// ntfy topic/server for push alerts (from the PC's status in GitHub mode, or the QR pairing).
    var alertsTopic: String? { agentStatus?.alertsTopic ?? pairing?.alertsTopic }
    var alertsServer: String { agentStatus?.ntfyServer ?? pairing?.server ?? "https://ntfy.sh" }

    init() {
        signedIn = Set(service.signedIn)
        for s in service.cached() { snapshots[s.provider] = s }
        pairing = store.agentPairing()
        github = store.githubAccount()
        agentStatus = store.cachedAgentStatus()
    }

    func refreshAgents() async {
        do {
            let status: AgentStatus?
            if var gh = github {
                // The PC creates the Gist when it connects; keep looking until it does.
                if gh.gistId == nil, let id = try await githubFeed.findGist(token: gh.token) {
                    gh.gistId = id
                    github = gh
                    store.setGitHubAccount(gh)
                }
                status = try await githubFeed.fetch(gh)
            } else if let pairing {
                status = try await feed.fetch(pairing)
            } else {
                return
            }
            if let status, status != agentStatus {
                agentStatus = status
                store.saveAgentStatus(status)
                WidgetCenter.shared.reloadTimelines(ofKind: "AgentsWidget")
            }
            agentError = nil
        } catch let e as LimitError {
            agentError = e.message
        } catch {
            agentError = "Can't reach the server. Check your connection."
        }
    }

    func connectGitHub(_ account: GitHubAccount) {
        store.setGitHubAccount(account)
        github = account
        agentStatus = nil
        agentError = nil
        Task { await refreshAgents() }
    }

    func disconnectGitHub() {
        store.setGitHubAccount(nil)
        github = nil
        agentStatus = nil
        store.setAgentPairing(pairing) // keeps a QR pairing if there is one; clears cached status otherwise
        WidgetCenter.shared.reloadTimelines(ofKind: "AgentsWidget")
    }

    func pair(_ p: AgentPairing) {
        store.setAgentPairing(p)
        pairing = p
        agentStatus = nil
        agentError = nil
        Task { await refreshAgents() }
    }

    func unpair() {
        store.setAgentPairing(nil)
        pairing = nil
        agentStatus = nil
        WidgetCenter.shared.reloadTimelines(ofKind: "AgentsWidget")
    }

    /// limitty://pair?… (from the QR code) or limitty://agents (from an alert).
    func handle(_ url: URL) {
        if url.host == "pair", let p = AgentPairing.parse(url.absoluteString) { pair(p) }
        Task { await refreshAgents() }
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
