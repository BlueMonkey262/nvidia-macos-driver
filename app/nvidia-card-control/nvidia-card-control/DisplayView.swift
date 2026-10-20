// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct DisplayView: View {
    let store: AppStore
    @State private var confirmClearCaches = false
    @State private var confirmRestartDesktop = false

    var body: some View {
        Form {
            Section {
                ConfFlagToggle(
                    title: "Framebuffer fetch for WindowServer",
                    key: ConfKey.framebufferFetchWS,
                    store: store
                )
            } header: {
                Text("Framebuffer")
            } footer: {
                RestartRequirementFooter(kind: .desktop)
            }

            Section("Icon caches") {
                if let caches = store.cachesStatus {
                    LabeledContent("Caches present", value: "\(caches.count)")
                        .accessibilityLabel(String(localized: "\(caches.count) icon caches present"))
                    if !caches.paths.isEmpty {
                        DisclosureGroup("Paths") {
                            ForEach(caches.paths, id: \.self) { path in
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Text("Cache status has not been loaded yet.")
                        .foregroundStyle(.secondary)
                }

                Text("Icon caches can go stale after a macOS or driver change. Clearing them removes disposable icon data that macOS rebuilds on demand. The first rebuild after clearing can take several minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Clear icon caches", role: .destructive) {
                    confirmClearCaches = true
                }
                .disabled(store.isBusy)
                .accessibilityHint(String(localized: "Asks for administrator access, then removes system icon caches"))

                if store.busyAction == .clearCaches {
                    ProgressView("Clearing icon caches…")
                }
            }

            Section("Desktop session") {
                Text("Restarting the desktop ends your current login session and brings WindowServer back. Unsaved work in other apps may be lost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Restart the desktop", role: .destructive) {
                    confirmRestartDesktop = true
                }
                .disabled(store.isBusy)
                .accessibilityHint(String(localized: "Ends the current desktop session after confirmation"))

                if store.busyAction == .restartDesktop {
                    ProgressView("Requesting desktop restart…")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Display")
        .confirmationDialog(
            "Clear icon caches?",
            isPresented: $confirmClearCaches,
            titleVisibility: .visible
        ) {
            Button("Clear icon caches", role: .destructive) {
                Task { await store.clearCaches() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes system icon caches. Icons rebuild at the next login or restart; the first rebuild can be slow.")
        }
        .confirmationDialog(
            "Restart the desktop?",
            isPresented: $confirmRestartDesktop,
            titleVisibility: .visible
        ) {
            Button("Restart the desktop", role: .destructive) {
                Task { await store.restartDesktop() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your desktop session will end and come back. Save your work first.")
        }
    }
}

#Preview {
    NavigationStack {
        DisplayView(store: .preview)
    }
}
