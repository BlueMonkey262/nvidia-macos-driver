// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// Sunshine page: Pointer section is live; Service / Display / Encoding remain mockups.
struct SunshineView: View {
    let store: DriverStore
    @State private var pointerHelper = PointerHelperStore()

    @State private var startAtLogin = true
    @State private var captureDisplay = "Display 2 (mirrored, 1920 × 1080)"
    @State private var mirrorDisplays = true
    @State private var codec = "Automatic"
    @State private var bitrateCap = 40.0
    @State private var retryEncoderStart = true

    private let displays = [
        "Display 1 (built-in, 1920 × 1080)",
        "Display 2 (mirrored, 1920 × 1080)",
        "GeForce RTX 2060 SUPER (headless, 1920 × 1080)",
    ]

    var body: some View {
        Form {
            Section("Service") {
                mockBanner
                LabeledContent("Sunshine") {
                    Label("Running", systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                LabeledContent("Version", value: "2025.924.154138")
                Toggle("Start at login", isOn: $startAtLogin)
                HStack {
                    Button("Restart") {}
                    Button("Stop") {}
                    Spacer()
                    Button("Open Web UI…") {}
                }
            }

            Section {
                mockBanner
                Picker("Capture display", selection: $captureDisplay) {
                    ForEach(displays, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Mirror displays", isOn: $mirrorDisplays)
            } header: {
                Text("Display")
            } footer: {
                Text("Sunshine streams the display you pick. Mirroring keeps the stream matching what the GPU renders.")
            }

            Section {
                mockBanner
                LabeledContent("Encoder", value: "VideoToolbox (hardware)")
                Picker("Codec", selection: $codec) {
                    Text("Automatic").tag("Automatic")
                    Text("H.264").tag("H.264")
                    Text("HEVC").tag("HEVC")
                }
                LabeledContent("Bitrate limit") {
                    HStack {
                        Slider(value: $bitrateCap, in: 5...150, step: 5)
                            .frame(maxWidth: 220)
                        Text("\(Int(bitrateCap)) Mbit/s")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .trailing)
                    }
                }
                Toggle("Retry when the encoder is busy", isOn: $retryEncoderStart)
            } header: {
                Text("Encoding")
            } footer: {
                Text("The hardware encoder opens one session at a time. Retrying avoids a failed stream start when a second session overlaps.")
            }

            Section {
                Toggle(
                    "Keep the pointer visible while typing",
                    isOn: Binding(
                        get: { pointerHelper.keepPointerVisibleWhileTyping },
                        set: { newValue in
                            Task { await pointerHelper.setEnabled(newValue) }
                        }
                    )
                )
                .disabled(pointerHelper.isBusy)

                LabeledContent("Helper") {
                    Label(pointerHelper.status.label, systemImage: pointerHelper.status.systemImage)
                        .foregroundStyle(helperForeground)
                }

                if case .needsAccessibility = pointerHelper.status {
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(pointerHelper.privacySettingsURL)
                    }
                }

                if let message = pointerHelper.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("macOS hides the pointer while you type and Sunshine moves it without bringing it back. The helper shows it again.")
            }

            Section("Troubleshooting") {
                mockBanner
                Button("Open Sunshine log") {}
                Button("Reset Sunshine settings…", role: .destructive) {}
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sunshine")
        .task {
            await pointerHelper.loadIfNeeded()
        }
    }

    private var mockBanner: some View {
        Label("Preview only: these controls are not connected to Sunshine yet.", systemImage: "hammer")
            .foregroundStyle(.secondary)
    }

    private var helperForeground: Color {
        switch pointerHelper.status {
        case .installedAndRunning:
            return .primary
        case .needsAccessibility, .error:
            return .secondary
        case .notInstalled:
            return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        SunshineView(store: .preview)
    }
}
