// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct AboutView: View {
    let store: DriverStore

    var body: some View {
        Form {
            Section("NVIDIA Card Control") {
                LabeledContent("App version", value: appVersion)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
                if let toolPath = store.toolPath {
                    LabeledContent("nvmtlctl path", value: toolPath)
                } else {
                    LabeledContent("nvmtlctl path", value: String(localized: "Not found"))
                }
                LabeledContent("nvmtlctl version", value: store.status?.tool ?? String(localized: "Unknown"))
            }

            Section("Status") {
                Text("Experimental. Tested on one card in a virtual machine. Expect gaps, especially outside that setup.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        String(localized: "Experimental. Tested on one card in a virtual machine.")
                    )
            }

            Section("License") {
                Text("Source-available, noncommercial (PolyForm Noncommercial 1.0.0). The owner decides copyright notices.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build, short != build {
            return "\(short) (\(build))"
        }
        if let short {
            return short
        }
        if let build {
            return build
        }
        return String(localized: "Unknown")
    }
}

#Preview {
    NavigationStack {
        AboutView(store: .preview)
    }
}
