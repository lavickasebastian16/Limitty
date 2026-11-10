import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// "Sign in with GitHub" linking. The PC writes agent status to a private Gist
// on your GitHub account (file limitty-status.json); the phone signs in to the
// same account and reads it. Sign-in uses GitHub's device flow: you enter a
// short code on github.com, and Limitty never sees your password.

public struct GitHubAccount: Codable, Hashable, Sendable {
    public var token: String
    public var login: String
    public var gistId: String?

    public init(token: String, login: String, gistId: String? = nil) {
        self.token = token
        self.login = login
        self.gistId = gistId
    }
}

public enum GitHubAuth {
    public static var clientID: String { limittyGitHubClientID }
    public static var isConfigured: Bool { !clientID.isEmpty }

    public struct DeviceCode: Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        public var interval: Double
        public var expiresAt: Date
    }

    public static func start(http: HTTPClient = URLSessionHTTPClient(), clientID: String = clientID, now: Date = Date()) async throws -> DeviceCode {
        guard !clientID.isEmpty else {
            throw LimitError("GitHub sign-in isn't set up in this build", hint: "See “Sign in with GitHub” in ios/README.md.")
        }
        let res = try await http.post(URL(string: "https://github.com/login/device/code")!,
                                      headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
                                      body: GoogleOAuth.form(["client_id": clientID, "scope": "gist"]))
        let obj = JSON.object(res.body) as? [String: Any] ?? [:]
        guard let device = obj["device_code"] as? String, let user = obj["user_code"] as? String,
              let uri = (obj["verification_uri"] as? String).flatMap(URL.init(string:))
        else {
            if obj["error"] as? String == "device_flow_disabled" {
                throw LimitError("Device Flow is off for the Limitty GitHub app", hint: "Tick “Enable Device Flow” in its GitHub settings.")
            }
            throw LimitError("GitHub sign-in failed (HTTP \(res.status))")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURL: uri,
                          interval: JSON.number(obj["interval"]) ?? 5,
                          expiresAt: now.addingTimeInterval(JSON.number(obj["expires_in"]) ?? 900))
    }

    /// Polls until you approve the code on github.com. Returns the access token.
    public static func waitForToken(_ code: DeviceCode, http: HTTPClient = URLSessionHTTPClient(), clientID: String = clientID,
                                    sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) async throws -> String {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await sleep(interval)
            let res = try await http.post(URL(string: "https://github.com/login/oauth/access_token")!,
                                          headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
                                          body: GoogleOAuth.form([
                                              "client_id": clientID, "device_code": code.deviceCode,
                                              "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                          ]))
            let obj = JSON.object(res.body) as? [String: Any] ?? [:]
            if let token = obj["access_token"] as? String { return token }
            switch obj["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw LimitError("Sign-in was cancelled on GitHub")
            case "expired_token": throw LimitError("The code expired. Try again.")
            default: throw LimitError("GitHub sign-in failed")
            }
        }
        throw LimitError("The code expired. Try again.")
    }
}

public struct GitHubStatusFeed: Sendable {
    public static let statusFile = "limitty-status.json"
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Limitty"]
    }

    public func login(token: String) async throws -> String {
        let res = try await http.get(URL(string: "https://api.github.com/user")!, headers: headers(token))
        try check(res.status, site: "GitHub")
        guard let login = (JSON.object(res.body) as? [String: Any])?["login"] as? String else { throw LimitError("GitHub sign-in failed") }
        return login
    }

    /// The Gist your PC writes to, if it has connected yet.
    public func findGist(token: String) async throws -> String? {
        for page in 1...10 {
            let res = try await http.get(URL(string: "https://api.github.com/gists?per_page=100&page=\(page)")!, headers: headers(token))
            try check(res.status, site: "GitHub")
            let gists = JSON.object(res.body) as? [[String: Any]] ?? []
            if let g = gists.first(where: { ($0["files"] as? [String: Any])?[Self.statusFile] != nil }) { return g["id"] as? String }
            if gists.count < 100 { break }
        }
        return nil
    }

    public func fetch(_ account: GitHubAccount) async throws -> AgentStatus? {
        guard let id = account.gistId else { return nil }
        let res = try await http.get(URL(string: "https://api.github.com/gists/\(id)")!, headers: headers(account.token))
        if res.status == 404 { throw LimitError("Your PC's status Gist was deleted", hint: "Connect again on your PC.") }
        try check(res.status, site: "GitHub")
        guard let files = (JSON.object(res.body) as? [String: Any])?["files"] as? [String: Any],
              let file = files[Self.statusFile] as? [String: Any],
              let content = file["content"] as? String
        else { return nil }
        let status = try? JSONDecoder().decode(AgentStatus.self, from: Data(content.utf8))
        return status?.sentAt == 0 ? nil : status // empty placeholder written at creation
    }
}

extension SharedStore {
    private var githubURL: URL { directory.appendingPathComponent("github.json") }

    public func githubAccount() -> GitHubAccount? {
        (try? Data(contentsOf: githubURL)).flatMap { try? JSONDecoder().decode(GitHubAccount.self, from: $0) }
    }

    public func setGitHubAccount(_ a: GitHubAccount?) {
        if let a, let data = try? JSONEncoder().encode(a) {
            writeProtected(data, to: githubURL)
        } else {
            try? FileManager.default.removeItem(at: githubURL)
        }
    }
}
