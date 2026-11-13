import Foundation

// A small IMAP reader for Gmail: sign in with an app password, search the inbox
// and read each message's subject and sender. It only reads; the inbox is opened
// read-only, so nothing is marked as read.

/// Collects bytes from the server and hands back one complete response at a time.
public struct IMAPBuffer: Sendable {
    private var bytes: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// The next full response line, including any `{n}` blocks inside it, or nil
    /// when more bytes are needed.
    public mutating func next() -> [UInt8]? {
        var pos = 0
        while true {
            guard let lineEnd = crlf(from: pos) else { return nil }
            if let n = literalLength(endingAt: lineEnd, from: pos) {
                // `{n}` at the end of a line: n raw bytes follow, then the line goes on.
                let after = lineEnd + 2 + n
                if bytes.count < after { return nil }
                pos = after
                continue
            }
            let response = Array(bytes[0..<lineEnd])
            bytes.removeFirst(lineEnd + 2)
            return response
        }
    }

    private func crlf(from start: Int) -> Int? {
        guard bytes.count >= 2, start < bytes.count - 1 else { return nil }
        var i = start
        while i < bytes.count - 1 {
            if bytes[i] == 13 && bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    private func literalLength(endingAt lineEnd: Int, from start: Int) -> Int? {
        guard lineEnd - start >= 3, bytes[lineEnd - 1] == UInt8(ascii: "}") else { return nil }
        var i = lineEnd - 2
        var digits: [UInt8] = []
        while i >= start, bytes[i] >= 48, bytes[i] <= 57 {
            digits.insert(bytes[i], at: 0)
            i -= 1
        }
        guard !digits.isEmpty, digits.count < 10, i >= start, bytes[i] == UInt8(ascii: "{") else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}

/// A parsed piece of an IMAP response.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string([UInt8])
    case list([IMAPValue])
    case none

    public var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: .isoLatin1)
        default: return nil
        }
    }

    public var items: [IMAPValue] {
        if case .list(let l) = self { return l }
        return []
    }
}

public enum IMAPParser {
    /// Splits one response into atoms, strings and lists.
    public static func parse(_ bytes: [UInt8]) -> [IMAPValue] {
        var pos = 0
        return parseSequence(bytes, &pos, nested: false)
    }

    private static func parseSequence(_ b: [UInt8], _ pos: inout Int, nested: Bool) -> [IMAPValue] {
        var out: [IMAPValue] = []
        while pos < b.count {
            let c = b[pos]
            if c == UInt8(ascii: " ") || c == 13 || c == 10 { pos += 1; continue }
            if c == UInt8(ascii: ")") {
                pos += 1
                if nested { return out }
                continue
            }
            if c == UInt8(ascii: "(") {
                pos += 1
                out.append(.list(parseSequence(b, &pos, nested: true)))
            } else if c == UInt8(ascii: "\"") {
                pos += 1
                var s: [UInt8] = []
                while pos < b.count, b[pos] != UInt8(ascii: "\"") {
                    if b[pos] == UInt8(ascii: "\\"), pos + 1 < b.count { pos += 1 }
                    s.append(b[pos])
                    pos += 1
                }
                pos += 1
                out.append(.string(s))
            } else if c == UInt8(ascii: "{"), let (n, start) = literalHeader(b, pos) {
                let end = min(start + n, b.count)
                out.append(.string(Array(b[start..<end])))
                pos = end
            } else {
                var s: [UInt8] = []
                var depth = 0 // keeps `BODY[HEADER.FIELDS (SUBJECT)]` in one piece
                while pos < b.count {
                    let ch = b[pos]
                    if ch == UInt8(ascii: "[") { depth += 1 }
                    if ch == UInt8(ascii: "]") { depth -= 1 }
                    if depth <= 0 && (ch == UInt8(ascii: " ") || ch == UInt8(ascii: "(") || ch == UInt8(ascii: ")") || ch == 13 || ch == 10) { break }
                    s.append(ch)
                    pos += 1
                }
                let atom = String(decoding: s, as: UTF8.self)
                out.append(atom.uppercased() == "NIL" ? .none : .atom(atom))
            }
        }
        return out
    }

    /// `{12}\r\n` at `pos` → (12, index of the first data byte).
    private static func literalHeader(_ b: [UInt8], _ pos: Int) -> (Int, Int)? {
        var i = pos + 1
        var n = 0
        var any = false
        while i < b.count, b[i] >= 48, b[i] <= 57, n < 100_000_000 {
            n = n * 10 + Int(b[i] - 48)
            i += 1
            any = true
        }
        guard any, i + 2 < b.count, b[i] == UInt8(ascii: "}"), b[i + 1] == 13, b[i + 2] == 10 else { return nil }
        return (n, i + 3)
    }
}

/// Decodes mail headers such as `=?UTF-8?B?xb1sdcWl?=` (RFC 2047).
public enum MIMEWords {
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var out = ""
        var rest = Substring(text)
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[rest.startIndex..<start.lowerBound]
            if let (word, after) = encodedWord(rest[start.lowerBound...]) {
                // Spaces between two encoded words are not part of the text.
                if !(lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })) { out += before }
                out += word
                rest = after
                lastWasEncoded = true
            } else {
                out += before
                out += "=?"
                rest = rest[start.upperBound...]
                lastWasEncoded = false
            }
        }
        return out + rest
    }

    /// Parses `=?charset?B?text?=` at the start of `s`.
    private static func encodedWord(_ s: Substring) -> (String, Substring)? {
        let parts = s.dropFirst(2).split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[3].hasPrefix("=") else { return nil }
        let charset = parts[0].split(separator: "*").first.map { $0.lowercased() } ?? ""
        let kind = parts[1].uppercased()
        var bytes: [UInt8]
        if kind == "B" {
            var b64 = String(parts[2])
            while b64.count % 4 != 0 { b64 += "=" }
            guard let d = Data(base64Encoded: b64) else { return nil }
            bytes = Array(d)
        } else if kind == "Q" {
            bytes = []
            let raw = Array(parts[2].utf8)
            var i = 0
            while i < raw.count {
                if raw[i] == UInt8(ascii: "_") {
                    bytes.append(32)
                } else if raw[i] == UInt8(ascii: "="), i + 2 < raw.count,
                          let v = UInt8(String(decoding: raw[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(v)
                    i += 2
                } else {
                    bytes.append(raw[i])
                }
                i += 1
            }
        } else {
            return nil
        }
        let word = String(bytes: bytes, encoding: encoding(charset))
            ?? String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return (word, parts[3].dropFirst())
    }

    private static func encoding(_ charset: String) -> String.Encoding {
        switch charset {
        case "iso-8859-1", "latin1": return .isoLatin1
        case "iso-8859-2", "latin2": return .isoLatin2
        case "windows-1250", "cp1250": return .windowsCP1250
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1252", "cp1252": return .windowsCP1252
        case "us-ascii", "ascii": return .ascii
        default: return .utf8
        }
    }
}

public struct MailMessage: Equatable, Sendable {
    public var uid: String
    public var subject: String
    public var from: String
    public var date: Date?
    public var starred: Bool
}

/// The connection to the mail server (TLS on the phone, a script in tests).
public protocol IMAPTransport: Sendable {
    func send(_ data: Data) async throws
    /// The next bytes from the server. Throws when the connection closes.
    func receive() async throws -> Data
}

public enum GmailIMAP {
    public static let badSignIn = "Gmail didn't accept the sign-in. Use your full address and an app password (not your normal password)."

    /// Messages in the inbox that match a Gmail search, newest first.
    public static func fetch(transport: IMAPTransport, user: String, password: String, query: String, limit: Int = 30) async throws -> [MailMessage] {
        let session = Session(transport: transport)
        _ = try await session.read() // the server's greeting

        do {
            // App passwords are shown in groups of four; the spaces aren't part of them.
            _ = try await session.command("LOGIN \(quote(user)) \(quote(password.replacingOccurrences(of: " ", with: "")))")
        } catch let e as BriefError {
            throw e.message.hasPrefix("Gmail said") ? BriefError(badSignIn) : e
        }
        _ = try await session.command("EXAMINE INBOX")

        let found = try await session.command("UID SEARCH X-GM-RAW \(quote(ascii(query)))")
        var uids: [Int] = []
        for line in found {
            let values = IMAPParser.parse(line)
            guard values.count >= 2, values[1].text?.uppercased() == "SEARCH" else { continue }
            uids += values.dropFirst(2).compactMap { $0.text.flatMap { Int($0) } }
        }
        uids = Array(uids.sorted().suffix(limit))
        guard !uids.isEmpty else {
            _ = try? await session.command("LOGOUT")
            return []
        }

        let list = uids.map(String.init).joined(separator: ",")
        let fetched = try await session.command("UID FETCH \(list) (UID FLAGS INTERNALDATE ENVELOPE)")
        _ = try? await session.command("LOGOUT")
        return fetched.compactMap(message).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// One `* 12 FETCH (UID 34 FLAGS (...) INTERNALDATE "..." ENVELOPE (...))` line.
    static func message(_ line: [UInt8]) -> MailMessage? {
        let values = IMAPParser.parse(line)
        guard values.count >= 4, values[2].text?.uppercased() == "FETCH" else { return nil }
        let fields = values[3].items
        var uid: String?
        var subject = ""
        var from = ""
        var date: Date?
        var starred = false
        var i = 0
        while i + 1 < fields.count {
            let name = fields[i].text?.uppercased() ?? ""
            let value = fields[i + 1]
            switch name {
            case "UID": uid = value.text
            case "FLAGS": starred = value.items.contains { $0.text?.lowercased() == "\\flagged" }
            case "INTERNALDATE": date = value.text.flatMap(internalDate)
            case "ENVELOPE":
                // (date subject from sender reply-to to cc bcc in-reply-to message-id)
                let env = value.items
                if env.count > 1 { subject = MIMEWords.decode(env[1].text ?? "") }
                // An address is (name route mailbox host).
                if env.count > 2, let first = env[2].items.first?.items, first.count >= 4 {
                    let name = MIMEWords.decode(first[0].text ?? "").trimmingCharacters(in: .whitespaces)
                    let address = [first[2].text, first[3].text].compactMap { $0 }.joined(separator: "@")
                    from = name.isEmpty ? address : name
                }
            default: break
            }
            i += 2
        }
        guard let uid else { return nil }
        subject = subject.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return MailMessage(uid: uid, subject: subject.isEmpty ? "(no subject)" : subject, from: from, date: date, starred: starred)
    }

    /// "13-Nov-2026 09:14:00 +0100"
    static func internalDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func quote(_ text: String) -> String {
        let clean = text.filter { $0 != "\r" && $0 != "\n" }
        return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func ascii(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.isASCII }))
    }

    public static func item(_ m: MailMessage) -> Item {
        Item(id: "gmail:\(m.uid)", source: .gmail, kind: .mail, title: m.subject,
             detail: m.starred ? "★ \(m.from)" : m.from, date: m.date, hasTime: true, link: "googlegmail://")
    }

    private final class Session: @unchecked Sendable {
        let transport: IMAPTransport
        var buffer = IMAPBuffer()
        var count = 0

        init(transport: IMAPTransport) { self.transport = transport }

        func read() async throws -> [UInt8] {
            while true {
                if let response = buffer.next() { return response }
                let data = try await transport.receive()
                if data.isEmpty { throw BriefError("Gmail closed the connection.") }
                buffer.append(data)
            }
        }

        /// Sends a command and returns the server's lines up to its "OK".
        func command(_ text: String) async throws -> [[UInt8]] {
            count += 1
            let tag = "a\(count)"
            try await transport.send(Data("\(tag) \(text)\r\n".utf8))
            var lines: [[UInt8]] = []
            let prefix = Array("\(tag) ".utf8)
            while true {
                let line = try await read()
                guard line.starts(with: prefix) else {
                    lines.append(line)
                    continue
                }
                let status = String(decoding: line.dropFirst(prefix.count), as: UTF8.self)
                if status.uppercased().hasPrefix("OK") { return lines }
                throw BriefError("Gmail said: \(status)")
            }
        }
    }
}
