import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Company mode: tasks you give from the phone go to your PC's CEO, which hands
// them to Claude Code, Codex or Antigravity. Synced through the same private
// Gist as agent status: the PC writes limitty-tasks.json, the phone appends
// requests to limitty-inbox.json.

public struct CompanyState: Codable, Hashable, Sendable {
    public struct Project: Codable, Hashable, Sendable { public var name: String }
    public struct Model: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var tier: String?
        public var remaining: Double?
    }
    public struct Worker: Codable, Hashable, Sendable {
        public var name: String
        public var strengths: String?
        public var available: Bool
        public var busy: Bool
        public var remaining: Double?
        public var models: [Model]?
    }

    public var projects: [Project]
    public var workers: [String: Worker]
    public var tasks: [CompanyTask]
    /// Which agent is the CEO.
    public var ceo: String?

    public init(projects: [Project] = [], workers: [String: Worker] = [:], tasks: [CompanyTask] = []) {
        self.projects = projects
        self.workers = workers
        self.tasks = tasks
    }

    public static let workerOrder = ["claude", "codex", "agy"]
}

public struct CompanyTask: Codable, Hashable, Identifiable, Sendable {
    public struct Step: Codable, Hashable, Sendable {
        public var worker: String
        public var model: String?
        public var modelLabel: String?
        public var title: String
        /// Which of the worker's strengths the CEO matched to this step.
        public var why: String?
        public var status: String
        public var output: String?
        public var startedAt: Double?
        public var finishedAt: Double?
    }
    public struct Plan: Codable, Hashable, Sendable {
        public var summary: String
        public var by: String?
        public var steps: [Step]
    }

    public var id: String
    public var title: String
    public var project: String
    public var worker: String
    public var source: String?
    public var status: String
    public var error: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var plan: Plan?

    public var isActive: Bool { ["queued", "planning", "running"].contains(status) }

    /// The answer: the last step's output once the task is done (or the failed step's).
    public var result: String? {
        let steps = plan?.steps ?? []
        let want = status == "done" ? "done" : status == "failed" ? "failed" : nil
        guard let want else { return nil }
        return steps.last { $0.status == want && !($0.output ?? "").isEmpty }?.output
    }

    public var statusLabel: String {
        switch status {
        case "queued": "Waiting"
        case "planning": "CEO is planning"
        case "running": "Working"
        case "done": "Done"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        default: status.capitalized
        }
    }
}

public func workerName(_ id: String) -> String {
    switch id {
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "agy": "Antigravity"
    case "you": "you"
    case "rules": "rules"
    default: id
    }
}

public struct CompanyRequest: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String // create | cancel | retry | remove
    public var title: String?
    public var project: String?
    public var worker: String?
    public var task: String?
    public var at: Double

    public static func create(title: String, project: String, worker: String) -> CompanyRequest {
        CompanyRequest(id: UUID().uuidString, kind: "create", title: title, project: project, worker: worker, task: nil, at: Date().timeIntervalSince1970)
    }

    public static func action(_ kind: String, task: String) -> CompanyRequest {
        CompanyRequest(id: UUID().uuidString, kind: kind, title: nil, project: nil, worker: nil, task: task, at: Date().timeIntervalSince1970)
    }
}

struct CompanyInbox: Codable { var requests: [CompanyRequest] }

extension GitHubStatusFeed {
    public static let tasksFile = "limitty-tasks.json"
    public static let inboxFile = "limitty-inbox.json"

    /// Reads agent status and tasks in one request.
    public func fetchAll(_ account: GitHubAccount) async throws -> (status: AgentStatus?, company: CompanyState?) {
        guard let id = account.gistId else { return (nil, nil) }
        let files = try await readFiles(id, token: account.token)
        let status = files[Self.statusFile].flatMap { try? JSONDecoder().decode(AgentStatus.self, from: Data($0.utf8)) }
        let company = files[Self.tasksFile].flatMap { try? JSONDecoder().decode(CompanyState.self, from: Data($0.utf8)) }
        return (status?.sentAt == 0 ? nil : status, company)
    }

    /// Adds a request to the inbox your PC reads (keeps the last 50).
    public func send(_ request: CompanyRequest, account: GitHubAccount) async throws {
        guard let id = account.gistId else { throw LimitError("Connect your PC first") }
        let files = try await readFiles(id, token: account.token)
        var inbox = files[Self.inboxFile].flatMap { try? JSONDecoder().decode(CompanyInbox.self, from: Data($0.utf8)) } ?? CompanyInbox(requests: [])
        inbox.requests = Array((inbox.requests + [request]).suffix(50))
        let content = String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["files": [Self.inboxFile: ["content": content]]])
        var headers = self.headers(account.token)
        headers["Content-Type"] = "application/json"
        let res = try await http.send(HTTPRequest(method: "PATCH", url: URL(string: "https://api.github.com/gists/\(id)")!, headers: headers, body: body))
        try check(res.status, site: "GitHub")
    }

    func readFiles(_ id: String, token: String) async throws -> [String: String] {
        let res = try await http.get(URL(string: "https://api.github.com/gists/\(id)")!, headers: headers(token))
        if res.status == 404 { throw LimitError("Your PC's status Gist was deleted", hint: "Connect again on your PC.") }
        try check(res.status, site: "GitHub")
        let files = (JSON.object(res.body) as? [String: Any])?["files"] as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for (name, any) in files {
            if let content = (any as? [String: Any])?["content"] as? String { out[name] = content }
        }
        return out
    }
}

extension SharedStore {
    private var companyURL: URL { directory.appendingPathComponent("company.json") }

    public func cachedCompany() -> CompanyState? {
        (try? Data(contentsOf: companyURL)).flatMap { try? JSONDecoder().decode(CompanyState.self, from: $0) }
    }

    public func saveCompany(_ c: CompanyState?) {
        if let c, let data = try? JSONEncoder().encode(c) { writeProtected(data, to: companyURL) }
        else { try? FileManager.default.removeItem(at: companyURL) }
    }
}
