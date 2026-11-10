#if os(iOS)
import SwiftUI
import LimittyCore

/// "Agents on your PC": what Claude Code, Codex and Antigravity are doing right now.
struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var showPair: Bool
    @Binding var showAlerts: Bool

    var body: some View {
        Section {
            if model.pairing == nil {
                Button {
                    showPair = true
                } label: {
                    Label("Pair with your PC", systemImage: "desktopcomputer")
                }
            } else {
                if let status = model.agentStatus {
                    pcRow(status)
                    if status.sessions.isEmpty {
                        Text("No agent sessions right now").foregroundStyle(.secondary).font(.footnote)
                    }
                    ForEach(status.sessions, id: \.key) { AgentRow($0).padding(.vertical, 2) }
                } else if model.agentError == nil {
                    HStack {
                        ProgressView()
                        Text("Waiting for your PC… make sure `npm run agent` is running there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = model.agentError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button { showAlerts = true } label: {
                    Label("Get alerts on this iPhone", systemImage: "bell.badge")
                }
                .font(.footnote)
            }
        } header: {
            Text("Agents on your PC")
        } footer: {
            if model.pairing != nil {
                Text("Updates every 15 s while Limitty is open. “Maybe waiting” means a tool has been running a while: it may be waiting for your approval.")
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
                    Text("npm install\nnpm run agent:setup").font(.system(.body, design: .monospaced))
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
                if let p = model.pairing {
                    Section("Steps") {
                        Button("1. Install ntfy from the App Store") {
                            openURL(URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("2. In ntfy, tap **+** and subscribe to this topic:")
                            Text(p.alertsTopic).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy topic") {
                                UIPasteboard.general.string = p.alertsTopic
                                copied = true
                            }
                            .buttonStyle(.bordered)
                        }
                        if p.server != "https://ntfy.sh" {
                            Text("Use server \(p.server) (tap “Use another server” in ntfy).").font(.footnote)
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
