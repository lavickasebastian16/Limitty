import Foundation
import XCTest
@testable import LimittyCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var calls: [(url: String, headers: [String: String], body: String)] = []
    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    func send(_ r: HTTPRequest) async throws -> (status: Int, body: Data) {
        calls.append((r.url.absoluteString, r.headers, r.body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
        guard let (status, body) = routes[r.url.absoluteString] else { throw URLError(.notConnectedToInternet) }
        return (status, Data(body.utf8))
    }
}

func jwt(_ claims: [String: Any]) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "\(b64(Data("{\"alg\":\"none\"}".utf8))).\(b64(payload)).sig"
}

func tempStore() -> SharedStore {
    SharedStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("limitty-\(UUID().uuidString)"))
}

let claudeRoutes: [String: (Int, String)] = [
    "https://claude.ai/api/organizations": (200, #"[{"uuid":"api-org","capabilities":["api"]},{"uuid":"org-1","capabilities":["chat","claude_max"]}]"#),
    "https://claude.ai/api/organizations/org-1/usage": (200, #"""
    {"five_hour":{"utilization":42.0,"resets_at":"2026-11-10T15:00:00.123456+00:00"},
     "seven_day":{"utilization":88,"resets_at":null},"seven_day_opus":null,
     "seven_day_sonnet":{"utilization":5,"resets_at":"2026-11-14T00:00:00Z"}}
    """#),
]

final class ParsingTests: XCTestCase {
    func testClaudeUsage() throws {
        let w = ClaudeParser.windows(from: Data(claudeRoutes["https://claude.ai/api/organizations/org-1/usage"]!.1.utf8))
        XCTAssertEqual(w.map(\.label), ["Session", "Weekly", "Weekly · Sonnet"])
        XCTAssertEqual(w.map(\.usedPercent), [42, 88, 5])
        XCTAssertEqual(w[0].resetsAt!.timeIntervalSince1970, 1_794_322_800, accuracy: 1)
        XCTAssertNil(w[1].resetsAt)
    }

    func testClaudeOrgPrefersChat() {
        let org = ClaudeParser.org(from: Data(claudeRoutes["https://claude.ai/api/organizations"]!.1.utf8))
        XCTAssertEqual(org, .init(uuid: "org-1", plan: "Max"))
    }

    func testCodexUsage() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_after_seconds":600},"secondary_window":{"used_percent":61.5,"limit_window_seconds":604800,"reset_at":1893456000}}}"#
        let r = CodexParser.snapshot(from: Data(body.utf8), now: now)
        XCTAssertEqual(r.plan, "Plus")
        XCTAssertEqual(r.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(r.windows.map(\.usedPercent), [7, 61.5])
        XCTAssertEqual(r.windows[0].resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(r.windows[1].resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testPastedCredentials() {
        XCTAssertEqual(Credential.fromPasted("sk-ant-sid01-abc", for: .claude)?.cookieHeader, "sessionKey=sk-ant-sid01-abc")
        XCTAssertEqual(Credential.fromPasted("Cookie: a=1; sessionKey=x", for: .claude)?.cookieHeader, "a=1; sessionKey=x")
        XCTAssertNil(Credential.fromPasted("hello", for: .claude))
        XCTAssertEqual(Credential.fromPasted("eyJa.eyJb.c", for: .codex)?.bearerToken, "eyJa.eyJb.c")
        XCTAssertEqual(Credential.fromPasted("a.b.c.d.e", for: .codex)?.cookieHeader, "__Secure-next-auth.session-token=a.b.c.d.e")
        XCTAssertNotNil(Credential.fromPasted("__Secure-next-auth.session-token.0=x; __Secure-next-auth.session-token.1=y", for: .codex)?.cookieHeader)
    }

    func testSignedInCookieDetection() {
        XCTAssertTrue(Provider.claude.isSignedIn(cookieNames: ["cf_clearance", "sessionKey"]))
        XCTAssertFalse(Provider.claude.isSignedIn(cookieNames: ["cf_clearance"]))
        XCTAssertTrue(Provider.codex.isSignedIn(cookieNames: ["__Secure-next-auth.session-token.0"]))
    }

    func testGroupCandidates() {
        XCTAssertEqual(SharedStore.groupCandidates(bundleID: "XTL-AB12CD.com.limitty.app.LimittyWidget"),
                       ["group.XTL-AB12CD.com.limitty.shared", "group.com.limitty.shared"])
        XCTAssertEqual(SharedStore.groupCandidates(bundleID: "com.limitty.app"), ["group.com.limitty.shared"])
        XCTAssertEqual(SharedStore.groupCandidates(bundleID: "com.limitty.app.ABCDE12345", profileGroups: ["group.other", "group.com.limitty.shared.ABCDE12345"]).first,
                       "group.com.limitty.shared.ABCDE12345")
    }

    func testAppGroupsFromProvisioningProfile() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array><string>group.com.limitty.shared.TEAM</string></array>
        </dict></dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x01, 0x00, 0xFF]) // fake CMS header bytes
        blob.append(Data(plist.utf8))
        blob.append(Data([0x00, 0xA0, 0xFF]))
        XCTAssertEqual(SharedStore.appGroups(fromProvisioningProfile: blob), ["group.com.limitty.shared.TEAM"])
        XCTAssertEqual(SharedStore.appGroups(fromProvisioningProfile: Data("junk".utf8)), [])
    }
}

final class ServiceTests: XCTestCase {
    func testClaudeEndToEndSendsCookieAndCaches() async {
        let store = tempStore()
        store.setCredential(Credential(cookieHeader: "sessionKey=k", userAgent: "UA-1"), for: .claude)
        let http = FakeHTTP(claudeRoutes)
        let svc = LimitsService(store: store, http: http)

        let snaps = await svc.refreshAll()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertTrue(snaps[0].ok, snaps[0].error ?? "")
        XCTAssertEqual(snaps[0].plan, "Max")
        XCTAssertEqual(http.calls[0].headers["Cookie"], "sessionKey=k")
        XCTAssertEqual(http.calls[0].headers["User-Agent"], "UA-1")

        // Offline now: show the cached numbers, flagged stale.
        http.routes = [:]
        let again = await svc.refresh(.claude)
        XCTAssertTrue(again.ok)
        XCTAssertTrue(again.stale)
        XCTAssertEqual(again.windows.count, 3)
    }

    func testExpiredLoginIsNotHiddenByCache() async {
        let store = tempStore()
        store.setCredential(Credential(cookieHeader: "sessionKey=k"), for: .claude)
        let http = FakeHTTP(claudeRoutes)
        let svc = LimitsService(store: store, http: http)
        _ = await svc.refresh(.claude)
        http.routes["https://claude.ai/api/organizations"] = (401, "{}")
        let snap = await svc.refresh(.claude)
        XCTAssertEqual(snap.error, "Login expired")
    }

    func testCodexCookieMintsTokenAndSendsAccount() async {
        let token = jwt(["exp": Date().timeIntervalSince1970 + 3600, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-9"]])
        let store = tempStore()
        store.setCredential(Credential(cookieHeader: "__Secure-next-auth.session-token=abc"), for: .codex)
        let http = FakeHTTP([
            "https://chatgpt.com/api/auth/session": (200, #"{"accessToken":"\#(token)"}"#),
            "https://chatgpt.com/backend-api/wham/usage": (200, #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":60}}}"#),
        ])
        let snap = await LimitsService(store: store, http: http).refresh(.codex)
        XCTAssertTrue(snap.ok, snap.error ?? "")
        XCTAssertEqual(snap.plan, "Pro")
        XCTAssertEqual(http.calls[1].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(http.calls[1].headers["ChatGPT-Account-Id"], "acct-9")
    }

    func testExpiredPastedCodexToken() async {
        let store = tempStore()
        store.setCredential(Credential(bearerToken: jwt(["exp": 1000])), for: .codex)
        let snap = await LimitsService(store: store, http: FakeHTTP([:])).refresh(.codex)
        XCTAssertEqual(snap.error, "Token expired")
    }

    func testOnlySignedInProvidersAreFetched() async {
        let svc = LimitsService(store: tempStore(), http: FakeHTTP([:]))
        let snaps = await svc.refreshAll()
        XCTAssertTrue(snaps.isEmpty)
    }
}

let modelsJSON = #"""
{"models":{
  "gemini-3-pro-high":{"displayName":"Gemini 3 Pro (High)","quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-11-10T15:00:00Z"}},
  "gemini-3-pro-low":{"displayName":"Gemini 3 Pro (Low)","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-11-10T16:00:00Z"}},
  "gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":1}},
  "claude-sonnet-4-5":{"displayName":"Claude Sonnet 4.5","quotaInfo":{"resetTime":"2026-11-10T17:00:00Z"}},
  "gpt-oss-120b":{"displayName":"GPT-OSS 120B","quotaInfo":{"remainingFraction":0.5}},
  "gemini-2.5-pro-old":{"displayName":"Old","quotaInfo":{"remainingFraction":0.0}},
  "chat_20706":{"quotaInfo":{"remainingFraction":0.1}},
  "gemini-disabled":{"disabled":true,"quotaInfo":{"remainingFraction":0}}
 },
 "agentModelSorts":[{"groups":[{"modelIds":["gemini-3-pro-high","gemini-3-pro-low","gemini-3-flash","claude-sonnet-4-5","gpt-oss-120b","gemini-disabled"]}]}]
}
"""#

final class GeminiTests: XCTestCase {
    func testGroupsModelsIntoQuotaPools() {
        let w = GeminiParser.windows(from: Data(modelsJSON.utf8))
        XCTAssertEqual(w.map(\.label), ["Gemini Pro", "Gemini Flash", "Claude + GPT"])
        XCTAssertEqual(w.map { $0.usedPercent.rounded() }, [40, 0, 100]) // most-used model in each pool; missing fraction = empty
        XCTAssertEqual(w[0].resetsAt, JSON.date("2026-11-10T16:00:00Z"))
    }

    func testProjectAndPlan() {
        let p = GeminiParser.project(from: Data(#"{"cloudaicompanionProject":{"id":"proj-1"},"currentTier":{"name":"Free"},"paidTier":{"name":"Google AI Pro"}}"#.utf8))
        XCTAssertEqual(p.id, "proj-1")
        XCTAssertEqual(p.plan, "Google AI Pro")
    }

    func testAuthorizationURLAndCallback() throws {
        let url = GoogleOAuth.authorizationURL(codeChallenge: "chal", state: "st")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "redirect_uri" }?.value, "http://localhost:51121/oauth-callback")
        XCTAssertEqual(q.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(q.first { $0.name == "access_type" }?.value, "offline")

        let cb = URL(string: "http://localhost:51121/oauth-callback?state=st&code=4%2Fabc&scope=x")!
        XCTAssertEqual(try GoogleOAuth.code(fromCallback: cb, expectedState: "st"), "4/abc")
        XCTAssertThrowsError(try GoogleOAuth.code(fromCallback: cb, expectedState: "other"))
        XCTAssertThrowsError(try GoogleOAuth.code(fromCallback: URL(string: "http://localhost:51121/oauth-callback?error=access_denied&state=st")!, expectedState: "st"))
    }

    func testExchangeCode() async throws {
        let http = FakeHTTP([
            "https://oauth2.googleapis.com/token": (200, #"{"access_token":"at","refresh_token":"rt","expires_in":3599}"#),
            "https://www.googleapis.com/oauth2/v1/userinfo?alt=json": (200, #"{"email":"me@example.com"}"#),
        ])
        let now = Date(timeIntervalSince1970: 1000)
        let c = try await GoogleOAuth.exchange(code: "4/abc", verifier: "ver", http: http, now: now)
        XCTAssertEqual(c.bearerToken, "at")
        XCTAssertEqual(c.refreshToken, "rt")
        XCTAssertEqual(c.email, "me@example.com")
        XCTAssertEqual(c.accessExpiry, now.addingTimeInterval(3599))
        XCTAssertTrue(http.calls[0].body.contains("code=4%2Fabc"))
        XCTAssertTrue(http.calls[0].body.contains("code_verifier=ver"))
        XCTAssertTrue(http.calls[0].body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A51121%2Foauth-callback"))
    }

    func testRefreshesTokenFindsProjectAndSavesCredential() async {
        let store = tempStore()
        store.setCredential(Credential(bearerToken: "old", refreshToken: "rt", accessExpiry: Date(timeIntervalSince1970: 0)), for: .gemini)
        let http = FakeHTTP([
            "https://oauth2.googleapis.com/token": (200, #"{"access_token":"fresh","expires_in":3600}"#),
            "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": (200, #"{"cloudaicompanionProject":"proj-9","currentTier":{"name":"Google AI Pro"}}"#),
            "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels": (200, modelsJSON),
        ])
        let snap = await LimitsService(store: store, http: http).refresh(.gemini)
        XCTAssertTrue(snap.ok, snap.error ?? "")
        XCTAssertEqual(snap.plan, "Google AI Pro")
        XCTAssertEqual(snap.windows.first?.label, "Gemini Pro")

        let saved = store.credential(for: .gemini)
        XCTAssertEqual(saved?.bearerToken, "fresh")
        XCTAssertEqual(saved?.projectId, "proj-9")
        XCTAssertEqual(saved?.refreshToken, "rt")
        let models = http.calls.first { $0.url.hasSuffix("fetchAvailableModels") }!
        XCTAssertEqual(models.headers["Authorization"], "Bearer fresh")
        XCTAssertEqual(models.body, #"{"project":"proj-9"}"#)
        XCTAssertTrue(models.headers["User-Agent"]!.hasPrefix("antigravity/"))
    }

    func testRevokedGoogleAccessAsksToSignInAgain() async {
        let store = tempStore()
        store.setCredential(Credential(refreshToken: "rt"), for: .gemini)
        let http = FakeHTTP(["https://oauth2.googleapis.com/token": (400, #"{"error":"invalid_grant"}"#)])
        let snap = await LimitsService(store: store, http: http).refresh(.gemini)
        XCTAssertEqual(snap.error, "Login expired")
    }

    func testSafariUserAgent() {
        XCTAssertEqual(safariUserAgent(iOSVersion: "18.1.1"),
                       "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(safariUserAgent(iOSVersion: "26").contains("Version/26.0 "))
    }
}

// Generated by src/agents/crypto.js with key bytes 0…31 and nonce 0…11.
let agentKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
let agentBox = "AAECAwQFBgcICQoLPCCgOf/U7jnlLuT/k9NaAPr791fSV30PXQmRxGlLOoM2KZrPnvEiq0KIXZ7t9FtRgTcTr2CN2Phe8E93bMHPzJNQpw+3tARNPjrLA4qtNMp75qgXEgZzK5KZ++5U0tDp6cJ7h8Yi+SitPhKQOAdOFd8EFonZ50jjYIgyr/GPGmuZfiK1wLa/NirbasBJrimsQp2MWxc9sS7pK4kelvDTzND7/2CNmuwQwga5if/56c7v7rpH+cYazxa2r6lRsdjTZj/v2k+8paEVevGV0y+64cNEyUEENInAQaGp8jxk9NgiRLHBkgI5BzEo3G3NM1BzxvLUEL8Kq+Z4DwILqbBg6HDzyLLpsnkcW/0CddhHX2mulvDv4fvojV0NHiVrgN9pOyGpJ8iup3n1HhZ4bvDUsvGmeWRrw6Bl81hzcbURZ5qg+xxPqVpJ3prUSBFt4y1S7keqai0gonHPG6KeTgSusdtRbQ=="

final class AgentTests: XCTestCase {
    func testParsePairingLink() {
        let p = AgentPairing.parse("limitty://pair?s=https%3A%2F%2Fntfy.sh&t=limitty-abcXYZ&k=\(agentKey)")
        XCTAssertEqual(p, AgentPairing(server: "https://ntfy.sh", topic: "limitty-abcXYZ", key: agentKey))
        XCTAssertEqual(p?.alertsTopic, "limitty-abcXYZ-alerts")
        XCTAssertEqual(AgentPairing.parse("  s=https://my.server/&t=x1&k=\(agentKey)\n")?.server, "https://my.server")
        XCTAssertNil(AgentPairing.parse("limitty://pair?t=x1&k=short"))
        XCTAssertNil(AgentPairing.parse("limitty://pair?t=bad%20topic&k=\(agentKey)"))
        XCTAssertNil(AgentPairing.parse("hello"))
    }

    func testLatestMessageAndSummary() {
        let body = """
        {"id":"1","event":"open","topic":"t"}
        {"id":"2","event":"message","topic":"t","message":"first"}
        {"id":"3","event":"message","topic":"t","message":"newest"}

        """
        XCTAssertEqual(AgentFeed.latestMessage(Data(body.utf8)), "newest")
        XCTAssertNil(AgentFeed.latestMessage(Data()))
        XCTAssertEqual(AgentSample.status().summary, "1 needs you · 1 working")
    }

    #if canImport(CryptoKit)
    func testDecryptsWhatThePCSends() async throws {
        let http = FakeHTTP(["https://ntfy.sh/limitty-t/json?poll=1&since=latest": (200, #"{"id":"x","event":"message","topic":"limitty-t","message":"\#(agentBox)"}"#)])
        let status = try await AgentFeed(http: http).fetch(AgentPairing(server: "https://ntfy.sh", topic: "limitty-t", key: agentKey))
        XCTAssertEqual(status?.host, "my-pc")
        XCTAssertEqual(status?.sessions.map(\.state), [.attention, .working])
        XCTAssertEqual(status?.sessions.first?.project, "my-website")
        XCTAssertEqual(status?.summary, "1 needs you · 1 working")
    }

    func testWrongKeyFailsCleanly() async {
        let http = FakeHTTP(["https://ntfy.sh/t/json?poll=1&since=latest": (200, #"{"event":"message","message":"\#(agentBox)"}"#)])
        let other = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        do {
            _ = try await AgentFeed(http: http).fetch(AgentPairing(server: "https://ntfy.sh", topic: "t", key: other))
            XCTFail("should throw")
        } catch let e as LimitError {
            XCTAssertEqual(e.message, "Couldn't read your PC's status")
        } catch { XCTFail("\(error)") }
    }
    #endif

    func testPairingStorage() {
        let store = tempStore()
        XCTAssertNil(store.agentPairing())
        let p = AgentPairing(server: "https://ntfy.sh", topic: "t", key: agentKey)
        store.setAgentPairing(p)
        XCTAssertEqual(store.agentPairing(), p)
        store.saveAgentStatus(AgentSample.status())
        XCTAssertEqual(store.cachedAgentStatus()?.sessions.count, 3)
        store.setAgentPairing(nil)
        XCTAssertNil(store.agentPairing())
        XCTAssertNil(store.cachedAgentStatus())
    }
}
