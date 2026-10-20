// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// Shared chrome for one `nvmtlctl conf` knob: description, default mark, reset.
struct ConfSettingChrome<Content: View>: View {
    let entry: ConfEntry?
    let fallbackKey: String
    let isBusy: Bool
    let onReset: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content()

            if let entry {
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(localized: "Description: \(entry.description)"))

                HStack(spacing: 12) {
                    if entry.isAtDefault {
                        Text("Default")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(String(localized: "Using the default value"))
                    } else {
                        Text("Default \(entry.defaultValue)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(
                                String(localized: "Default value \(entry.defaultValue)")
                            )
                    }

                    Button("Reset") {
                        onReset()
                    }
                    .disabled(isBusy || entry.isAtDefault)
                    .accessibilityHint(String(localized: "Restore the driver default for this setting"))
                }
            } else {
                Text("Setting \(fallbackKey) was not returned by nvmtlctl. Refresh status, or update nvmtlctl.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ConfFlagToggle: View {
    let title: LocalizedStringKey
    let key: String
    let store: DriverStore

    var body: some View {
        let entry = store.entry(for: key)
        ConfSettingChrome(
            entry: entry,
            fallbackKey: key,
            isBusy: store.isBusy,
            onReset: {
                Task { await store.unsetConf(key: key) }
            }
        ) {
            Toggle(isOn: flagBinding(entry: entry)) {
                Text(title)
            }
            .disabled(store.isBusy || entry == nil)
            .accessibilityValue(flagBinding(entry: entry).wrappedValue ? "On" : "Off")
        }
    }

    private func flagBinding(entry: ConfEntry?) -> Binding<Bool> {
        Binding(
            get: { entry?.isEnabledFlag ?? false },
            set: { newValue in
                Task { await store.setFlag(key: key, enabled: newValue) }
            }
        )
    }
}

struct RestartRequirementFooter: View {
    enum Kind {
        case appLaunch
        case desktop
        case both
    }

    let kind: Kind

    var body: some View {
        Text(footerText)
            .foregroundStyle(.secondary)
    }

    private var footerText: LocalizedStringKey {
        switch kind {
        case .appLaunch:
            return "App-level settings apply when an app starts."
        case .desktop:
            return "Desktop settings need the desktop restarted before WindowServer picks them up."
        case .both:
            return "App-level settings apply when an app starts. Desktop settings need the desktop restarted."
        }
    }
}
