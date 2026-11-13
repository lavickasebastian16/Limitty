import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// EduPage has no public API. This signs in the way its own web page does and
// reads the same data the page shows after sign-in. The steps follow the
// open-source edupage-api project (github.com/EdupageAPI/edupage-api).

/// Reads the data out of EduPage pages.
public enum EduPageParser {
    /// "myschool", "myschool.edupage.org" or a full link → "myschool".
    public static func school(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        s = String(s.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        if s.hasSuffix(".edupage.org") { s = String(s.dropLast(".edupage.org".count)) }
        let ok = !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
        return ok ? s : nil
    }

    /// The data inside `userhome({...})` on the page shown after sign-in.
    public static func userHome(_ html: String) -> [String: Any]? {
        guard let marker = html.range(of: "userhome(") else { return nil }
        // Raw tabs and line breaks are not allowed in JSON strings; EduPage sends some.
        let rest = html[marker.upperBound...].unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        guard let object = balancedObject(String(String.UnicodeScalarView(rest))),
              let data = object.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// The first complete `{...}` at the start of the text.
    static func balancedObject(_ text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var out = String.UnicodeScalarView()
        for ch in text.unicodeScalars {
            if depth == 0 {
                if ch == "{" { depth = 1; out.append(ch); continue }
                if ch == " " { continue }
                return nil
            }
            out.append(ch)
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(out) }
            }
        }
        return nil
    }

    private static let homework: Set<String> = ["homework", "etesthw"]
    private static let exams: Set<String> = ["bexam", "sexam", "oexam", "rexam", "pexam", "testing", "testpridelenie"]
    private static let events: Set<String> = ["event", "schoolevent", "excursion", "trip", "parentsevening", "culture",
                                              "ctevent", "meeting", "bmeeting", "contest", "project"]
    private static let tags = Rx("<[^>]+>")

    /// Homework, exams and school events from the sign-in data that are still ahead
    /// (or at most two weeks old), and not marked done.
    public static func items(from home: [String: Any], school: String, now: Date, calendar: Calendar = .current) -> [Item] {
        guard let rows = home["items"] as? [[String: Any]] else { return [] }
        let props = home["userProps"] as? [String: Any] ?? [:]
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -14, to: today) ?? today
        let link = "https://\(school).edupage.org/"

        var out: [Item] = []
        var seen = Set<String>()
        for row in rows {
            guard let id = string(row["timelineid"]), let type = string(row["typ"]) else { continue }
            let label: String
            let kind: ItemKind
            if homework.contains(type) { label = "Homework"; kind = .task }
            else if exams.contains(type) { label = "Exam"; kind = .event }
            else if events.contains(type) { label = "School event"; kind = .event }
            else { continue }
            if string(row["removed"]) == "1" { continue }
            if let p = props[id] as? [String: Any], let done = string(p["doneMaxCas"]), !done.isEmpty { continue }

            var extra: [String: Any] = [:]
            if let d = row["data"] as? [String: Any] { extra = d }
            else if let s = row["data"] as? String, let d = s.data(using: .utf8),
                    let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { extra = parsed }

            var title = clean(string(row["text"]) ?? "")
            if title.isEmpty { title = clean(string(extra["nazov"]) ?? "") }
            if title.isEmpty { continue }

            // `cas_udalosti` is when it happens (for homework: the day it is due).
            var when: (date: Date, hasTime: Bool)?
            for candidate in [string(row["cas_udalosti"]), string(extra["date"]), string(extra["datetill"]), string(extra["dateto"])] {
                if let c = candidate, let parsed = DayParser.dateTime(c, calendar: calendar) { when = parsed; break }
            }

            if let when {
                if when.date < oldest { continue }
                // Exams and events that are over are not something to do.
                if kind == .event && when.date < today { continue }
            } else {
                // No date: keep recent homework as a task without a date, skip the rest.
                guard kind == .task, let added = string(row["timestamp"]).flatMap({ DayParser.dateTime($0, calendar: calendar) }),
                      added.date >= oldest else { continue }
            }
            guard seen.insert(id).inserted else { continue }
            out.append(Item(id: "edupage:\(id)", source: .edupage, kind: kind, title: title, detail: label,
                            date: when?.date, hasTime: when?.hasTime ?? false, link: link))
        }
        return out
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func clean(_ text: String) -> String {
        var s = tags.replace(in: text, with: " ")
        for (entity, plain) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\"")] {
            s = s.replacingOccurrences(of: entity, with: plain)
        }
        return s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }
}

/// The wrapping EduPage's sign-in calls use for what they send and return.
public enum EduPageRPC {
    public static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func form(_ fields: [(String, String)]) -> String {
        fields.map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }.joined(separator: "&")
    }

    /// Raw DEFLATE without compression ("stored" blocks), which any inflater reads.
    static func deflateStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        repeat {
            let n = min(bytes.count - offset, 0xFFFF)
            let last = offset + n >= bytes.count
            out.append(last ? 1 : 0)
            out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<offset + n])
            offset += n
        } while offset < bytes.count
        return out
    }

    /// `eqap` (the wrapped fields) and what `eqacs` is the SHA-1 of.
    static func wrapped(_ fields: [(String, String)]) -> String {
        "dz:" + Data(deflateStored(Array(form(fields).utf8))).base64EncodedString()
    }

    /// The body of a sign-in call, or nil where SHA-1 isn't available.
    public static func body(_ fields: [(String, String)]) -> String? {
        #if canImport(CryptoKit)
        let eqap = wrapped(fields)
        let hash = Insecure.SHA1.hash(data: Data(eqap.utf8)).map { byte -> String in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
        return form([("eqap", eqap), ("eqacs", hash), ("eqaz", "1")])
        #else
        return nil
        #endif
    }

    /// The JSON in a sign-in call's answer.
    public static func decode(_ response: String) -> [String: Any]? {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        var data = Data(text.utf8)
        for prefix in ["eqwd:", "eqz:"] where text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).filter { !$0.isWhitespace }
            guard let d = Data(base64Encoded: encoded) else { return nil }
            data = d
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// One web request, for the EduPage sign-in. Cookies are kept between calls.
public protocol EduHTTP: Sendable {
    /// Returns the address after redirects and the page text.
    func send(method: String, url: URL, form: String?) async throws -> (url: String, status: Int, text: String)
}

public final class URLSessionEduHTTP: EduHTTP, @unchecked Sendable {
    private let session: URLSession

    public init() {
        // Its own cookie jar, kept only while the app runs.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        ]
        session = URLSession(configuration: config)
    }

    public func send(method: String, url: URL, form: String?) async throws -> (url: String, status: Int, text: String) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let form {
            req.httpBody = Data(form.utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (resp.url?.absoluteString ?? url.absoluteString, (resp as? HTTPURLResponse)?.statusCode ?? 0, text)
    }
}

/// Signs in to EduPage and reads homework, exams and events.
public final class EduPageClient: Sendable {
    public static let badSignIn = "EduPage didn't accept the sign-in. Check the school, username and password."

    private let http: EduHTTP

    public init(http: EduHTTP = URLSessionEduHTTP()) {
        self.http = http
    }

    public func items(school input: String, username: String, password: String, now: Date = Date(), calendar: Calendar = .current) async throws -> [Item] {
        guard let school = EduPageParser.school(input) else {
            throw BriefError("That school name doesn't look right. Use the first part of your EduPage address, e.g. “myschool” for myschool.edupage.org.")
        }
        let base = "https://\(school).edupage.org"

        // Still signed in from the last refresh?
        if let page = try? await http.send(method: "GET", url: try url(base + "/user"), form: nil),
           let home = EduPageParser.userHome(page.text) {
            return EduPageParser.items(from: home, school: school, now: now, calendar: calendar)
        }

        var page = try await rpcSignIn(base: base, username: username, password: password)
        if page == nil { page = try await formSignIn(base: base, username: username, password: password) }
        guard let page else { throw BriefError(Self.badSignIn) }
        if page.url.contains("twofactor") {
            throw BriefError("This EduPage account uses two-step sign-in, which Daybrief can't do yet.")
        }
        guard let home = EduPageParser.userHome(page.text) else { throw BriefError(Self.badSignIn) }
        return EduPageParser.items(from: home, school: school, now: now, calendar: calendar)
    }

    private func url(_ text: String) throws -> URL {
        guard let u = URL(string: text) else { throw BriefError("EduPage sent a link that can't be opened.") }
        return u
    }

    /// The current sign-in (as on EduPage's own page): ask for a token, then sign in with it.
    private func rpcSignIn(base: String, username: String, password: String) async throws -> (url: String, text: String)? {
        let start = try await http.send(method: "GET", url: try url(base + "/login/?cmd=MainLogin"), form: nil)
        guard start.status == 200 else { return nil }

        guard let tokenBody = EduPageRPC.body([("rpcparams", json(["username": username, "edupage": ""]))]) else { return nil }
        let tokenPage = try await http.send(method: "POST", url: try url(base + "/login/?cmd=MainLogin&akcia=getToken"), form: tokenBody)
        guard tokenPage.status == 200, let token = EduPageRPC.decode(tokenPage.text)?["token"] as? String, !token.isEmpty else { return nil }

        let params: [String: Any] = ["username": username, "password": password, "userToken": token, "edupage": "",
                                     "ctxt": "", "tu": NSNull(), "gu": NSNull(), "au": NSNull()]
        guard let loginBody = EduPageRPC.body([("rpcparams", json(params))]) else { return nil }
        let loginPage = try await http.send(method: "POST", url: try url(base + "/login/?cmd=MainLogin&akcia=login"), form: loginBody)
        guard loginPage.status == 200, let answer = EduPageRPC.decode(loginPage.text),
              let redirect = answer["redirectUrl"] as? String, !redirect.isEmpty else { return nil }

        let target = redirect.hasPrefix("http") ? redirect : base + (redirect.hasPrefix("/") ? "" : "/") + redirect
        let home = try await http.send(method: "GET", url: try url(target), form: nil)
        return (home.url, home.text)
    }

    /// The older sign-in form, used when the current one isn't offered.
    private func formSignIn(base: String, username: String, password: String) async throws -> (url: String, text: String)? {
        let start = try await http.send(method: "GET", url: try url(base + "/login/?cmd=MainLogin"), form: nil)
        guard let marker = start.text.range(of: "\"csrftoken\":\""),
              let end = start.text[marker.upperBound...].firstIndex(of: "\"") else {
            throw BriefError("Can't reach the EduPage sign-in page for this school. Check the school name.")
        }
        let token = String(start.text[marker.upperBound..<end])
        let form = EduPageRPC.form([("csrfauth", token), ("username", username), ("password", password)])
        let page = try await http.send(method: "POST", url: try url(base + "/login/edubarLogin.php"), form: form)
        if page.url.contains("cap=1") || page.url.contains("lerr=b43b43") {
            throw BriefError("EduPage is asking for a captcha. Sign in once at \(base) in Safari, then try again later.")
        }
        if page.url.contains("bad=1") { throw BriefError(Self.badSignIn) }
        return (page.url, page.text)
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
