import Foundation

/// Fetches every signed-in provider, saves the results, and falls back to the
/// last good numbers (marked stale) when the network is down.
public struct LimitsService: Sendable {
    let store: SharedStore
    let claude: ClaudeClient
    let codex: CodexClient
    let gemini: GeminiClient

    public init(store: SharedStore = .shared, http: HTTPClient = URLSessionHTTPClient()) {
        self.store = store
        self.claude = ClaudeClient(http: http)
        self.codex = CodexClient(http: http)
        self.gemini = GeminiClient(http: http)
    }

    /// Providers you've signed in to, in display order.
    public var signedIn: [Provider] { Provider.allCases.filter { store.credential(for: $0) != nil } }

    public func refreshAll(now: Date = Date()) async -> [ProviderSnapshot] {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for p in signedIn { group.addTask { await refresh(p, now: now) } }
            var out: [ProviderSnapshot] = []
            for await s in group { out.append(s) }
            return out.sorted { Provider.allCases.firstIndex(of: $0.provider)! < Provider.allCases.firstIndex(of: $1.provider)! }
        }
    }

    public func refresh(_ p: Provider, now: Date = Date()) async -> ProviderSnapshot {
        guard let cred = store.credential(for: p) else {
            return ProviderSnapshot(provider: p, error: LimitError.notSignedIn.message, hint: LimitError.notSignedIn.hint, fetchedAt: now)
        }
        do {
            let result: (plan: String?, windows: [LimitWindow])
            switch p {
            case .claude: result = try await claude.fetch(cred)
            case .codex: result = try await codex.fetch(cred, now: now)
            case .gemini:
                let r = try await gemini.fetch(cred, now: now)
                // Keep the refreshed Google token so the app and widget share it.
                if let updated = r.updated { store.setCredential(updated, for: .gemini) }
                result = (r.plan, r.windows)
            }
            let snap = ProviderSnapshot(provider: p, plan: result.plan, windows: result.windows, fetchedAt: now)
            store.saveSnapshot(snap)
            return snap
        } catch {
            let le = error as? LimitError ?? LimitError(Self.describe(error))
            // Offline or a server hiccup: keep showing the last numbers for up to a day.
            if !le.isAuth, var cached = store.snapshots()[p], cached.ok, now.timeIntervalSince(cached.fetchedAt) < 86_400 {
                cached.stale = true
                return cached
            }
            return ProviderSnapshot(provider: p, error: le.message, hint: le.hint, fetchedAt: now)
        }
    }

    /// Last saved results, without touching the network.
    public func cached() -> [ProviderSnapshot] {
        let all = store.snapshots()
        return signedIn.compactMap { all[$0] }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Can't reach the server" }
        return ns.localizedDescription
    }
}

/// Sample data for widget previews and the placeholder state.
public enum SampleData {
    public static func snapshots(now: Date = Date()) -> [ProviderSnapshot] {
        [
            ProviderSnapshot(provider: .claude, plan: "Max", windows: [
                LimitWindow(id: "five_hour", label: "Session", usedPercent: 42, resetsAt: now.addingTimeInterval(2.3 * 3600)),
                LimitWindow(id: "seven_day", label: "Weekly", usedPercent: 67, resetsAt: now.addingTimeInterval(3.2 * 86_400)),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .codex, plan: "Plus", windows: [
                LimitWindow(id: "primary", label: "Session", usedPercent: 91, resetsAt: now.addingTimeInterval(0.4 * 3600)),
                LimitWindow(id: "secondary", label: "Weekly", usedPercent: 38, resetsAt: now.addingTimeInterval(5 * 86_400)),
            ], fetchedAt: now),
            ProviderSnapshot(provider: .gemini, plan: "Google AI Pro", windows: [
                LimitWindow(id: "gemini_pro", label: "Gemini Pro", usedPercent: 15, resetsAt: now.addingTimeInterval(3 * 3600)),
                LimitWindow(id: "gemini_flash", label: "Gemini Flash", usedPercent: 4, resetsAt: now.addingTimeInterval(3 * 3600)),
            ], fetchedAt: now),
        ]
    }
}
