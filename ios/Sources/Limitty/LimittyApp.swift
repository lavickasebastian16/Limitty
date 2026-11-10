#if os(iOS)
import SwiftUI
import WebKit
import WidgetKit
import LimittyCore

@main
struct LimittyApp: App {
    @State private var model = AppModel()

    init() {
        AlertCenter.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(model)
        }
        // iOS wakes Limitty now and then to check on your agents and alert you.
        .backgroundTask(.appRefresh(AlertCenter.refreshTaskID)) {
            await AlertCenter.shared.scheduleBackgroundRefresh()
            await model.refreshAgents()
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
    /// Company mode: tasks for the agents on your PC (GitHub sign-in only).
    private(set) var company: CompanyState?
    /// Tasks sent from this phone that the PC hasn't picked up yet.
    private(set) var pendingTasks: [CompanyRequest] = []
    private let feed = AgentFeed()
    private let githubFeed = GitHubStatusFeed()

    /// Notification settings (also saved to the Gist so the PC can send Bark alerts).
    private(set) var phone: PhoneSettings
    private(set) var phoneSyncError: String?
    private var phoneSyncTask: Task<Void, Never>?

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
        company = store.cachedCompany()
        phone = store.phoneSettings()
    }

    func updatePhone(_ change: (inout PhoneSettings) -> Void) {
        change(&phone)
        phone.updatedAt = Date().timeIntervalSince1970
        store.savePhoneSettings(phone)
        syncPhone()
    }

    /// Saves the settings to the Gist (debounced), so the PC uses your Bark key and sounds.
    private func syncPhone() {
        phoneSyncTask?.cancel()
        guard let gh = github, gh.gistId != nil else { return }
        let settings = phone
        phoneSyncTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try await githubFeed.savePhoneSettings(settings, account: gh)
                phoneSyncError = nil
            } catch let e as LimitError {
                phoneSyncError = "Couldn't save to your PC: \(e.message)"
            } catch {
                phoneSyncError = "Couldn't save to your PC. Check your connection."
            }
        }
    }

    /// Local notifications for what changed. With Bark set up, the PC sends them instead.
    private func deliver(_ alerts: [AgentAlert]) {
        guard !alerts.isEmpty, phone.notify.bark == nil || github == nil else { return }
        for a in alerts where phone.wants(a.kind, task: a.isTask) {
            AlertCenter.shared.post(a, settings: phone)
        }
    }

    /// Skips changes that happened long ago (e.g. the first refresh after days away).
    private func isRecent(_ t: Double) -> Bool { Date().timeIntervalSince1970 - t < 15 * 60 }

    var canSendTasks: Bool { github?.gistId != nil }

    func sendTask(title: String, project: String, worker: String) async throws {
        guard let gh = github else { throw LimitError("Sign in with GitHub first") }
        let req = CompanyRequest.create(title: title, project: project, worker: worker)
        try await githubFeed.send(req, account: gh)
        pendingTasks.append(req)
    }

    func taskAction(_ kind: String, _ task: CompanyTask) async {
        guard let gh = github else { return }
        do {
            try await githubFeed.send(.action(kind, task: task.id), account: gh)
            agentError = nil
        } catch let e as LimitError {
            agentError = e.message
        } catch {
            agentError = error.localizedDescription
        }
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
                let all = try await githubFeed.fetchAll(gh)
                status = all.status
                if let c = all.company, c != company {
                    deliver(AlertDetector.alerts(from: company, to: c).filter { a in
                        c.tasks.first { "task-\($0.id)" == a.id }.map { isRecent($0.updatedAt) } ?? false
                    })
                    company = c
                    store.saveCompany(c)
                }
                // Drop "sent" placeholders once the PC lists the task (or after 10 minutes).
                let titles = Set(company?.tasks.map(\.title) ?? [])
                pendingTasks.removeAll { titles.contains($0.title ?? "") || Date().timeIntervalSince1970 - $0.at > 600 }
            } else if let pairing {
                status = try await feed.fetch(pairing)
            } else {
                return
            }
            if let status, status != agentStatus {
                if isRecent(status.sentAt) { deliver(AlertDetector.alerts(from: agentStatus, to: status)) }
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
        Task {
            await refreshAgents()
            syncPhone() // the PC learns your notification settings
            await AlertCenter.shared.requestPermission()
        }
    }

    func disconnectGitHub() {
        store.setGitHubAccount(nil)
        github = nil
        company = nil
        store.saveCompany(nil)
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
