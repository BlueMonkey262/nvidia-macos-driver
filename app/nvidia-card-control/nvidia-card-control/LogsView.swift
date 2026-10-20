// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

struct LogsView: View {
    let store: DriverStore
    @State private var lastCollectedFolder: URL?

    var body: some View {
        Form {
            Section("Collect diagnostics") {
                Text("Gather driver status, configuration, recent system log lines and related files into a folder on this Mac. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Choose folder…") {
                        Task { await collectChoosingFolder() }
                    }
                    .disabled(store.isBusy)
                    .accessibilityHint(String(localized: "Pick a folder, then run nvmtlctl logs"))

                    Button("Collect on Desktop") {
                        Task { await collectOnDesktop() }
                    }
                    .disabled(store.isBusy)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(String(localized: "Write logs under the Desktop folder"))
                }

                if store.busyAction == .collectLogs {
                    ProgressView("Collecting logs…")
                        .accessibilityLabel(String(localized: "Collecting logs"))
                }

                if let lastCollectedFolder {
                    LabeledContent("Last collection") {
                        Text(lastCollectedFolder.path)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([lastCollectedFolder])
                    }
                    .accessibilityLabel(String(localized: "Reveal collected logs in Finder"))
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Review the folder before sharing it. Paths include your user name and GPU state.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Logs")
    }

    private func collectOnDesktop() async {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let folderName = "nvmtl-logs-\(Self.timestampFormatter.string(from: Date()))"
        let destination = desktop.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            // nvmtlctl also creates the directory; continue and let the tool report failure if needed.
        }
        if let url = await store.collectLogs(into: destination) {
            lastCollectedFolder = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func collectChoosingFolder() async {
        guard let chosen = await pickDirectory() else { return }
        let folderName = "nvmtl-logs-\(Self.timestampFormatter.string(from: Date()))"
        let destination = chosen.appendingPathComponent(folderName, isDirectory: true)
        if let url = await store.collectLogs(into: destination) {
            lastCollectedFolder = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @MainActor
    private func pickDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for nvmtlctl logs")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

#Preview {
    NavigationStack {
        LogsView(store: .preview)
    }
}
