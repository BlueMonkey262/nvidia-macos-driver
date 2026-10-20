// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct VideoView: View {
    let store: DriverStore

    var body: some View {
        Form {
            Section {
                ConfFlagToggle(
                    title: "Bitrate control",
                    key: ConfKey.videoBitrateControl,
                    store: store
                )
                ConfFlagToggle(
                    title: "Hardware HEVC encode",
                    key: ConfKey.nvencHEVC,
                    store: store
                )
                ConfFlagToggle(
                    title: "Prefer Apple's encoder",
                    key: ConfKey.noNVENC,
                    store: store
                )
                ConfFlagToggle(
                    title: "Disable VideoToolbox low-latency fix",
                    key: ConfKey.noVTSpecHook,
                    store: store
                )
            } header: {
                Text("Hardware encode")
            } footer: {
                RestartRequirementFooter(kind: .appLaunch)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Video")
    }
}

#Preview {
    NavigationStack {
        VideoView(store: .preview)
    }
}
