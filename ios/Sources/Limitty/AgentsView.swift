#if os(iOS)
import SwiftUI
import LimittyCore

/// "Agents on your PC": what Claude Code, Codex and Antigravity are doing right now.
struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var showPair: Bool
    @Binding var showAlerts: Bool
    @Binding var showGitHub: Bool

    var body: some View {
        Section {
            if !model.agentsConnected {
                Button {
                    showGitHub = true
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button("Pair with a QR code instead") { showPair = true }
                    .font(.footnote)
            } else {
                if let gh = model.github, gh.gistId == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in as @\(gh.login). Now connect your PC:").font(.subheadline)
                        Text("In the Limitty desktop app, open the menu (⋯) → **Connect agents to iPhone…** and sign in with the same GitHub account. Or run `npm run agent:setup`.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let status = model.agentStatus {
                    pcRow(status)
                    if status.sessions.isEmpty {
                        Text("No agent sessions right now").foregroundStyle(.secondary).font(.footnote)
                    }
                    ForEach(status.sessions, id: \.key) { AgentRow($0).padding(.vertical, 2) }
                } else if model.agentError == nil {
                    HStack {
                        ProgressView()
                        Text("Waiting for your PC… keep Limitty open there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = model.agentError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if model.alertsTopic != nil {
                    Button { showAlerts = true } label: {
                        Label("Get alerts on this iPhone", systemImage: "bell.badge")
                    }
                    .font(.footnote)
                }
            }
        } header: {
            HStack {
                Text("Agents on your PC")
                Spacer()
                if model.agentsConnected {
                    Menu {
                        if let gh = model.github {
                            Text("GitHub: @\(gh.login)")
                            Button("Sign out of GitHub", role: .destructive) { model.disconnectGitHub() }
                        }
                        if model.pairing != nil {
                            Button("Unpair QR-code PC", role: .destructive) { model.unpair() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .textCase(nil)
                }
            }
        } footer: {
            if model.agentsConnected {
                Text("Updates every 15 s while Limitty is open. “Maybe waiting” means a tool has been running a while: it may be waiting for your approval.")
            } else {
                Text("See whether Claude Code, Codex and Antigravity on your PC are working, need you, or are idle. Sign in with the same GitHub account here and on your PC.")
            }
        }
    }

    private func pcRow(_ status: AgentStatus) -> some View {
        let online = status.pcOnline()
        return HStack {
            Image(systemName: online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .foregroundStyle(online ? Color.secondary : Color.orange)
            Text(status.host).font(.subheadline.weight(.medium))
            Spacer()
            Group {
                if online {
                    Text(status.summary)
                } else {
                    Text("offline · last seen ") + Text(status.sentDate, style: .relative) + Text(" ago")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// GitHub device sign-in: shows a short code to enter on github.com.
struct GitHubLoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: GitHubAuth.DeviceCode?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 44)).foregroundStyle(.tint)
                if let code {
                    VStack(spacing: 8) {
                        Text("Enter this code on GitHub").font(.headline)
                        Text(code.userCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = code.userCode
                        openURL(code.verificationURL)
                    } label: {
                        Label("Copy code & open GitHub", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve it…").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Try again") { attempt += 1 }.buttonStyle(.bordered)
                } else {
                    ProgressView()
                }
                Spacer()
                Text("Use the same GitHub account on your PC. Limitty only asks for access to your Gists, where your PC stores agent status privately.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle("Sign in with GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: attempt) { await signIn() }
        }
    }

    private func signIn() async {
        code = nil
        error = nil
        do {
            let c = try await GitHubAuth.start()
            code = c
            let token = try await GitHubAuth.waitForToken(c)
            let feed = GitHubStatusFeed()
            let login = try await feed.login(token: token)
            let gist = (try? await feed.findGist(token: token)) ?? nil
            model.connectGitHub(GitHubAccount(token: token, login: login, gistId: gist))
            dismiss()
        } catch is CancellationError {
            return
        } catch let e as LimitError {
            code = nil
            error = [e.message, e.hint].compactMap { $0 }.joined(separator: "\n")
        } catch {
            code = nil
            self.error = error.localizedDescription
        }
    }
}

struct PairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section("1. On your PC") {
                    Text("In the Limitty folder, run:")
                    Text("npm install\nnpm run agent:setup -- --qr").font(.system(.body, design: .monospaced))
                    Text("That installs small hooks for Claude Code, Codex and agy, starts the relay at login, and shows a QR code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2. On this iPhone") {
                    Text("Scan the QR code with the **Camera** app; it opens Limitty and pairs automatically. Or paste the `limitty://pair…` link:")
                    TextField("limitty://pair?…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Button("Paste from clipboard") { link = UIPasteboard.general.string ?? "" }
                }
                if model.pairing != nil {
                    Section {
                        Button("Unpair this PC", role: .destructive) {
                            model.unpair()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Pair with your PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        if let p = AgentPairing.parse(link) {
                            model.pair(p)
                            dismiss()
                        } else {
                            invalid = true
                        }
                    }
                    .disabled(link.isEmpty)
                }
            }
            .alert("That isn't a Limitty pairing link.", isPresented: $invalid) { Button("OK", role: .cancel) {} }
        }
    }
}

struct AlertsSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Push alerts come through **ntfy**, a free notification app. Without a paid Apple developer account, Limitty can't send pushes itself.")
                }
                if let topic = model.alertsTopic {
                    Section("Steps") {
                        Button("1. Install ntfy from the App Store") {
                            openURL(URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("2. In ntfy, tap **+** and subscribe to this topic:")
                            Text(topic).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy topic") {
                                UIPasteboard.general.string = topic
                                copied = true
                            }
                            .buttonStyle(.bordered)
                        }
                        if model.alertsServer != "https://ntfy.sh" {
                            Text("Use server \(model.alertsServer) (tap “Use another server” in ntfy).").font(.footnote)
                        }
                        Text("3. Allow notifications. Run `node src/agents/cli.js test` on your PC to send a test alert.")
                    }
                    Section {
                        Text("You'll get an alert when an agent needs you (a permission prompt or question) and when it finishes. Tapping one opens Limitty. Alerts aren't encrypted; turn off project names with `\"showProjectNames\": false` in ~/.limitty/agent.json.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
