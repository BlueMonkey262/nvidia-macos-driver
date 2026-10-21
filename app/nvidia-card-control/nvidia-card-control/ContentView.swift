// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct ContentView: View {
    @Bindable var store: DriverStore
    @State private var testsStore = TestsStore()
    @State private var selection: SidebarCategory? = .status

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 520)
        .task {
            await store.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gpuControlSelectSidebarCategory)) { note in
            if let category = note.object as? SidebarCategory {
                selection = category
            }
        }
        .overlay(alignment: .bottom) {
            if let message = store.lastErrorMessage {
                banner(
                    message: message,
                    role: .error,
                    dismiss: { store.dismissError() }
                )
            } else if let message = store.lastNoticeMessage {
                banner(
                    message: message,
                    role: .notice,
                    dismiss: { store.dismissNotice() }
                )
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .status {
        case .status:
            StatusView(store: store)
        case .display:
            DisplayView(store: store)
        case .video:
            VideoView(store: store)
        case .sunshine:
            SunshineView(store: store)
        case .performance:
            PerformanceView(store: store)
        case .tests:
            TestsView(driverStore: store, testsStore: testsStore)
        case .logs:
            LogsView(store: store)
        case .about:
            AboutView(store: store)
        }
    }

    private enum BannerRole {
        case error
        case notice
    }

    private func banner(message: String, role: BannerRole, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: role == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(role == .error ? String(localized: "Error: \(message)") : String(localized: "Notice: \(message)"))
    }
}

#Preview {
    ContentView(store: .preview)
}
