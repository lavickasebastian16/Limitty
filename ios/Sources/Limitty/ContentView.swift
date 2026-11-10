#if os(iOS)
import SwiftUI
import LimittyCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginFor: Provider?

    var body: some View {
        NavigationStack {
            List {
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
                                Label("Sign in to \(provider.displayName)", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(provider.color).frame(width: 8, height: 8)
                            Text(provider.displayName)
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
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(model.signedIn.isEmpty)
                    }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $loginFor) { provider in
                LoginView(provider: provider) { credential in
                    model.save(credential, for: provider)
                }
            }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
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
