#if os(iOS)
import Foundation
import Network
import DaybriefCore

/// A TLS connection to Gmail's mail server.
final class MailConnection: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "daybrief.mail")

    /// Makes sure a waiting caller is answered exactly once.
    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: .tls)
    }

    func open() async throws {
        let once = Once()
        let connection = self.connection
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { ready.resume() }
                case .failed, .waiting, .cancelled:
                    if once.first() { ready.resume(throwing: BriefError("Can't reach Gmail. Check your connection.")) }
                    if case .waiting = state { connection.cancel() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { sent.resume(throwing: error) } else { sent.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (got: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let data, !data.isEmpty {
                    got.resume(returning: data)
                } else {
                    got.resume(throwing: error ?? BriefError("Gmail closed the connection."))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

enum GmailSource {
    static func mail(user: String, password: String, query: String) async throws -> [Item] {
        let connection = MailConnection(host: "imap.gmail.com", port: 993)
        // Gives up after 30 seconds: closing the connection ends any waiting call.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled { connection.close() }
        }
        defer {
            timeout.cancel()
            connection.close()
        }
        try await connection.open()
        let search = query.trimmingCharacters(in: .whitespaces).isEmpty ? AppSettings.defaultGmailQuery : query
        return try await GmailIMAP.fetch(transport: connection, user: user, password: password, query: search).map(GmailIMAP.item)
    }
}
#endif
