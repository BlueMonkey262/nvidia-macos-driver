// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct PointerView: View {
    var body: some View {
        Form {
            Section {
                ContentUnavailableView {
                    Label("Pointer helper planned", systemImage: "cursorarrow")
                } description: {
                    Text("macOS hides the pointer while you type. Sunshine’s absolute-position moves never un-hide it, so the cursor can stay invisible during remote sessions. A helper that restores the pointer after typing is planned here.")
                }
            }

            Section("Workaround today") {
                Text("Move the mouse on the host, or toggle an accessibility pointer setting, to force the cursor visible again. This page will host an in-app helper when it is ready.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pointer")
    }
}

#Preview {
    NavigationStack {
        PointerView()
    }
}
