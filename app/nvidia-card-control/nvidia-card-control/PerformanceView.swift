// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct PerformanceView: View {
    let store: DriverStore
    @State private var headroomDraft: String = ""
    @State private var headroomError: String?

    var body: some View {
        Form {
            Section("Command pools") {
                ConfSettingChrome(
                    entry: store.entry(for: ConfKey.poolKeep),
                    fallbackKey: ConfKey.poolKeep,
                    isBusy: store.isBusy,
                    onReset: {
                        Task { await store.unsetConf(key: ConfKey.poolKeep) }
                    }
                ) {
                    Stepper(value: poolKeepBinding, in: 0...256) {
                        LabeledContent("Pools kept per process") {
                            Text("\(poolKeepValue)")
                                .monospacedDigit()
                                .accessibilityLabel(String(localized: "\(poolKeepValue) pools kept"))
                        }
                    }
                    .disabled(store.isBusy || store.entry(for: ConfKey.poolKeep) == nil)
                }
            }

            Section {
                ConfFlagToggle(
                    title: "Async texture upload",
                    key: ConfKey.asyncTexUpload,
                    store: store
                )

                ConfSettingChrome(
                    entry: store.entry(for: ConfKey.vramHeadroomMB),
                    fallbackKey: ConfKey.vramHeadroomMB,
                    isBusy: store.isBusy,
                    onReset: {
                        Task { await store.unsetConf(key: ConfKey.vramHeadroomMB) }
                        syncHeadroomDraft()
                    }
                ) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("VRAM headroom")
                        Spacer()
                        TextField("Megabytes", text: $headroomDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .multilineTextAlignment(.trailing)
                            .disabled(store.isBusy)
                            .onSubmit { commitHeadroom() }
                            .accessibilityLabel(String(localized: "VRAM headroom in megabytes"))
                        Text("MB")
                            .foregroundStyle(.secondary)
                        Button("Apply") {
                            commitHeadroom()
                        }
                        .disabled(store.isBusy || !headroomDraftChanged)
                        .keyboardShortcut(.defaultAction)
                    }
                    if let headroomError {
                        Text(headroomError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Textures and memory")
            } footer: {
                RestartRequirementFooter(kind: .appLaunch)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Performance")
        .onAppear(perform: syncHeadroomDraft)
        .onChange(of: store.confEntries) { _, _ in
            syncHeadroomDraft()
        }
    }

    private var poolKeepValue: Int {
        Int(store.entry(for: ConfKey.poolKeep)?.value ?? "16") ?? 16
    }

    private var poolKeepBinding: Binding<Int> {
        Binding(
            get: { poolKeepValue },
            set: { newValue in
                Task { await store.setPoolKeep(newValue) }
            }
        )
    }

    private var headroomDraftChanged: Bool {
        headroomDraft != (store.entry(for: ConfKey.vramHeadroomMB)?.value ?? "")
    }

    private func syncHeadroomDraft() {
        headroomDraft = store.entry(for: ConfKey.vramHeadroomMB)?.value ?? ""
        headroomError = nil
    }

    private func commitHeadroom() {
        let trimmed = headroomDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConfKey.isValidConfValue(trimmed) else {
            headroomError = String(
                localized: "Enter a value using letters, digits, underscore, period or hyphen only."
            )
            return
        }
        headroomError = nil
        Task { await store.setConf(key: ConfKey.vramHeadroomMB, value: trimmed) }
    }
}

#Preview {
    NavigationStack {
        PerformanceView(store: .preview)
    }
}
