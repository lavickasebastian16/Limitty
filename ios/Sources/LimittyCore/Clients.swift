import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> (status: Int, body: Data)
}

public extension HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        try await send(HTTPRequest(url: url, headers: headers))
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        try await send(HTTPRequest(method: "POST", url: url, headers: headers, body: body))
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ r: HTTPRequest) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: r.url, timeoutInterval: 20)
        req.httpMethod = r.method
        req.httpBody = r.body
        req.httpShouldHandleCookies = false // we send the saved cookie header ourselves
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Mobile Safari user agent, used when no browser UA was saved at sign-in.
public let defaultUserAgent = safariUserAgent(iOSVersion: "18.0")

/// The exact user agent Safari sends on this iOS version. Sign-in pages (Google's
/// especially) are less likely to block the in-app browser when it matches.
public func safariUserAgent(iOSVersion: String) -> String {
    let parts = iOSVersion.split(separator: ".").map(String.init)
    let os = parts.joined(separator: "_")
    let short = parts.prefix(2).joined(separator: ".") + (parts.count == 1 ? ".0" : "")
    return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
}

func browserHeaders(_ c: Credential) -> [String: String] {
    var h = ["Accept": "application/json", "User-Agent": c.userAgent ?? defaultUserAgent]
    if let cookie = c.cookieHeader { h["Cookie"] = cookie }
    return h
}

public struct ClaudeClient: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    public func fetch(_ c: Credential) async throws -> (plan: String?, windows: [LimitWindow]) {
        guard c.cookieHeader != nil else { throw LimitError.notSignedIn }
        let headers = browserHeaders(c)

        let orgs = try await http.get(URL(string: "https://claude.ai/api/organizations")!, headers: headers)
        try check(orgs.status, site: "claude.ai")
        guard let org = ClaudeParser.org(from: orgs.body) else { throw LimitError("No Claude account found") }

        let usage = try await http.get(URL(string: "https://claude.ai/api/organizations/\(org.uuid)/usage")!, headers: headers)
        try check(usage.status, site: "claude.ai")
        let windows = ClaudeParser.windows(from: usage.body)
        guard !windows.isEmpty else { throw LimitError("No usage data from claude.ai") }
        return (org.plan, windows)
    }
}

public struct CodexClient: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    func accessToken(_ c: Credential) async throws -> String {
        if let token = c.bearerToken { return token }
        guard c.cookieHeader != nil else { throw LimitError.notSignedIn }
        let res = try await http.get(URL(string: "https://chatgpt.com/api/auth/session")!, headers: browserHeaders(c))
        try check(res.status, site: "chatgpt.com")
        guard let token = CodexParser.accessToken(fromSession: res.body) else { throw LimitError.expired }
        return token
    }

    public func fetch(_ c: Credential, now: Date = Date()) async throws -> (plan: String?, windows: [LimitWindow]) {
        let token = try await accessToken(c)
        if let exp = JWT.expiry(token), exp < now {
            throw LimitError("Token expired", hint: "Open Limitty and sign in again.", isAuth: true)
        }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "codex-cli"]
        if let account = JWT.chatGPTAccountID(token) { headers["ChatGPT-Account-Id"] = account }

        let res = try await http.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        try check(res.status, site: "chatgpt.com")
        let parsed = CodexParser.snapshot(from: res.body, now: now)
        guard !parsed.windows.isEmpty else { throw LimitError("No usage data from chatgpt.com") }
        return parsed
    }
}

func check(_ status: Int, site: String) throws {
    switch status {
    case 200..<300: return
    case 401: throw LimitError.expired
    case 403: throw LimitError("\(site) refused the request", hint: "Sign in again in Limitty. If it keeps happening, \(site) may be blocking app requests.", isAuth: true)
    case 429: throw LimitError("Rate limited by \(site)", hint: "It will retry on the next refresh.")
    default: throw LimitError("\(site) returned HTTP \(status)")
    }
}
