#if os(iOS)
import SwiftUI
import WebKit
import LimittyCore

/// Opens the provider's real sign-in page. As soon as the login cookie appears,
/// the cookies for that site are saved to shared storage for the widget.
struct LoginView: View {
    let provider: Provider
    let onSignedIn: (Credential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showPaste = false
    @State private var pasted = ""
    @State private var pasteError = false

    var body: some View {
        NavigationStack {
            WebLogin(provider: provider) { credential in
                onSignedIn(credential)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) {
                Text("If Google says this browser isn't secure, go back and use “Continue with email” (the code goes to the same Gmail), or tap Paste instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Paste instead") { showPaste = true } }
            }
            .alert("Paste a login", isPresented: $showPaste) {
                SecureField(provider == .claude ? "sessionKey cookie" : "Cookie or access token", text: $pasted)
                Button("Save") {
                    if let c = Credential.fromPasted(pasted, for: provider) {
                        onSignedIn(c)
                        dismiss()
                    } else {
                        pasteError = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(provider == .claude
                     ? "Paste the value of the claude.ai “sessionKey” cookie (starts with sk-ant-sid)."
                     : "Paste the chatgpt.com “__Secure-next-auth.session-token” cookie, or a Codex access token (eyJ…).")
            }
            .alert("That doesn't look like a \(provider.displayName) login.", isPresented: $pasteError) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

/// Safari's user agent for the iOS version this iPhone runs.
@MainActor
var deviceSafariUserAgent: String { safariUserAgent(iOSVersion: UIDevice.current.systemVersion) }

struct WebLogin: UIViewRepresentable {
    let provider: Provider
    let onSignedIn: (Credential) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(provider: provider, onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // "Continue with Google" opens a pop-up window on some sites.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        // Look exactly like Safari on this iPhone so sign-in pages (Google's especially) behave normally.
        webView.customUserAgent = deviceSafariUserAgent
        webView.uiDelegate = context.coordinator
        context.coordinator.start(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        let provider: Provider
        let onSignedIn: (Credential) -> Void
        private var timer: Timer?
        private var done = false
        private var popups: [WKWebView] = []

        init(provider: Provider, onSignedIn: @escaping (Credential) -> Void) {
            self.provider = provider
            self.onSignedIn = onSignedIn
        }

        // Show pop-up windows (e.g. Google sign-in) on top of the page. They must use the
        // configuration WebKit hands us so the pop-up can report back to the page.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.customUserAgent = webView.customUserAgent
            popup.uiDelegate = self
            webView.addSubview(popup)
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let i = popups.firstIndex(of: webView) else { return }
            popups.remove(at: i).removeFromSuperview()
        }

        func start(_ webView: WKWebView) {
            Task {
                // Forget any old (possibly expired) login first, so we only capture a fresh one.
                await clearCookies(for: provider)
                webView.load(URLRequest(url: provider.loginURL))
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak webView] _ in
                    Task { @MainActor in
                        guard let self, let webView else { return }
                        await self.check(webView)
                    }
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func check(_ webView: WKWebView) async {
            guard !done else { return }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix(provider.cookieDomain) }
            guard provider.isSignedIn(cookieNames: cookies.map(\.name)) else { return }
            done = true
            stop()
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            popups.forEach { $0.removeFromSuperview() }
            popups.removeAll()
            onSignedIn(Credential(cookieHeader: header, userAgent: webView.customUserAgent ?? defaultUserAgent))
        }
    }
}
#endif
