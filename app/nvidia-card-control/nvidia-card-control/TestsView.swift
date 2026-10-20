// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

struct TestsView: View {
    let driverStore: DriverStore
    @Bindable var testsStore: TestsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            if testsStore.isLoadingList && testsStore.definitions.isEmpty {
                Section {
                    ProgressView("Loading tests…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(String(localized: "Loading tests"))
                }
            } else if testsStore.definitions.isEmpty {
                ContentUnavailableView {
                    Label("No tests", systemImage: "checkmark.seal")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("Refresh") {
                        Task { await testsStore.refreshList() }
                    }
                }
            } else {
                ForEach(testsStore.groupedSections) { section in
                    Section(section.name) {
                        ForEach(section.tests) { definition in
                            TestRowView(
                                definition: definition,
                                testsStore: testsStore
                            )
                        }
                    }
                }

                Section {
                    Button("Open test pattern") {
                        openWindow(id: "stream-pattern")
                    }
                    .accessibilityHint(
                        String(localized: "Opens a full-window animated pattern for streaming encode tests")
                    )
                } header: {
                    Text("Stream pattern")
                } footer: {
                    Text("Opens a separate window with scrolling colour bars, noise, text and motion so a streaming encoder has demanding, recognisable content.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tests")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    testsStore.runAll()
                } label: {
                    if testsStore.isRunningAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run all", systemImage: "play.fill")
                    }
                }
                .disabled(
                    testsStore.isRunningAll
                        || !testsStore.runningTestIDs.isEmpty
                        || testsStore.availableDefinitions.isEmpty
                        || testsStore.isLoadingList
                )
                .help("Run every available test with its current parameters")
                .accessibilityLabel(String(localized: "Run all tests"))
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    copyReportToPasteboard()
                } label: {
                    Label("Copy report", systemImage: "doc.on.clipboard")
                }
                .disabled(testsStore.reportResults.isEmpty)
                .help("Copy a plain-text report of results to the clipboard")
                .accessibilityLabel(String(localized: "Copy report"))
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await testsStore.refreshList() }
                } label: {
                    if testsStore.isLoadingList {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(testsStore.isBusy && !testsStore.isLoadingList)
                .help("Reload the test list from nvmtlctl")
                .accessibilityLabel(String(localized: "Refresh test list"))
            }
        }
        .task {
            await testsStore.loadListIfNeeded()
        }
        .overlay(alignment: .bottom) {
            if let message = testsStore.lastErrorMessage {
                testsBanner(message: message, role: .error) {
                    testsStore.dismissError()
                }
            } else if let message = testsStore.lastNoticeMessage {
                testsBanner(message: message, role: .notice) {
                    testsStore.dismissNotice()
                }
            }
        }
    }

    private var emptyDescription: String {
        if driverStore.toolIsMissing {
            return String(
                localized: "Install nvmtlctl, then refresh. Tests come from nvmtlctl test list."
            )
        }
        if let error = testsStore.lastErrorMessage {
            return error
        }
        return String(localized: "Refresh to load tests from nvmtlctl test list.")
    }

    private func copyReportToPasteboard() {
        let status = driverStore.status
        let text = testsStore.copyReport(
            macos: status.map { "\($0.macos) (\($0.build))" } ?? "",
            gpu: status?.gpu ?? "",
            toolVersion: status?.tool ?? ""
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        testsStore.noteReportCopied()
    }

    private enum BannerRole {
        case error
        case notice
    }

    private func testsBanner(message: String, role: BannerRole, dismiss: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(
            role == .error
                ? String(localized: "Error: \(message)")
                : String(localized: "Notice: \(message)")
        )
    }
}

private struct TestRowView: View {
    let definition: TestDefinition
    @Bindable var testsStore: TestsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(definition.title)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(TestHelpers.formatEstimatedDuration(definition.estimatedSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(
                            localized: "Estimated time \(TestHelpers.formatEstimatedDuration(definition.estimatedSeconds))"
                        )
                    )
            }

            Text(definition.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !definition.available {
                Label {
                    Text(definition.unavailableReason ?? String(localized: "Unavailable"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        localized: "Unavailable: \(definition.unavailableReason ?? "Unavailable")"
                    )
                )
            }

            if definition.available && !definition.params.isEmpty {
                ForEach(definition.params) { param in
                    TestParamControl(
                        testID: definition.id,
                        spec: param,
                        testsStore: testsStore
                    )
                }
            }

            HStack {
                Button {
                    testsStore.run(testID: definition.id)
                } label: {
                    if testsStore.isRunning(definition.id) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Text("Run")
                    }
                }
                .disabled(
                    !definition.available
                        || testsStore.isRunning(definition.id)
                        || testsStore.isRunningAll
                )
                .accessibilityLabel(
                    String(localized: "Run \(definition.title)")
                )
                .accessibilityHint(
                    definition.available
                        ? String(localized: "Starts this test with the chosen parameters")
                        : String(localized: "This test is unavailable")
                )

                if definition.needsRoot {
                    Text("Asks for administrator access")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let result = testsStore.resultsByID[definition.id] {
                TestResultBlock(result: result)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct TestParamControl: View {
    let testID: String
    let spec: TestParamSpec
    @Bindable var testsStore: TestsStore
    @State private var intDraft: String = ""

    var body: some View {
        switch spec.kind {
        case .choice:
            Picker(spec.label, selection: choiceBinding) {
                ForEach(spec.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .accessibilityLabel(spec.label)

        case .int:
            HStack(alignment: .firstTextBaseline) {
                Text(spec.label)
                Spacer(minLength: 8)
                Stepper(value: intBinding, in: intRange) {
                    TextField(spec.label, text: $intDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 72)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitIntDraft() }
                        .accessibilityLabel(spec.label)
                }
            }
            .onAppear {
                intDraft = testsStore.paramValue(testID: testID, key: spec.key)
            }
        }
    }

    private var choiceBinding: Binding<String> {
        Binding(
            get: { testsStore.paramValue(testID: testID, key: spec.key) },
            set: { testsStore.setParamValue(testID: testID, key: spec.key, value: $0) }
        )
    }

    private var intRange: ClosedRange<Int> {
        let lower = spec.min ?? 0
        let upper = spec.max ?? max(lower, 1_000_000)
        return lower...upper
    }

    private var intBinding: Binding<Int> {
        Binding(
            get: {
                Int(testsStore.paramValue(testID: testID, key: spec.key)) ?? (spec.min ?? 0)
            },
            set: { newValue in
                testsStore.setIntParam(testID: testID, spec: spec, raw: newValue)
                intDraft = testsStore.paramValue(testID: testID, key: spec.key)
            }
        )
    }

    private func commitIntDraft() {
        if let parsed = Int(intDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
            testsStore.setIntParam(testID: testID, spec: spec, raw: parsed)
            intDraft = testsStore.paramValue(testID: testID, key: spec.key)
        } else {
            intDraft = testsStore.paramValue(testID: testID, key: spec.key)
        }
    }
}

private struct TestResultBlock: View {
    let result: TestRunResult
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: result.status.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(result.status.displayName)
                    .font(.body.weight(.medium))
                Text(String(format: "%.1f s", result.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                String(
                    localized: "\(result.status.displayName), \(String(format: "%.1f", result.durationSeconds)) seconds"
                )
            )

            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.metrics.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(result.metrics.keys.sorted(), id: \.self) { key in
                        GridRow {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(TestHelpers.formatMetricValue(result.metrics[key] ?? 0))
                                .font(.caption.monospacedDigit())
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(metricsAccessibilityLabel)
            }

            if let hint = result.hint, !hint.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(hint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Hint: \(hint)"))
            }

            if !result.details.isEmpty {
                DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                    Text(result.details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(String(localized: "Details"))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var metricsAccessibilityLabel: String {
        let parts = result.metrics.keys.sorted().map { key in
            "\(key) \(TestHelpers.formatMetricValue(result.metrics[key] ?? 0))"
        }
        return String(localized: "Metrics: \(parts.joined(separator: ", "))")
    }
}

#Preview {
    NavigationStack {
        TestsView(driverStore: .preview, testsStore: .preview)
    }
}
