// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// Sunshine page: Service, Display, Encoding, Pointer and Troubleshooting are all live.
struct SunshineView: View {
    let store: DriverStore
    @State private var sunshine = SunshineStore()
    @State private var confirmReset = false
    @State private var sunshineNameDraft = ""
    @State private var fecDraft: Double = 20
    @State private var portDraft: Double = 47989

    @State private var pointerHelper = PointerHelperStore()

    var body: some View {
        Form {
            serviceSection
            displaySection
            encodingSection

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
                Text("macOS hides the pointer while you type, and a streamed mouse move does not bring it back. After you stop typing, the helper briefly opens a small GPU Control app, which makes macOS show the pointer again. You may see its icon in the Dock for a moment. Updating the helper asks for Accessibility access again.")
            }

            troubleshootingSection
        }
        .formStyle(.grouped)
        .navigationTitle("Sunshine")
        .task {
            await pointerHelper.loadIfNeeded()
            await sunshine.loadIfNeeded()
            sunshineNameDraft = sunshine.sunshineName
            fecDraft = Double(sunshine.fecPercentage)
            portDraft = Double(sunshine.port)
        }
        .onDisappear {
            sunshine.stopPolling()
        }
        .alert("Reset Sunshine settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task { await sunshine.resetSettings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This backs up and removes only sunshine.conf. Credentials and pairing state are left alone.")
        }
    }

    // MARK: - Service

    @ViewBuilder
    private var serviceSection: some View {
        Section("Service") {
            LabeledContent("Sunshine") {
                if sunshine.isRunning {
                    Label("Running", systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(String(localized: "Sunshine is running"))
                } else {
                    Label("Stopped", systemImage: "circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "Sunshine is stopped"))
                }
            }

            LabeledContent("Version", value: sunshine.version ?? String(localized: "Not installed"))

            Toggle(
                "Start at login",
                isOn: Binding(
                    get: { sunshine.startAtLogin },
                    set: { newValue in
                        Task { await sunshine.setStartAtLogin(newValue) }
                    }
                )
            )
            .disabled(sunshine.isBusy)
            .accessibilityHint(String(localized: "Installs a user LaunchAgent that starts Sunshine when you log in"))

            if sunshine.userLocalLoginAgentPresent {
                Text("Your LaunchAgent com.local.sunshine-login is also installed. GPU Control will not change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(localized: "Your LaunchAgent com.local.sunshine-login is also installed"))
            }

            HStack {
                if sunshine.isRunning {
                    Button("Restart") {
                        Task { await sunshine.restart() }
                    }
                    .disabled(sunshine.isBusy)
                    Button("Stop") {
                        Task { await sunshine.stop() }
                    }
                    .disabled(sunshine.isBusy)
                } else {
                    Button("Start") {
                        Task { await sunshine.start() }
                    }
                    .disabled(sunshine.isBusy)
                }
                Spacer()
                Button("Open Web UI…") {
                    sunshine.openWebUI()
                }
                .accessibilityHint(String(localized: "Opens the Sunshine web interface at https://localhost:47990"))
            }

            if sunshine.needsRestart {
                HStack {
                    Text("Restart Sunshine to apply")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart") {
                        Task { await sunshine.restart() }
                    }
                    .disabled(sunshine.isBusy)
                    .accessibilityLabel(String(localized: "Restart Sunshine to apply settings"))
                }
            }

            if let message = sunshine.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Display

    @ViewBuilder
    private var displaySection: some View {
        Section {
            if sunshine.displays.count <= 1 {
                Text("Only one display connected")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Only one display connected"))
            } else {
                Picker(
                    "Capture display",
                    selection: Binding(
                        get: { sunshine.capturePickerSelection },
                        set: { newValue in
                            Task {
                                if newValue == sunshine.mainDisplayPickerID {
                                    await sunshine.selectMainDisplay()
                                } else if let info = sunshine.displays.first(where: { String($0.id) == newValue }) {
                                    await sunshine.selectDisplay(info)
                                }
                            }
                        }
                    )
                ) {
                    Text("Use the main display (default)")
                        .tag(sunshine.mainDisplayPickerID)
                    ForEach(sunshine.displays) { display in
                        Text(display.pickerLabel).tag(String(display.id))
                    }
                }
                .disabled(sunshine.isBusy)

                Text(SunshineOptionSpec.outputNameDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Mirror displays",
                    isOn: Binding(
                        get: { sunshine.displayChoice.mirrorEnabled },
                        set: { newValue in
                            Task { await sunshine.setMirrorEnabled(newValue) }
                        }
                    )
                )
                .disabled(sunshine.isBusy)
                .accessibilityHint(String(localized: "Mirrors other displays onto the capture display for this login session"))

                if sunshine.mirrorActive || sunshine.displayChoice.mirrorEnabled {
                    Button("Stop mirroring") {
                        Task { await sunshine.setMirrorEnabled(false) }
                    }
                    .disabled(sunshine.isBusy)
                    .accessibilityLabel(String(localized: "Stop mirroring displays"))
                }
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Sunshine streams the display you pick. Display IDs change every boot, so GPU Control matches by name and size.")
        }
    }

    // MARK: - Encoding

    @ViewBuilder
    private var encodingSection: some View {
        Section {
            encodingRow(
                title: "Encoder",
                description: SunshineOptionSpec.encoderDescription,
                isDefault: sunshine.encoder == SunshineOptionSpec.defaultEncoder,
                onReset: { Task { await sunshine.resetEncoder() } }
            ) {
                Picker(
                    "Encoder",
                    selection: Binding(
                        get: {
                            sunshine.encoder.isEmpty ? SunshineOptionSpec.defaultEncoder : sunshine.encoder
                        },
                        set: { newValue in
                            Task { await sunshine.setEncoder(newValue) }
                        }
                    )
                ) {
                    ForEach(SunshineOptionSpec.encoders, id: \.value) { item in
                        Text(item.title).tag(item.value)
                    }
                }
                .labelsHidden()
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "HEVC support",
                description: SunshineOptionSpec.hevcModeDescription,
                isDefault: sunshine.hevcMode == SunshineOptionSpec.defaultHevcMode,
                onReset: { Task { await sunshine.resetHevcMode() } }
            ) {
                Picker(
                    "HEVC support",
                    selection: Binding(
                        get: { sunshine.hevcMode },
                        set: { newValue in Task { await sunshine.setHevcMode(newValue) } }
                    )
                ) {
                    ForEach(SunshineOptionSpec.hevcModes, id: \.value) { item in
                        Text(item.title).tag(item.value)
                    }
                }
                .labelsHidden()
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "AV1 support",
                description: SunshineOptionSpec.av1ModeDescription,
                isDefault: sunshine.av1Mode == SunshineOptionSpec.defaultAv1Mode,
                onReset: { Task { await sunshine.resetAv1Mode() } }
            ) {
                Picker(
                    "AV1 support",
                    selection: Binding(
                        get: { sunshine.av1Mode },
                        set: { newValue in Task { await sunshine.setAv1Mode(newValue) } }
                    )
                ) {
                    ForEach(SunshineOptionSpec.av1Modes, id: \.value) { item in
                        Text(item.title).tag(item.value)
                    }
                }
                .labelsHidden()
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "FEC percentage",
                description: SunshineOptionSpec.fecPercentageDescription,
                isDefault: sunshine.fecPercentage == SunshineOptionSpec.defaultFecPercentage,
                onReset: {
                    fecDraft = Double(SunshineOptionSpec.defaultFecPercentage)
                    Task { await sunshine.resetFecPercentage() }
                }
            ) {
                HStack {
                    Slider(
                        value: $fecDraft,
                        in: 1...255,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing {
                                Task { await sunshine.setFecPercentage(Int(fecDraft)) }
                            }
                        }
                    )
                    .frame(maxWidth: 220)
                    .disabled(sunshine.isBusy)
                    Text("\(Int(fecDraft))")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityLabel(String(localized: "FEC percentage \(Int(fecDraft))"))
                }
            }

            encodingRow(
                title: "Sunshine name",
                description: SunshineOptionSpec.sunshineNameDescription,
                isDefault: sunshine.sunshineName.isEmpty,
                onReset: {
                    sunshineNameDraft = ""
                    Task { await sunshine.resetSunshineName() }
                }
            ) {
                TextField(
                    "Hostname default",
                    text: $sunshineNameDraft
                )
                .onSubmit {
                    Task { await sunshine.setSunshineName(sunshineNameDraft) }
                }
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "Log level",
                description: SunshineOptionSpec.minLogLevelDescription,
                isDefault: sunshine.minLogLevel == SunshineOptionSpec.defaultMinLogLevel,
                onReset: { Task { await sunshine.resetMinLogLevel() } }
            ) {
                Picker(
                    "Log level",
                    selection: Binding(
                        get: { sunshine.minLogLevel },
                        set: { newValue in Task { await sunshine.setMinLogLevel(newValue) } }
                    )
                ) {
                    ForEach(SunshineOptionSpec.logLevels, id: \.value) { item in
                        Text(item.title).tag(item.value)
                    }
                }
                .labelsHidden()
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "UPnP",
                description: SunshineOptionSpec.upnpDescription,
                isDefault: !sunshine.upnpEnabled,
                onReset: { Task { await sunshine.resetUpnp() } }
            ) {
                Toggle(
                    "UPnP",
                    isOn: Binding(
                        get: { sunshine.upnpEnabled },
                        set: { newValue in Task { await sunshine.setUpnpEnabled(newValue) } }
                    )
                )
                .labelsHidden()
                .disabled(sunshine.isBusy)
            }

            encodingRow(
                title: "Port",
                description: SunshineOptionSpec.portDescription,
                isDefault: sunshine.port == SunshineOptionSpec.defaultPort,
                onReset: {
                    portDraft = Double(SunshineOptionSpec.defaultPort)
                    Task { await sunshine.resetPort() }
                }
            ) {
                HStack {
                    TextField(
                        "Port",
                        value: $portDraft,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(maxWidth: 100)
                    .onSubmit {
                        Task { await sunshine.setPort(Int(portDraft)) }
                    }
                    .disabled(sunshine.isBusy)
                    Text("1024…65535")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // TODO: "Retry when the encoder is busy" belongs to the GPU driver (nvmtlctl), not Sunshine.
            // Re-home that control on the Video page when the driver knob is ready.

            if let status = store.status {
                LabeledContent("Driver H.264 encoder", value: status.turingH264EncoderLib)
                LabeledContent("Driver HEVC encoder", value: status.turingHevcEncoderLib)
                Button("Open Video settings…") {
                    NotificationCenter.default.post(name: .gpuControlSelectSidebarCategory, object: SidebarCategory.video)
                }
                .accessibilityHint(String(localized: "Switches the sidebar to the Video page for hardware encode options"))
            }
        } header: {
            Text("Encoding")
        } footer: {
            Text("Bitrate is chosen by the Moonlight client; Sunshine has no bitrate-limit setting.")
        }
    }

    // MARK: - Troubleshooting

    @ViewBuilder
    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            if let line = sunshine.lastLogErrorLine {
                VStack(alignment: .leading, spacing: 4) {
                    if let stamp = sunshine.lastLogErrorTimestamp, !stamp.isEmpty {
                        Text(stamp)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(String(localized: "Error time \(stamp)"))
                    }
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(String(localized: "Last Sunshine error: \(line)"))
                }
            } else {
                Text("No error lines in the current Sunshine log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Sunshine log") {
                sunshine.openLog()
            }
            Button("Reveal settings file") {
                sunshine.revealSettingsFile()
            }
            Button("Reset Sunshine settings…", role: .destructive) {
                confirmReset = true
            }
            .disabled(sunshine.isBusy)
        }
    }

    @ViewBuilder
    private func encodingRow<Content: View>(
        title: LocalizedStringKey,
        description: String,
        isDefault: Bool,
        onReset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                content()
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(String(localized: "Description: \(description)"))
            Button("Reset") {
                onReset()
            }
            .disabled(sunshine.isBusy || isDefault)
            .accessibilityHint(String(localized: "Restore the Sunshine default for this setting"))
        }
    }

    private var helperForeground: Color {
        switch pointerHelper.status {
        case .installedAndRunning:
            return .primary
        case .needsAccessibility, .error, .notInstalled:
            return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        SunshineView(store: .preview)
    }
}
