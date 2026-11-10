import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    /// Antigravity / agy quota (Gemini Pro, Gemini Flash, Claude + GPT), via Google sign-in.
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// Gemini signs in with Google OAuth instead of the in-app browser.
    public var usesGoogleOAuth: Bool { self == .gemini }

    /// Page the in-app browser opens so you can sign in.
    public var loginURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/login")!
        case .codex: URL(string: "https://chatgpt.com/auth/login")!
        case .gemini: URL(string: "https://accounts.google.com")!
        }
    }

    /// Cookie domain whose cookies are kept after signing in.
    public var cookieDomain: String {
        switch self {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        case .gemini: "accounts.google.com"
        }
    }

    /// Returns true once the cookie that proves you're signed in is present.
    public func isSignedIn(cookieNames: [String]) -> Bool {
        switch self {
        case .claude: cookieNames.contains("sessionKey")
        case .codex: cookieNames.contains { $0.hasPrefix("__Secure-next-auth.session-token") }
        case .gemini: false
        }
    }
}

public struct LimitWindow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    /// 0–100
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ProviderSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var provider: Provider
    public var plan: String?
    public var windows: [LimitWindow]
    public var error: String?
    public var hint: String?
    public var fetchedAt: Date
    /// True when showing cached numbers because the latest refresh failed.
    public var stale: Bool

    public var id: Provider { provider }
    public var ok: Bool { error == nil }

    public init(provider: Provider, plan: String? = nil, windows: [LimitWindow] = [], error: String? = nil,
                hint: String? = nil, fetchedAt: Date = Date(), stale: Bool = false) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.error = error
        self.hint = hint
        self.fetchedAt = fetchedAt
        self.stale = stale
    }

    /// The fullest window. Used for compact lock-screen widgets.
    public var worst: LimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

/// What the app saved after you signed in. Either a cookie header from the
/// in-app browser, or a token you pasted.
public struct Credential: Codable, Hashable, Sendable {
    public var cookieHeader: String?
    public var bearerToken: String?
    public var userAgent: String?
    public var savedAt: Date
    // Google OAuth (Gemini)
    public var refreshToken: String?
    public var accessExpiry: Date?
    public var projectId: String?
    public var plan: String?
    public var email: String?

    public init(cookieHeader: String? = nil, bearerToken: String? = nil, userAgent: String? = nil, savedAt: Date = Date(),
                refreshToken: String? = nil, accessExpiry: Date? = nil, projectId: String? = nil,
                plan: String? = nil, email: String? = nil) {
        self.cookieHeader = cookieHeader
        self.bearerToken = bearerToken
        self.userAgent = userAgent
        self.savedAt = savedAt
        self.refreshToken = refreshToken
        self.accessExpiry = accessExpiry
        self.projectId = projectId
        self.plan = plan
        self.email = email
    }

    /// Accepts anything a user might paste: a bare cookie value, a full
    /// `Cookie:` header, or an access token (JWT).
    public static func fromPasted(_ raw: String, for provider: Provider) -> Credential? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.lowercased().hasPrefix("cookie:") { v = String(v.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !v.isEmpty else { return nil }
        switch provider {
        case .claude:
            if v.contains("sessionKey=") { return Credential(cookieHeader: v) }
            if v.hasPrefix("sk-ant-sid") { return Credential(cookieHeader: "sessionKey=\(v)") }
            return nil
        case .codex:
            if v.contains("next-auth.session-token") { return Credential(cookieHeader: v) }
            let parts = v.split(separator: ".", omittingEmptySubsequences: false).count
            if parts == 3, v.hasPrefix("eyJ") { return Credential(bearerToken: v) }
            if parts == 5 { return Credential(cookieHeader: "__Secure-next-auth.session-token=\(v)") }
            return nil
        case .gemini:
            return nil
        }
    }
}

public struct LimitError: Error, Equatable, Sendable {
    public var message: String
    public var hint: String?
    /// Auth problems are shown as-is; anything else falls back to cached numbers.
    public var isAuth: Bool

    public init(_ message: String, hint: String? = nil, isAuth: Bool = false) {
        self.message = message
        self.hint = hint
        self.isAuth = isAuth
    }

    public static let notSignedIn = LimitError("Not signed in", hint: "Open Limitty and sign in.", isAuth: true)
    public static let expired = LimitError("Login expired", hint: "Open Limitty and sign in again.", isAuth: true)
}
