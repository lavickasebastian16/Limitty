import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Agent status from the Limitty companion on your PC (src/agents/). The PC writes
// it to limitty-status.json in your private GitHub Gist; see GitHubSync.swift.

public enum AgentState: String, Codable, Sendable {
    case working, attention, waiting, idle

    public var label: String {
        switch self {
        case .working: "Working"
        case .attention: "Needs you"
        case .waiting: "Maybe waiting"
        case .idle: "Idle"
        }
    }
}

public struct AgentSession: Codable, Hashable, Identifiable, Sendable {
    public var agent: String
    public var name: String
    public var id: String
    public var project: String
    public var state: AgentState
    public var detail: String
    /// Unix seconds when it entered this state.
    public var since: Double

    public var key: String { "\(agent):\(id)" }
    public var sinceDate: Date { Date(timeIntervalSince1970: since) }
}

public struct AgentStatus: Codable, Hashable, Sendable {
    public var v: Int
    public var host: String
    public var sentAt: Double
    public var sessions: [AgentSession]

    public init(v: Int = 1, host: String, sentAt: Double, sessions: [AgentSession]) {
        self.v = v
        self.host = host
        self.sentAt = sentAt
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey { case v, host, sentAt, sessions }

    // Lenient: the Gist starts as {"v":1,"sessions":[]} before the PC first writes to it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        sentAt = try c.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0
        sessions = try c.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
    }

    public var sentDate: Date { Date(timeIntervalSince1970: sentAt) }

    /// The PC sends a heartbeat every 10 minutes; older than 25 means it's off or asleep.
    public func pcOnline(now: Date = Date()) -> Bool { now.timeIntervalSince(sentDate) < 25 * 60 }

    public func count(_ state: AgentState) -> Int { sessions.filter { $0.state == state }.count }

    /// "1 needs you · 2 working", or "All idle".
    public var summary: String {
        let parts = [(AgentState.attention, "needs you"), (.waiting, "maybe waiting"), (.working, "working")]
            .compactMap { s, label in count(s) > 0 ? "\(count(s)) \(label)" : nil }
        if parts.isEmpty { return sessions.isEmpty ? "No agents running" : "All idle" }
        return parts.joined(separator: " · ")
    }
}

// MARK: storage

extension SharedStore {
    private var agentStatusURL: URL { directory.appendingPathComponent("agents.json") }

    public func cachedAgentStatus() -> AgentStatus? {
        (try? Data(contentsOf: agentStatusURL)).flatMap { try? JSONDecoder().decode(AgentStatus.self, from: $0) }
    }

    public func saveAgentStatus(_ s: AgentStatus?) {
        if let s, let data = try? JSONEncoder().encode(s) { writeProtected(data, to: agentStatusURL) }
        else { try? FileManager.default.removeItem(at: agentStatusURL) }
    }

    func writeProtected(_ data: Data, to url: URL) {
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}

public enum AgentSample {
    public static func status(now: Date = Date()) -> AgentStatus {
        let t = now.timeIntervalSince1970
        return AgentStatus(v: 1, host: "my-pc", sentAt: t, sessions: [
            AgentSession(agent: "claude", name: "Claude Code", id: "a", project: "website", state: .attention,
                         detail: "Claude needs your permission to use Bash", since: t - 40),
            AgentSession(agent: "codex", name: "Codex", id: "b", project: "api", state: .working, detail: "Running a shell command", since: t - 300),
            AgentSession(agent: "agy", name: "Antigravity", id: "c", project: "app", state: .idle, detail: "Finished", since: t - 900),
        ])
    }
}
