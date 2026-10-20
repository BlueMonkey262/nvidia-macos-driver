// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Session mirroring helpers shared by the Sunshine page and `gpucontrol-sunshine-tool`.
nonisolated enum SunshineDisplayMirroring {
    static func setMirrored(_ enabled: Bool, rootDisplay: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        let online = onlineDisplayIDs()
        if enabled {
            for id in online where id != rootDisplay {
                _ = CGConfigureDisplayMirrorOfDisplay(config, id, rootDisplay)
            }
            _ = CGConfigureDisplayMirrorOfDisplay(config, rootDisplay, kCGNullDirectDisplay)
        } else {
            for id in online {
                _ = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            }
        }
        _ = CGCompleteDisplayConfiguration(config, .forSession)
    }

    static func isAnyMirrorActive() -> Bool {
        onlineDisplayIDs().contains { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
