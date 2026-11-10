import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Notifications when an agent needs your permission or is done, with a
// different sound for each.
//
//  - In Limitty itself: local notifications with Limitty's own sounds, while the
//    app is open or refreshing in the background.
//  - Instantly, even when Limitty is closed: through Bark, a free push app. The
//    phone saves the Bark key and your sounds to limitty-phone.json in your
//    private Gist; the PC reads them and sends each alert straight to Bark.
//    (Limitty can't receive pushes itself without a paid Apple developer account.)

public enum AlertKind: String, Codable, Sendable { case attention, done }

public struct PhoneSettings: Codable, Hashable, Sendable {
    public struct Bark: Codable, Hashable, Sendable {
        public var server: String
        public var key: String
        public init(server: String = "https://api.day.app", key: String) {
            self.server = server
            self.key = key
        }
    }
    public struct Sounds: Codable, Hashable, Sendable {
        public var attention: String
        public var done: String
        public init(attention: String, done: String) {
            self.attention = attention
            self.done = done
        }
    }
    public struct Notify: Codable, Hashable, Sendable {
        public var enabled = true
        /// Alert when an agent finishes (permission alerts are always on while enabled).
        public var finished = true
        /// Alert when a Company task is done or fails.
        public var tasks = true
        public var bark: Bark?
        /// Bark's sound names (used by the PC when it sends through Bark).
        public var sounds = Sounds(attention: BarkSound.defaultAttention, done: BarkSound.defaultDone)
        /// Limitty's own sounds (local notifications).
        public var localSounds = Sounds(attention: LocalSound.alert.rawValue, done: LocalSound.chime.rawValue)
        public init() {}

        enum CodingKeys: String, CodingKey { case enabled, finished, tasks, bark, sounds, localSounds }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
            tasks = try c.decodeIfPresent(Bool.self, forKey: .tasks) ?? true
            bark = try c.decodeIfPresent(Bark.self, forKey: .bark)
            sounds = try c.decodeIfPresent(Sounds.self, forKey: .sounds) ?? sounds
            localSounds = try c.decodeIfPresent(Sounds.self, forKey: .localSounds) ?? localSounds
        }
    }

    public var v = 1
    public var notify = Notify()
    public var updatedAt: Double = 0
    public init() {}

    public func wants(_ kind: AlertKind, task: Bool = false) -> Bool {
        guard notify.enabled else { return false }
        if task { return notify.tasks }
        return kind == .attention || notify.finished
    }
}

/// Bark's built-in sounds (github.com/Finb/Bark/tree/master/Sounds).
public enum BarkSound {
    public static let all = ["alarm", "anticipate", "bell", "birdsong", "bloom", "calypso", "chime", "choo", "descent",
                             "electronic", "fanfare", "glass", "gotosleep", "healthnotification", "horn", "ladder", "mailsent",
                             "minuet", "multiwayinvitation", "newmail", "newsflash", "noir", "paymentsuccess", "shake",
                             "sherwoodforest", "spell", "suspense", "telegraph", "tiptoes", "typewriters", "update"]
    public static let defaultAttention = "alarm"
    public static let defaultDone = "glass"

    public static func label(_ name: String) -> String {
        switch name {
        case "healthnotification": "Health notification"
        case "multiwayinvitation": "Multiway invitation"
        case "newmail": "New mail"
        case "mailsent": "Mail sent"
        case "newsflash": "News flash"
        case "paymentsuccess": "Payment success"
        case "sherwoodforest": "Sherwood forest"
        case "gotosleep": "Go to sleep"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

public enum BarkLink {
    /// Accepts what Bark's copy button gives (`https://api.day.app/KEY/…`) or a bare key.
    public static func parse(_ text: String) -> PhoneSettings.Bark? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isKey = { (s: String) in s.range(of: #"^[A-Za-z0-9_-]{8,64}$"#, options: .regularExpression) != nil }
        if isKey(raw) { return .init(key: raw) }
        // Find the first URL in the text (Bark's example lines include extra words).
        guard let range = raw.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression),
              let c = URLComponents(string: String(raw[range])), let host = c.host, !host.isEmpty
        else { return nil }
        guard let key = c.path.split(separator: "/").first.map(String.init), isKey(key) else { return nil }
        let port = c.port.map { ":\($0)" } ?? ""
        return .init(server: "https://\(host)\(port)", key: key)
    }

    /// Sends a push straight from the phone (used for the test button).
    public static func send(_ bark: PhoneSettings.Bark, title: String, body: String, sound: String, kind: AlertKind,
                            http: HTTPClient = URLSessionHTTPClient()) async throws {
        let payload: [String: Any] = [
            "device_key": bark.key, "title": title, "body": body, "sound": sound,
            "level": kind == .attention ? "timeSensitive" : "active",
            "group": kind == .attention ? "Limitty · needs you" : "Limitty · done",
            "url": "limitty://agents",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let res = try await http.post(URL(string: "\(bark.server)/push")!, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
        try check(res.status, site: "Bark")
    }
}

// MARK: - When to alert

public struct AgentAlert: Equatable, Sendable {
    public var kind: AlertKind
    public var title: String
    public var body: String
    /// Same id → iOS replaces the older notification.
    public var id: String
    public var isTask: Bool
}

public enum AlertDetector {
    /// What changed since the last status: new "needs you" states and agents that just finished.
    /// Nothing on the first load (`old == nil`), so opening the app doesn't replay old states.
    public static func alerts(from old: AgentStatus?, to new: AgentStatus) -> [AgentAlert] {
        guard let old else { return [] }
        let before = Dictionary(old.sessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [AgentAlert] = []
        for s in new.sessions {
            let prev = before[s.key]
            let where_ = s.project.isEmpty ? "" : " · \(s.project)"
            if s.state == .attention, prev?.state != .attention || prev?.detail != s.detail {
                out.append(AgentAlert(kind: .attention, title: "\(s.name) needs you\(where_)",
                                      body: s.detail.isEmpty ? "It's waiting for your permission or an answer." : s.detail,
                                      id: "agent-\(s.key)", isTask: false))
            } else if s.state == .idle, s.detail == "Finished", let prev, prev.state != .idle {
                out.append(AgentAlert(kind: .done, title: "\(s.name) finished\(where_)", body: "Waiting for your next prompt.",
                                      id: "agent-\(s.key)", isTask: false))
            }
        }
        return out
    }

    /// Company tasks that just finished or failed.
    public static func alerts(from old: CompanyState?, to new: CompanyState) -> [AgentAlert] {
        guard let old else { return [] }
        let before = Dictionary(old.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        return new.tasks.compactMap { t in
            guard let prev = before[t.id], prev != t.status else { return nil }
            switch t.status {
            case "done": return AgentAlert(kind: .done, title: "Task done · \(t.project)", body: t.title, id: "task-\(t.id)", isTask: true)
            case "failed": return AgentAlert(kind: .attention, title: "Task failed · \(t.project)", body: t.error ?? t.title, id: "task-\(t.id)", isTask: true)
            default: return nil
            }
        }
    }
}

// MARK: - Limitty's own sounds

/// Notification sounds made in code (no sound files to ship), written as WAV
/// files to Library/Sounds, where iOS looks for custom notification sounds.
public enum LocalSound: String, CaseIterable, Codable, Sendable {
    case alert, knock, ping, chime, success, system

    public var label: String {
        switch self {
        case .alert: "Alert (urgent beeps)"
        case .knock: "Knock knock"
        case .ping: "Ping"
        case .chime: "Chime"
        case .success: "Success"
        case .system: "iPhone default"
        }
    }

    public var fileName: String { "limitty-\(rawValue).wav" }

    /// (frequency Hz, start s, length s, volume) notes.
    var notes: [(Double, Double, Double, Double)] {
        switch self {
        case .alert: [(1318.5, 0, 0.12, 0.8), (1760, 0.15, 0.12, 0.8), (1318.5, 0.45, 0.12, 0.8), (1760, 0.6, 0.12, 0.8)]
        case .knock: [(196, 0, 0.09, 1), (196, 0.16, 0.09, 1), (233, 0.55, 0.09, 1), (233, 0.71, 0.09, 1)]
        case .ping: [(1567.98, 0, 0.9, 0.7)]
        case .chime: [(1046.5, 0, 0.9, 0.55), (783.99, 0.18, 0.9, 0.55), (659.25, 0.36, 1.1, 0.55)]
        case .success: [(523.25, 0, 0.5, 0.5), (659.25, 0.12, 0.5, 0.5), (783.99, 0.24, 0.5, 0.5), (1046.5, 0.36, 0.9, 0.55)]
        case .system: []
        }
    }

    /// 16-bit mono WAV.
    public func wav(sampleRate: Int = 22_050) -> Data {
        let notes = self.notes
        let length = (notes.map { $0.1 + $0.2 }.max() ?? 0) + 0.05
        let count = Int(length * Double(sampleRate))
        var samples = [Double](repeating: 0, count: count)
        let knock = self == .knock
        for (freq, start, dur, vol) in notes {
            let s0 = Int(start * Double(sampleRate))
            let n = Int(dur * Double(sampleRate))
            for i in 0..<n where s0 + i < count {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1, t / 0.005)
                let decay = knock ? exp(-t * 40) : exp(-t * (3.2 / dur))
                // A little second harmonic makes it sound like a bell rather than a beep.
                let wave = sin(2 * .pi * freq * t) + 0.3 * sin(4 * .pi * freq * t)
                samples[s0 + i] += wave * attack * decay * vol
            }
        }
        let peak = max(samples.map(abs).max() ?? 1, 1)
        var pcm = Data(capacity: count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s / peak * 0.9)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Writes every sound to `directory` (Library/Sounds) if it isn't there yet.
    public static func install(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for s in allCases where s != .system {
            let url = directory.appendingPathComponent(s.fileName)
            if !FileManager.default.fileExists(atPath: url.path) { try? s.wav().write(to: url) }
        }
    }
}

// MARK: - Saving

extension GitHubStatusFeed {
    public static let phoneFile = "limitty-phone.json"

    /// Saves your alert settings where the PC reads them.
    public func savePhoneSettings(_ settings: PhoneSettings, account: GitHubAccount) async throws {
        guard let id = account.gistId else { throw LimitError("Connect your PC first") }
        let content = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["files": [Self.phoneFile: ["content": content]]])
        var headers = self.headers(account.token)
        headers["Content-Type"] = "application/json"
        let res = try await http.send(HTTPRequest(method: "PATCH", url: URL(string: "https://api.github.com/gists/\(id)")!, headers: headers, body: body))
        try check(res.status, site: "GitHub")
    }
}

extension SharedStore {
    private var phoneURL: URL { directory.appendingPathComponent("phone-settings.json") }

    public func phoneSettings() -> PhoneSettings {
        (try? Data(contentsOf: phoneURL)).flatMap { try? JSONDecoder().decode(PhoneSettings.self, from: $0) } ?? PhoneSettings()
    }

    public func savePhoneSettings(_ s: PhoneSettings) {
        if let data = try? JSONEncoder().encode(s) { writeProtected(data, to: phoneURL) }
    }
}
