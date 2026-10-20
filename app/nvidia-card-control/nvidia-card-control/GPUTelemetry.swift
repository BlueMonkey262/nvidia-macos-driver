// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Live GPU readings. Every value is optional: the driver reports only what the card exposes.
nonisolated struct GPUTelemetry: Equatable, Sendable {
    var temperatureC: Double?
    var fanRPM: Int?
    var fanPercent: Int?
    var coreClockMHz: Int?
    var powerWatts: Double?

    static let unavailable = GPUTelemetry()

    static let previewSample = GPUTelemetry(
        temperatureC: 52,
        fanRPM: 1240,
        fanPercent: 38,
        coreClockMHz: 1905,
        powerWatts: 78
    )
}
