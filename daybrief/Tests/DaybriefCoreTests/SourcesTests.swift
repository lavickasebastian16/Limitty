import Foundation
import XCTest
@testable import DaybriefCore

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    return c
}()

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Plays back saved pages instead of calling EduPage.
private final class FakeEduHTTP: EduHTTP, @unchecked Sendable {
    var calls: [String] = []
    var forms: [String?] = []
    let answer: (String, String?) -> (url: String, status: Int, text: String)

    init(_ answer: @escaping (String, String?) -> (url: String, status: Int, text: String)) { self.answer = answer }

    func send(method: String, url: URL, form: String?) async throws -> (url: String, status: Int, text: String) {
        calls.append("\(method) \(url.absoluteString.replacingOccurrences(of: "https://myschool.edupage.org", with: ""))")
        forms.append(form)
        return answer(url.absoluteString, form)
    }
}

final class EduPageTests: XCTestCase {
    private let page = """
    <html><script>
    $j(document).ready(function() { ASC.gsechash="abc"; userhome({"userid":"Student1","items":[
      {"timelineid":"10","typ":"homework","text":"Read <b>chapter 3</b>","cas_udalosti":"2026-11-16 00:00:00","timestamp":"2026-11-12 10:00:00","data":"{\\"nazov\\":\\"x\\"}"},
      {"timelineid":"11","typ":"bexam","text":"","cas_udalosti":"2026-11-18 08:55:00","timestamp":"2026-11-10 10:00:00","data":"{\\"nazov\\":\\"Maths: fractions } {\\"}"},
      {"timelineid":"12","typ":"homework","text":"Done already","cas_udalosti":"2026-11-17 00:00:00","timestamp":"2026-11-12 10:00:00","data":"{}"},
      {"timelineid":"13","typ":"sprava","text":"A message","cas_udalosti":null,"timestamp":"2026-11-12 10:00:00","data":"{}"},
      {"timelineid":"14","typ":"homework","text":"Removed","removed":"1","cas_udalosti":"2026-11-17 00:00:00","timestamp":"2026-11-12 10:00:00","data":"{}"},
      {"timelineid":"15","typ":"sexam","text":"Old test","cas_udalosti":"2026-11-02 00:00:00","timestamp":"2026-10-30 10:00:00","data":"{}"},
      {"timelineid":"16","typ":"homework","text":"No date","cas_udalosti":null,"timestamp":"2026-11-11 10:00:00","data":"{}"},
      {"timelineid":"17","typ":"homework","text":"Late one","cas_udalosti":"2026-11-09 00:00:00","timestamp":"2026-11-01 10:00:00","data":"{}"}
    ],"userProps":{"12":{"doneMaxCas":"2026-11-12 18:00:00"}},"note":"a\tb"}); });
    </script></html>
    """

    func testSchoolName() {
        XCTAssertEqual(EduPageParser.school(" MySchool "), "myschool")
        XCTAssertEqual(EduPageParser.school("https://my-school.edupage.org/login/"), "my-school")
        XCTAssertEqual(EduPageParser.school("zs1.edupage.org"), "zs1")
        XCTAssertNil(EduPageParser.school("evil.com/x"))
        XCTAssertNil(EduPageParser.school(""))
    }

    func testReadsHomeworkExamsAndSkipsDone() throws {
        let home = try XCTUnwrap(EduPageParser.userHome(page))
        let items = EduPageParser.items(from: home, school: "myschool", now: at(2026, 11, 13, 12), calendar: cal)
        XCTAssertEqual(items.map(\.title), ["Read chapter 3", "Maths: fractions } {", "No date", "Late one"])
        XCTAssertEqual(items.map(\.detail), ["Homework", "Exam", "Homework", "Homework"])
        XCTAssertEqual(items.map(\.kind), [.task, .event, .task, .task])
        XCTAssertEqual(items[0].date, at(2026, 11, 16))
        XCTAssertFalse(items[0].hasTime)
        XCTAssertEqual(items[1].date, at(2026, 11, 18, 8, 55))
        XCTAssertTrue(items[1].hasTime)
        XCTAssertNil(items[2].date)
        XCTAssertEqual(items[0].id, "edupage:10")
        XCTAssertEqual(items[0].link, "https://myschool.edupage.org/")
        XCTAssertNil(EduPageParser.userHome("<html>Sign in</html>"))
    }

    func testSignInWrapping() {
        // Checked against Python: zlib.decompress(raw, -15) gives the form back.
        let fields = [("rpcparams", #"{"username":"jan","edupage":""}"#)]
        XCTAssertEqual(EduPageRPC.form(fields), "rpcparams=%7B%22username%22%3A%22jan%22%2C%22edupage%22%3A%22%22%7D")
        XCTAssertEqual(EduPageRPC.wrapped(fields), "dz:AUMAvP9ycGNwYXJhbXM9JTdCJTIydXNlcm5hbWUlMjIlM0ElMjJqYW4lMjIlMkMlMjJlZHVwYWdlJTIyJTNBJTIyJTIyJTdE")
        #if canImport(CryptoKit)
        XCTAssertEqual(EduPageRPC.body(fields), "eqap=dz%3AAUMAvP9ycGNwYXJhbXM9JTdCJTIydXNlcm5hbWUlMjIlM0ElMjJqYW4lMjIlMkMlMjJlZHVwYWdlJTIyJTNBJTIyJTIyJTdE&eqacs=2137c79c1713435dd53eab62b2bd7fb5979da973&eqaz=1")
        #endif
        XCTAssertEqual(EduPageRPC.decode("eqz:eyJ0b2tlbiI6ImFiYyJ9")?["token"] as? String, "abc")
        XCTAssertEqual(EduPageRPC.decode(#"{"token":"x"}"#)?["token"] as? String, "x")
        XCTAssertNil(EduPageRPC.decode("<html>"))
    }

    func testSignsInWithATokenThenReadsTheHomePage() async throws {
        let home = page
        let http = FakeEduHTTP { url, form in
            if url.hasSuffix("/user") { return (url, 200, "<html>login</html>") }
            if url.contains("akcia=getToken") { return (url, 200, "eqz:eyJ0b2tlbiI6ImFiYyJ9") }
            if url.contains("akcia=login") { return (url, 200, #"{"redirectUrl":"/user/?"}"#) }
            if url.hasSuffix("/user/?") { return (url, 200, home) }
            return (url, 200, #"<html>{"csrftoken":"tok"}</html>"#)
        }
        let items = try await EduPageClient(http: http).items(school: "myschool", username: "jan", password: "pw", now: at(2026, 11, 13), calendar: cal)
        XCTAssertEqual(items.count, 4)
        #if canImport(CryptoKit)
        XCTAssertEqual(http.calls, ["GET /user", "GET /login/?cmd=MainLogin", "POST /login/?cmd=MainLogin&akcia=getToken",
                                    "POST /login/?cmd=MainLogin&akcia=login", "GET /user/?"])
        #endif
    }

    func testFallsBackToTheFormAndReportsAWrongPassword() async {
        let http = FakeEduHTTP { url, form in
            if url.contains("akcia=") { return (url, 200, "") }
            if url.contains("edubarLogin") { return ("https://myschool.edupage.org/login/?bad=1", 200, "<html></html>") }
            return (url, 200, #"<html>{"csrftoken":"tok"}</html>"#)
        }
        do {
            _ = try await EduPageClient(http: http).items(school: "myschool", username: "jan", password: "a b&c")
            XCTFail("should not sign in")
        } catch {
            XCTAssertEqual((error as? BriefError)?.message, EduPageClient.badSignIn)
        }
        XCTAssertEqual(http.forms.last ?? nil, "csrfauth=tok&username=jan&password=a%20b%26c")
    }
}

/// A scripted mail server: answers each command with the given lines.
private final class FakeIMAP: IMAPTransport, @unchecked Sendable {
    var sent: [String] = []
    private var pending: [Data] = [Data("* OK Gimap ready\r\n".utf8)]
    private let answers: [(String, String)]

    init(_ answers: [(String, String)]) { self.answers = answers }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self)
        sent.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        let tag = String(line.split(separator: " ").first ?? "")
        let reply = answers.first { line.contains($0.0) }?.1 ?? "TAG BAD unknown\r\n"
        // In two pieces, as a network would deliver it.
        let bytes = Array(reply.replacingOccurrences(of: "TAG", with: tag).utf8)
        let cut = bytes.count / 2
        pending.append(Data(bytes[..<cut]))
        pending.append(Data(bytes[cut...]))
    }

    func receive() async throws -> Data {
        if pending.isEmpty { throw BriefError("closed") }
        return pending.removeFirst()
    }
}

final class MailTests: XCTestCase {
    func testBufferWaitsForWholeResponses() {
        var b = IMAPBuffer()
        b.append(Data("* OK hi\r\n* 1 FETCH (ENVELOPE (NIL {5}\r\nab".utf8))
        XCTAssertEqual(b.next().map { String(decoding: $0, as: UTF8.self) }, "* OK hi")
        XCTAssertNil(b.next())
        b.append(Data("\r\nc NIL))\r".utf8))
        XCTAssertNil(b.next())
        b.append(Data("\n".utf8))
        XCTAssertEqual(b.next().map { String(decoding: $0, as: UTF8.self) }, "* 1 FETCH (ENVELOPE (NIL {5}\r\nab\r\nc NIL))")
        XCTAssertNil(b.next())
    }

    func testParsesListsStringsAndLiterals() {
        let values = IMAPParser.parse(Array("* 1 FETCH (UID 7 FLAGS (\\Seen \\Flagged) X \"a \\\"b\\\"\" Y {3}\r\n(c) Z NIL)".utf8))
        XCTAssertEqual(values, [.atom("*"), .atom("1"), .atom("FETCH"), .list([
            .atom("UID"), .atom("7"), .atom("FLAGS"), .list([.atom("\\Seen"), .atom("\\Flagged")]),
            .atom("X"), .string(Array("a \"b\"".utf8)), .atom("Y"), .string(Array("(c)".utf8)), .atom("Z"), .none,
        ])])
    }

    func testDecodesHeaders() {
        XCTAssertEqual(MIMEWords.decode("Plain subject"), "Plain subject")
        XCTAssertEqual(MIMEWords.decode("=?UTF-8?B?xb1sdcWlb3XEjWvDvSBrw7TFiA==?="), "Žluťoučký kôň")
        XCTAssertEqual(MIMEWords.decode("Re: =?utf-8?Q?=C5=A0kola_v_pr=C3=ADrode?= 2026"), "Re: Škola v prírode 2026")
        XCTAssertEqual(MIMEWords.decode("=?iso-8859-2?Q?=A9kola?= =?iso-8859-2?Q?_dnes?="), "Škola dnes")
        XCTAssertEqual(MIMEWords.decode("1 =? 2"), "1 =? 2")
    }

    func testReadsTheInbox() async throws {
        let fetch = "* 1 FETCH (UID 41 FLAGS (\\Flagged) INTERNALDATE \"12-Nov-2026 09:14:00 +0100\" ENVELOPE (\"Thu, 12 Nov 2026 09:14:00 +0100\" \"=?UTF-8?B?xaBrb2xza8O9IHbDvWxldA==?=\" ((\"Jana Nov\\\"a\" NIL \"jana\" \"example.com\")) NIL NIL NIL NIL NIL NIL \"<1@example.com>\"))\r\n"
            + "* 2 FETCH (UID 45 FLAGS () INTERNALDATE \"13-Nov-2026 07:00:00 +0000\" ENVELOPE (NIL {7}\r\nInvoice ((NIL NIL \"billing\" \"shop.example\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
            + "TAG OK Success\r\n"
        let server = FakeIMAP([
            ("LOGIN", "TAG OK signed in\r\n"),
            ("EXAMINE", "* 2 EXISTS\r\nTAG OK [READ-ONLY] done\r\n"),
            ("SEARCH", "* SEARCH 45 41\r\nTAG OK done\r\n"),
            ("FETCH", fetch),
            ("LOGOUT", "* BYE\r\nTAG OK bye\r\n"),
        ])
        let mail = try await GmailIMAP.fetch(transport: server, user: "me@gmail.com", password: "abcd efgh ijkl mnop", query: "is:starred")
        XCTAssertEqual(server.sent, [
            "a1 LOGIN \"me@gmail.com\" \"abcdefghijklmnop\"",
            "a2 EXAMINE INBOX",
            "a3 UID SEARCH X-GM-RAW \"is:starred\"",
            "a4 UID FETCH 41,45 (UID FLAGS INTERNALDATE ENVELOPE)",
            "a5 LOGOUT",
        ])
        XCTAssertEqual(mail.map(\.uid), ["45", "41"])
        XCTAssertEqual(mail.map(\.subject), ["Invoice", "Školský výlet"])
        XCTAssertEqual(mail.map(\.from), ["billing@shop.example", "Jana Nov\"a"])
        XCTAssertEqual(mail.map(\.starred), [false, true])
        XCTAssertEqual(mail[1].date, at(2026, 11, 12, 9, 14))
        let item = GmailIMAP.item(mail[1])
        XCTAssertEqual(item.kind, .mail)
        XCTAssertEqual(item.detail, "★ Jana Nov\"a")
    }

    func testWrongPasswordIsExplained() async {
        let server = FakeIMAP([("LOGIN", "TAG NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")])
        do {
            _ = try await GmailIMAP.fetch(transport: server, user: "me@gmail.com", password: "x", query: "")
            XCTFail("should not sign in")
        } catch {
            XCTAssertEqual((error as? BriefError)?.message, GmailIMAP.badSignIn)
        }
    }

    func testNothingFound() async throws {
        let server = FakeIMAP([("LOGIN", "TAG OK\r\n"), ("EXAMINE", "TAG OK\r\n"), ("SEARCH", "* SEARCH\r\nTAG OK\r\n"), ("LOGOUT", "TAG OK\r\n")])
        let mail = try await GmailIMAP.fetch(transport: server, user: "me@gmail.com", password: "x", query: "é is:unread")
        XCTAssertEqual(mail, [])
        XCTAssertEqual(server.sent[2], "a3 UID SEARCH X-GM-RAW \" is:unread\"")
    }
}
