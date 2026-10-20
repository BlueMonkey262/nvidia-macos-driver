// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct AboutView: View {
    let store: DriverStore

    private let upstreamURL = URL(string: "https://github.com/nullmoth/nvidia-macos-driver")

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

            Section("Credits") {
                Text("Thank you to NullMoth for the upstream NVIDIA driver for macOS. This app and the fork it belongs to build on that work.")
                    .fixedSize(horizontal: false, vertical: true)
                if let upstreamURL {
                    Link("NullMoth's driver on GitHub", destination: upstreamURL)
                }
                Text("This is an unofficial, community project. It is not affiliated with or endorsed by NVIDIA or NullMoth Systems.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("License") {
                Text("Copyright © 2026 BlueMonkey. Source-available, noncommercial (PolyForm Noncommercial 1.0.0).")
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
