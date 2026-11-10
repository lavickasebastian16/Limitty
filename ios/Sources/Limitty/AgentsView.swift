#if os(iOS)
import SwiftUI
import LimittyCore

/// "Agents on your PC": what Claude Code, Codex and Antigravity are doing right now.
struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var showGitHub: Bool

    var body: some View {
        Section {
            if !model.agentsConnected {
                Button {
                    showGitHub = true
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                if let gh = model.github, gh.gistId == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in as @\(gh.login). Now connect your PC:").font(.subheadline)
                        Text("In the Limitty desktop app, press **Install agents** (or Settings → iPhone → **Link iPhone…**) and approve with the same GitHub account.")
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
#endif
