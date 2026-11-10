#if os(iOS)
import SwiftUI
import LimittyCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginFor: Provider?
    @State private var showPair = false
    @State private var showAlerts = false

    var body: some View {
        NavigationStack {
            List {
                AgentsSection(showPair: $showPair, showAlerts: $showAlerts)

                if !model.store.isShared {
                    Section {
                        Label("The widget can't read your logins because the shared App Group is missing. Reinstall with `xtool dev`.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                    }
                }

                ForEach(Provider.allCases) { provider in
                    Section {
                        if model.signedIn.contains(provider) {
                            signedInRows(provider)
                        } else {
                            Button {
                                loginFor = provider
                            } label: {
                                Label(provider.usesGoogleOAuth ? "Sign in with Google" : "Sign in to \(provider.displayName)",
                                      systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(provider.color).frame(width: 8, height: 8)
                            Text(provider.usesGoogleOAuth ? "Gemini · Antigravity" : provider.displayName)
                        }
                    } footer: {
                        if provider.usesGoogleOAuth {
                            Text(model.store.credential(for: provider)?.email.map { "Signed in as \($0)." } ?? "Gemini Pro, Gemini Flash and Claude + GPT quotas, as in agy's /usage.")
                        }
                    }
                }

                Section("Widget") {
                    Text("Long-press your Home Screen, tap Edit → Add Widget, and choose **Limitty**. Lock Screen widgets are available too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Limitty")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.refreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task {
                                async let limits: Void = model.refresh()
                                async let agents: Void = model.refreshAgents()
                                _ = await (limits, agents)
                            }
                        } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(model.signedIn.isEmpty && model.pairing == nil)
                    }
                }
            }
            .refreshable {
                async let limits: Void = model.refresh()
                async let agents: Void = model.refreshAgents()
                _ = await (limits, agents)
            }
            .sheet(item: $loginFor) { provider in
                if provider.usesGoogleOAuth {
                    GoogleLoginView { credential in model.save(credential, for: provider) }
                } else {
                    LoginView(provider: provider) { credential in
                        model.save(credential, for: provider)
                    }
                }
            }
            .sheet(isPresented: $showPair) { PairView() }
            .sheet(isPresented: $showAlerts) { AlertsSetupView() }
            .task { await model.refresh() }
            .task(id: scenePhase) {
                // Keep agent status fresh while the app is open.
                while scenePhase == .active && !Task.isCancelled {
                    await model.refreshAgents()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .onOpenURL { model.handle($0) }
        }
    }

    @ViewBuilder
    private func signedInRows(_ provider: Provider) -> some View {
        if let snap = model.snapshots[provider] {
            if snap.ok {
                if snap.plan != nil || snap.stale {
                    ProviderHeader(snap)
                }
                ForEach(snap.windows) { window in
                    WindowRow(window).padding(.vertical, 2)
                }
            } else {
                ErrorLine(snap)
                Button("Sign in again") { loginFor = provider }
            }
        } else {
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        }
        Button("Sign out", role: .destructive) { model.signOut(provider) }
            .font(.footnote)
    }
}
#endif
