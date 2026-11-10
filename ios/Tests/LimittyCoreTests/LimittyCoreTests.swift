import Foundation
import XCTest
@testable import LimittyCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var routes: [String: (Int, String)]
    var calls: [(url: String, headers: [String: String])] = []
    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        calls.append((url.absoluteString, headers))
        guard let (status, body) = routes[url.absoluteString] else { throw URLError(.notConnectedToInternet) }
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
