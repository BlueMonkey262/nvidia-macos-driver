// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarCategory?

    var body: some View {
        List(SidebarCategory.allCases, selection: $selection) { category in
            Label(category.title, systemImage: category.systemImage)
                .tag(category)
                .accessibilityLabel(Text(category.title))
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
