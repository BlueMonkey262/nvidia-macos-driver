// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

enum SidebarCategory: String, CaseIterable, Identifiable, Hashable {
    case status
    case display
    case video
    case sunshine
    case performance
    case logs
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .status:
            return "Status"
        case .display:
            return "Display"
        case .video:
            return "Video"
        case .sunshine:
            return "Sunshine"
        case .performance:
            return "Performance"
        case .logs:
            return "Logs"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .status:
            return "heart.text.square"
        case .display:
            return "display"
        case .video:
            return "video"
        case .sunshine:
            return "sun.max"
        case .performance:
            return "gauge.with.needle"
        case .logs:
            return "doc.text.magnifyingglass"
        case .about:
            return "info.circle"
        }
    }
}
