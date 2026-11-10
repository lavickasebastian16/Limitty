#if os(iOS)
import SwiftUI
import AuthenticationServices
import CryptoKit
import Network
import LimittyCore

/// Google sign-in for the Gemini (Antigravity) quota.
///
/// Google refuses sign-in inside an app's own web view, so this uses iOS's
/// secure Safari sign-in sheet. Antigravity's Google client sends you back to
/// http://localhost:51121/oauth-callback, so Limitty briefly listens on that port
/// on the phone itself to catch the reply.
struct GoogleLoginView: View {
    let onSignedIn: (Credential) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var flow = GoogleFlow()
    @State private var working = false
    @State private var error: String?
    @State private var showManual = false
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Limitty reads your **Gemini Pro**, **Gemini Flash** and **Claude + GPT** quotas from Antigravity, the same numbers as agy's /usage.")
                    Label("This signs in as the Antigravity app, which Google's terms don't allow. Accounts have been suspended for this, so a spare Google account is safest.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Section {
                    Button {
                        Task { await run { try await flow.signIn() } }
                    } label: {
                        HStack {
                            Label("Sign in with Google", systemImage: "person.badge.key")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button("Open sign-in in Safari instead") {
                        openURL(flow.authURL)
                        showManual = true
                    }
                    if showManual {
                        TextField("Paste the localhost link", text: $pasted, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Finish sign-in") {
                            Task { await run { try await flow.finish(pastedLink: pasted) } }
                        }
                        .disabled(pasted.isEmpty || working)
                    }
                } header: {
                    Text("Didn't work?")
                } footer: {
                    Text("After signing in, Safari will show “can't connect to localhost”. That's expected: copy the link from the address bar, come back, and paste it here.")
                }
            }
            .navigationTitle("Gemini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func run(_ step: () async throws -> Credential) async {
        working = true
        error = nil
        defer { working = false }
        do {
            onSignedIn(try await step())
            dismiss()
        } catch let e as LimitError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class GoogleFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    let verifier = GoogleFlow.randomString(bytes: 48)
    let state = GoogleFlow.randomString(bytes: 16)
    private(set) lazy var authURL = GoogleOAuth.authorizationURL(codeChallenge: Self.challenge(for: verifier), state: state)
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?

    func signIn() async throws -> Credential {
        let expectedState = state
        let code: String = try await withCheckedThrowingContinuation { cont in
            var finished = false
            let finish: (Result<String, Error>) -> Void = { [weak self] result in
                guard !finished else { return }
                finished = true
                // Let the "you're signed in" page reach the sheet before closing it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.session?.cancel()
                    self?.server?.stop()
                }
                cont.resume(with: result)
            }

            do {
                server = try LoopbackServer(port: GoogleOAuth.port) { url in
                    finish(Result { try GoogleOAuth.code(fromCallback: url, expectedState: expectedState) })
                }
            } catch {
                finish(.failure(LimitError("Couldn't listen for Google's reply (\(error.localizedDescription))",
                                           hint: "Use “Open sign-in in Safari instead”.")))
                return
            }

            let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "limitty") { url, err in
                Task { @MainActor in
                    if let url { finish(Result { try GoogleOAuth.code(fromCallback: url, expectedState: expectedState) }) }
                    else { finish(.failure(LimitError("Sign-in was cancelled"))) }
                }
            }
            s.presentationContextProvider = self
            session = s
            if !s.start() { finish(.failure(LimitError("Couldn't open Google sign-in"))) }
        }
        return try await GoogleOAuth.exchange(code: code, verifier: verifier)
    }

    func finish(pastedLink: String) async throws -> Credential {
        guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LimitError("That isn't a link")
        }
        let code = try GoogleOAuth.code(fromCallback: url, expectedState: state)
        return try await GoogleOAuth.exchange(code: code, verifier: verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    static func randomString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A tiny HTTP server on the phone's own localhost that waits for Google's redirect.
final class LoopbackServer {
    private let listener: NWListener

    init(port: UInt16, onCallback: @escaping @MainActor (URL) -> Void) throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, _ in
                // First line looks like: GET /oauth-callback?state=…&code=… HTTP/1.1
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
                let isCallback = target.hasPrefix(GoogleOAuth.callbackPath)
                let html = isCallback
                    ? "<meta name=viewport content='width=device-width'><body style='font:17px -apple-system;text-align:center;padding-top:30vh'><h2>Signed in ✓</h2><p>You can return to Limitty.</p></body>"
                    : "Not found"
                let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                if isCallback, let url = URL(string: "http://localhost:\(port)\(target)") {
                    Task { @MainActor in onCallback(url) }
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel() }
}
#endif
