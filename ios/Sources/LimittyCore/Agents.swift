import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// Agent status relayed from the Limitty companion on your PC (src/agents/).
// The PC publishes encrypted status to an ntfy topic; the phone fetches the
// latest message and decrypts it with the key from pairing.

public struct AgentPairing: Codable, Hashable, Sendable {
    public var server: String
    public var topic: String
    public var key: String

    public init(server: String, topic: String, key: String) {
        self.server = server
        self.topic = topic
        self.key = key
    }

    public var alertsTopic: String { "\(topic)-alerts" }

    /// Accepts the `limitty://pair?s=…&t=…&k=…` link (or just its query string).
    public static func parse(_ text: String) -> AgentPairing? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.lowercased().hasPrefix("limitty:") { raw = "limitty://pair?" + raw.drop { $0 == "?" } }
        guard let c = URLComponents(string: raw) else { return nil }
        let q = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        guard let topic = q("t"), let key = q("k"), !topic.isEmpty,
              topic.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              Data(base64URL: key)?.count == 32
        else { return nil }
        let server = (q("s") ?? "https://ntfy.sh").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard server.hasPrefix("https://") || server.hasPrefix("http://") else { return nil }
        return AgentPairing(server: server, topic: topic, key: key)
    }
}

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
    /// Where push alerts go (sent by the PC in GitHub mode).
    public var alertsTopic: String?
    public var ntfyServer: String?

    public init(v: Int = 1, host: String, sentAt: Double, sessions: [AgentSession], alertsTopic: String? = nil, ntfyServer: String? = nil) {
        self.v = v
        self.host = host
        self.sentAt = sentAt
        self.sessions = sessions
        self.alertsTopic = alertsTopic
        self.ntfyServer = ntfyServer
    }

    enum CodingKeys: String, CodingKey { case v, host, sentAt, sessions, alertsTopic, ntfyServer }

    // Lenient: the Gist starts as {"v":1,"sessions":[]} before the PC first writes to it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        sentAt = try c.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0
        sessions = try c.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
        alertsTopic = try c.decodeIfPresent(String.self, forKey: .alertsTopic)
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer)
    }

    public var sentDate: Date { Date(timeIntervalSince1970: sentAt) }

    /// The PC sends a heartbeat every 30 minutes; older than ~40 means it's off or asleep.
    public func pcOnline(now: Date = Date()) -> Bool { now.timeIntervalSince(sentDate) < 40 * 60 }

    public func count(_ state: AgentState) -> Int { sessions.filter { $0.state == state }.count }

    /// "1 needs you · 2 working", or "All idle".
    public var summary: String {
        let parts = [(AgentState.attention, "needs you"), (.waiting, "maybe waiting"), (.working, "working")]
            .compactMap { s, label in count(s) > 0 ? "\(count(s)) \(label)" : nil }
        if parts.isEmpty { return sessions.isEmpty ? "No agents running" : "All idle" }
        return parts.joined(separator: " · ")
    }
}

public enum AgentCrypto {
    public struct Unsupported: Error {}

    /// AES-256-GCM, base64 of nonce | ciphertext | tag (CryptoKit's "combined" layout).
    public static func open(_ base64: String, key: String) throws -> Data {
        #if canImport(CryptoKit)
        guard let data = Data(base64Encoded: base64), let keyData = Data(base64URL: key) else { throw LimitError("Bad status message") }
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        #else
        throw Unsupported()
        #endif
    }
}

public struct AgentFeed: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Latest status from the PC, or nil if it hasn't sent anything in the last 12 hours.
    public func fetch(_ p: AgentPairing) async throws -> AgentStatus? {
        let url = URL(string: "\(p.server)/\(p.topic)/json?poll=1&since=latest")!
        let res = try await http.get(url, headers: ["Accept": "application/x-ndjson"])
        try check(res.status, site: "ntfy")
        guard let message = Self.latestMessage(res.body) else { return nil }
        do {
            let plain = try AgentCrypto.open(message, key: p.key)
            return try JSONDecoder().decode(AgentStatus.self, from: plain)
        } catch is AgentCrypto.Unsupported {
            throw LimitError("Decryption isn't available on this platform")
        } catch {
            throw LimitError("Couldn't read your PC's status", hint: "Pair again with the link from `npm run agent:setup`.")
        }
    }

    /// ntfy returns one JSON object per line; take the newest `message` event.
    static func latestMessage(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { JSON.object(Data($0.utf8)) as? [String: Any] }
            .filter { $0["event"] as? String == "message" }
            .last?["message"] as? String
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}

// MARK: storage

extension SharedStore {
    private var pairingURL: URL { directory.appendingPathComponent("pairing.json") }
    private var agentStatusURL: URL { directory.appendingPathComponent("agents.json") }

    public func agentPairing() -> AgentPairing? {
        (try? Data(contentsOf: pairingURL)).flatMap { try? JSONDecoder().decode(AgentPairing.self, from: $0) }
    }

    public func setAgentPairing(_ p: AgentPairing?) {
        if let p, let data = try? JSONEncoder().encode(p) {
            writeProtected(data, to: pairingURL)
        } else {
            try? FileManager.default.removeItem(at: pairingURL)
            try? FileManager.default.removeItem(at: agentStatusURL)
        }
    }

    public func cachedAgentStatus() -> AgentStatus? {
        (try? Data(contentsOf: agentStatusURL)).flatMap { try? JSONDecoder().decode(AgentStatus.self, from: $0) }
    }

    public func saveAgentStatus(_ s: AgentStatus) {
        if let data = try? JSONEncoder().encode(s) { writeProtected(data, to: agentStatusURL) }
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
