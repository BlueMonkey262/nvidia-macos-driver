// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct StatusView: View {
    let store: DriverStore

    var body: some View {
        Form {
            if store.isRefreshing && store.status == nil {
                Section {
                    ProgressView("Loading driver status…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(String(localized: "Loading driver status"))
                }
            } else if let status = store.status {
                healthSection(status)
                overviewSection(status)
                pluginSection(status)
                encodersSection(status)
            } else if store.toolIsMissing {
                ContentUnavailableView {
                    Label("nvmtlctl not found", systemImage: "terminal")
                } description: {
                    Text("Install nvmtlctl at /usr/local/bin/nvmtlctl, or confirm the app bundle includes the nvmtlctl resource, then refresh.")
                } actions: {
                    Button("Refresh") {
                        Task { await store.refresh() }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            } else {
                ContentUnavailableView {
                    Label("Status unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(store.lastErrorMessage ?? String(localized: "Refresh to read driver status from nvmtlctl."))
                } actions: {
                    Button("Refresh") {
                        Task { await store.refresh() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isBusy)
                .help("Reload status from nvmtlctl")
                .accessibilityLabel(String(localized: "Refresh status"))
            }
        }
    }

    @ViewBuilder
    private func healthSection(_ status: DriverStatus) -> some View {
        Section("Health") {
            healthRow(
                title: String(localized: "Kexts loaded"),
                ok: status.hasLoadedKexts,
                detail: status.hasLoadedKexts ? status.kexts : String(localized: "None reported")
            )
            healthRow(
                title: String(localized: "GPU found"),
                ok: status.hasGPU,
                detail: status.hasGPU ? status.gpu : String(localized: "No NVIDIA chipset in system_profiler")
            )
            healthRow(
                title: String(localized: "Metal supported"),
                ok: status.reportsMetalSupport,
                detail: status.reportsMetalSupport ? status.metal : String(localized: "No Metal support string reported")
            )
        }
    }

    private func healthRow(title: String, ok: Bool, detail: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(ok ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(ok ? "Yes" : "No")
                    .foregroundStyle(.primary)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(ok ? "Yes" : "No"), \(detail)")
        } label: {
            Text(title)
        }
    }

    @ViewBuilder
    private func overviewSection(_ status: DriverStatus) -> some View {
        Section("Driver") {
            LabeledContent("Package", value: display(status.package))
            LabeledContent("macOS", value: "\(status.macos) (\(status.build))")
            LabeledContent("nvmtlctl", value: display(status.tool))
            LabeledContent("Boot args", value: display(status.bootArgs, empty: "None"))
            LabeledContent("Cache key", value: display(status.cacheKey))
        }
    }

    @ViewBuilder
    private func pluginSection(_ status: DriverStatus) -> some View {
        Section("Metal plugin") {
            LabeledContent("SHA-256 prefix", value: display(status.pluginSha8, empty: "Unavailable"))
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(status.pluginBytes), countStyle: .file))
        }
    }

    @ViewBuilder
    private func encodersSection(_ status: DriverStatus) -> some View {
        Section("Turing encoder libraries") {
            LabeledContent("H.264") {
                Text(yesNoLabel(status.turingH264EncoderLib))
                    .accessibilityLabel(String(localized: "H.264 encoder library \(yesNoLabel(status.turingH264EncoderLib))"))
            }
            LabeledContent("HEVC") {
                Text(yesNoLabel(status.turingHevcEncoderLib))
                    .accessibilityLabel(String(localized: "HEVC encoder library \(yesNoLabel(status.turingHevcEncoderLib))"))
            }
        }
    }

    private func display(_ value: String, empty: String = "—") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? empty : trimmed
    }

    private func yesNoLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "yes": return String(localized: "Present")
        case "no": return String(localized: "Missing")
        default: return raw
        }
    }
}

#Preview {
    NavigationStack {
        StatusView(store: .preview)
    }
}
