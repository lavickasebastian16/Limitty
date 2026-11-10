import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Antigravity (agy) quota for Gemini Pro, Gemini Flash and Claude + GPT.
//
// There's no public API for this. Like CodexBar and other community tools, we
// sign in with Google using Antigravity's own OAuth client (an "installed app"
// client, whose ID and secret ship inside Antigravity and are not confidential),
// then ask Google's Cloud Code service the same question Antigravity asks.
// This impersonates Antigravity, which Google's terms don't allow; a spare
// Google account is safest.

public enum GoogleOAuth {
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    public static let port: UInt16 = 51121
    public static let callbackPath = "/oauth-callback"
    public static var redirectURI: String { "http://localhost:\(port)\(callbackPath)" }
    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    /// Google's sign-in page. `codeChallenge` is the base64url SHA-256 of the PKCE verifier.
    public static func authorizationURL(codeChallenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// Pulls the authorization code out of the `http://localhost:51121/oauth-callback?...` URL.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let err = value("error") { throw LimitError("Google sign-in failed: \(err)", isAuth: true) }
        guard value("state") == expectedState else { throw LimitError("Google sign-in didn't match. Try again.", isAuth: true) }
        guard let code = value("code"), !code.isEmpty else { throw LimitError("No sign-in code from Google", isAuth: true) }
        return code
    }

    /// Swaps the authorization code for tokens.
    public static func exchange(code: String, verifier: String, http: HTTPClient = URLSessionHTTPClient(), now: Date = Date()) async throws -> Credential {
        let res = try await http.post(URL(string: "https://oauth2.googleapis.com/token")!,
                                      headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                      body: form([
                                          "client_id": clientID, "client_secret": clientSecret, "code": code,
                                          "grant_type": "authorization_code", "redirect_uri": redirectURI, "code_verifier": verifier,
                                      ]))
        guard res.status == 200, let obj = JSON.object(res.body) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String
        else { throw LimitError("Google sign-in failed (HTTP \(res.status))", isAuth: true) }
        var cred = Credential(bearerToken: access, refreshToken: refresh,
                              accessExpiry: now.addingTimeInterval(JSON.number(obj["expires_in"]) ?? 3600))
        if let info = try? await http.get(URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!,
                                          headers: ["Authorization": "Bearer \(access)"]),
           let email = (JSON.object(info.body) as? [String: Any])?["email"] as? String {
            cred.email = email
        }
        return cred
    }

    /// Gets a new access token with the saved refresh token (Google doesn't rotate it).
    static func refresh(_ c: Credential, http: HTTPClient, now: Date) async throws -> Credential {
        guard let refresh = c.refreshToken else { throw LimitError.notSignedIn }
        let res = try await http.post(URL(string: "https://oauth2.googleapis.com/token")!,
                                      headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                      body: form([
                                          "client_id": clientID, "client_secret": clientSecret,
                                          "grant_type": "refresh_token", "refresh_token": refresh,
                                      ]))
        let obj = JSON.object(res.body) as? [String: Any]
        if res.status == 400 || res.status == 401 { throw LimitError.expired } // invalid_grant: access revoked
        guard res.status == 200, let access = obj?["access_token"] as? String else {
            throw LimitError("Google returned HTTP \(res.status)")
        }
        var out = c
        out.bearerToken = access
        out.accessExpiry = now.addingTimeInterval(JSON.number(obj?["expires_in"]) ?? 3600)
        return out
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

public enum GeminiParser {
    static let order = ["gemini_pro", "gemini_flash", "claude_gpt"]
    static let labels = ["gemini_pro": "Gemini Pro", "gemini_flash": "Gemini Flash", "claude_gpt": "Claude + GPT"]

    static func group(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("claude") || n.contains("gpt") { return "claude_gpt" }
        guard n.contains("gemini") else { return nil }
        return n.contains("flash") ? "gemini_flash" : "gemini_pro"
    }

    /// Parses `fetchAvailableModels`. Models sharing a quota are grouped, and
    /// each group shows its most-used model.
    public static func windows(from data: Data) -> [LimitWindow] {
        guard let obj = JSON.object(data) as? [String: Any], let models = obj["models"] as? [String: Any] else { return [] }

        // Only count models Antigravity actually offers in its picker, when it says which.
        var selectable = Set<String>()
        for sort in obj["agentModelSorts"] as? [[String: Any]] ?? [] {
            for g in sort["groups"] as? [[String: Any]] ?? [] {
                selectable.formUnion(g["modelIds"] as? [String] ?? [])
            }
        }
        for ids in (obj["tieredModelIds"] as? [String: [String]] ?? [:]).values { selectable.formUnion(ids) }

        var best: [String: LimitWindow] = [:]
        for (name, any) in models {
            guard let entry = any as? [String: Any], let quota = entry["quotaInfo"] as? [String: Any] else { continue }
            if entry["disabled"] as? Bool == true { continue }
            if !selectable.isEmpty && !selectable.contains(name) { continue }
            let display = (entry["displayName"] as? String) ?? (entry["modelName"] as? String) ?? ""
            guard let key = group("\(name) \(display)") else { continue }
            // A missing fraction means none left.
            let remaining = min(1, max(0, JSON.number(quota["remainingFraction"]) ?? 0))
            let w = LimitWindow(id: key, label: labels[key]!, usedPercent: (1 - remaining) * 100, resetsAt: JSON.date(quota["resetTime"]))
            if let cur = best[key], cur.usedPercent >= w.usedPercent { continue }
            best[key] = w
        }
        return order.compactMap { best[$0] }
    }

    /// From `loadCodeAssist`: the Cloud Code project and the plan name.
    public static func project(from data: Data) -> (id: String?, plan: String?) {
        guard let obj = JSON.object(data) as? [String: Any] else { return (nil, nil) }
        let project = obj["cloudaicompanionProject"]
        let id = (project as? String) ?? ((project as? [String: Any])?["id"] as? String)
        let tier = (obj["paidTier"] as? [String: Any]) ?? (obj["currentTier"] as? [String: Any])
        return (id?.isEmpty == false ? id : nil, tier?["name"] as? String)
    }
}

public struct GeminiClient: Sendable {
    static let base = "https://daily-cloudcode-pa.googleapis.com"
    static let userAgent = "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64)"
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Returns the limits and, when tokens or project info changed, the credential to save.
    public func fetch(_ c: Credential, now: Date = Date()) async throws -> (plan: String?, windows: [LimitWindow], updated: Credential?) {
        guard c.refreshToken != nil else { throw LimitError.notSignedIn }
        var cred = c
        var changed = false

        if cred.bearerToken == nil || (cred.accessExpiry ?? .distantPast) < now.addingTimeInterval(60) {
            cred = try await GoogleOAuth.refresh(cred, http: http, now: now)
            changed = true
        }

        if cred.projectId == nil {
            let res = try await post("loadCodeAssist", ["metadata": ["ideType": "ANTIGRAVITY"]], token: cred.bearerToken!)
            if res.status == 200 {
                let p = GeminiParser.project(from: res.body)
                cred.projectId = p.id
                cred.plan = p.plan
                changed = true
            }
        }

        let body: [String: Any] = cred.projectId.map { ["project": $0] } ?? [:]
        var res = try await post("fetchAvailableModels", body, token: cred.bearerToken!)
        if res.status == 401 {
            cred = try await GoogleOAuth.refresh(cred, http: http, now: now)
            changed = true
            res = try await post("fetchAvailableModels", body, token: cred.bearerToken!)
        }
        try check(res.status, site: "Google")
        let windows = GeminiParser.windows(from: res.body)
        guard !windows.isEmpty else { throw LimitError("No Gemini quota found", hint: "Is this Google account signed up for Antigravity?") }
        return (cred.plan, windows, changed ? cred : nil)
    }

    private func post(_ method: String, _ body: [String: Any], token: String) async throws -> (status: Int, body: Data) {
        try await http.post(URL(string: "\(Self.base)/v1internal:\(method)")!,
                            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "User-Agent": Self.userAgent],
                            body: try JSONSerialization.data(withJSONObject: body))
    }
}
