// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarCategory?
    @State private var videoExpanded = true

    private func row(_ category: SidebarCategory) -> some View {
        Label(category.title, systemImage: category.systemImage)
            .tag(category)
            .accessibilityLabel(Text(category.title))
    }

    var body: some View {
        List(selection: $selection) {
            row(.status)
            row(.display)
            DisclosureGroup(isExpanded: $videoExpanded) {
                row(.sunshine)
            } label: {
                row(.video)
            }
            row(.performance)
            row(.logs)
            row(.about)
        }
        .listStyle(.sidebar)
        .navigationTitle("GPU Control")
    }
}

#Preview {
    NavigationSplitView {
        SidebarView(selection: .constant(.status))
    } detail: {
        Text("Detail")
    }
}
