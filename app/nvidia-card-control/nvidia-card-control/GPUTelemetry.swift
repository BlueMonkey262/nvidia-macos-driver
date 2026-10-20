// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Darwin
import Foundation

/// One probe metric: a real value, an error object from the probe, or absent from the JSON.
nonisolated enum MetricReading<Value: Equatable & Sendable>: Equatable, Sendable {
    case unavailable
    case value(Value)
    case error(domain: String, reason: String)

    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    /// Human-readable reason for a dash tile; nil when a value is present.
    var helpReason: String? {
        switch self {
        case .value:
            return nil
        case .unavailable:
            return String(localized: "Unavailable")
        case .error(let domain, let reason):
            return "\(domain): \(reason)"
        }
    }
}

/// One process row from `process_vram` in the probe JSON.
nonisolated struct ProcessVRAMUsage: Equatable, Sendable, Identifiable {
    var pid: Int32
    var privateBytes: UInt64
    var sharedOwnedBytes: UInt64
    var sharedDupedBytes: UInt64
    /// Set when the per-pid `vram` field was an error object instead of byte counts.
    var vramErrorHelp: String?

    var id: Int32 { pid }

    /// Private plus both shared fields; used for sorting and the size column only.
    var reportedBytes: UInt64 {
        privateBytes &+ sharedOwnedBytes &+ sharedDupedBytes
    }
}

/// Live GPU readings from `nvmtlctl telemetry --json`. Every metric is a value-or-error reading.
nonisolated struct GPUTelemetry: Equatable, Sendable {
    var schemaVersion: Int?
    var timestampUnixS: Double?
    var probeStatus: String?

    var gpuName: MetricReading<String> = .unavailable
    var gpuUUID: MetricReading<String> = .unavailable
    var driverVersion: MetricReading<String> = .unavailable
    var gspFirmwareVersion: MetricReading<String> = .unavailable
    var vbiosVersion: MetricReading<String> = .unavailable

    var temperatureCoreC: MetricReading<Double> = .unavailable
    var temperatureMemoryC: MetricReading<Double> = .unavailable
    var temperatureHotspotC: MetricReading<Double> = .unavailable

    var fanRPMSlots: MetricReading<[Int]> = .unavailable
    var fanPercent: MetricReading<Int> = .unavailable

    var clockGraphicsMHz: MetricReading<Double> = .unavailable
    var clockMemoryMHz: MetricReading<Double> = .unavailable
    var clockVideoMHz: MetricReading<Double> = .unavailable

    var powerDrawW: MetricReading<Double> = .unavailable
    var powerAverageW: MetricReading<Double> = .unavailable

    var gpuUtilizationPercent: MetricReading<Double> = .unavailable
    var memoryUtilizationPercent: MetricReading<Double> = .unavailable

    var performanceState: MetricReading<String> = .unavailable
    var pcieGeneration: MetricReading<Int> = .unavailable
    var pcieWidth: MetricReading<Int> = .unavailable

    var vramTotalBytes: MetricReading<UInt64> = .unavailable
    var vramUsedBytes: MetricReading<UInt64> = .unavailable
    var vramFreeBytes: MetricReading<UInt64> = .unavailable

    var bar1TotalBytes: MetricReading<UInt64> = .unavailable
    var bar1UsedBytes: MetricReading<UInt64> = .unavailable
    var bar1FreeBytes: MetricReading<UInt64> = .unavailable
    var bar1LargestFreeBytes: MetricReading<UInt64> = .unavailable
    var bar1GrantBudgetBytes: MetricReading<UInt64> = .unavailable
    var bar1GrantMappedBytes: MetricReading<UInt64> = .unavailable

    var processVRAM: MetricReading<[ProcessVRAMUsage]> = .unavailable

    /// Convenience for the Temperature tile; nil when the metric is missing or an error.
    var temperatureC: Double? { temperatureCoreC.value }

    /// First non-zero cooler slot, else 0 when the array is present and all zeros; nil on error/missing.
    var fanRPM: Int? {
        guard let slots = fanRPMSlots.value else { return nil }
        return slots.first(where: { $0 > 0 }) ?? slots.first ?? 0
    }

    var fanPercentValue: Int? { fanPercent.value }

    /// Graphics clock rounded to MHz for the Core clock tile.
    var coreClockMHz: Int? {
        guard let mhz = clockGraphicsMHz.value else { return nil }
        return Int(mhz.rounded())
    }

    /// Instantaneous draw when present, otherwise the average; never invented.
    var powerWatts: Double? { powerDrawW.value ?? powerAverageW.value }

    static let unavailable = GPUTelemetry()

    static let previewSample = GPUTelemetry(
        schemaVersion: 1,
        timestampUnixS: 1_792_465_321,
        probeStatus: "complete",
        gpuName: .value("NVIDIA GeForce RTX 2060 SUPER"),
        gpuUUID: .value("GPU-c86e1267-a8d3-00b2-dccf-e97f80728d97"),
        driverVersion: .value("610.57.04"),
        gspFirmwareVersion: .value("610.57.04"),
        vbiosVersion: .value("90.06.44.40.72"),
        temperatureCoreC: .value(52),
        temperatureMemoryC: .error(domain: "probe", reason: "not_exposed_or_cache_invalid"),
        temperatureHotspotC: .error(domain: "probe", reason: "no_verified_public_abi"),
        fanRPMSlots: .error(domain: "rm", reason: "46"),
        fanPercent: .error(domain: "probe", reason: "no_verified_public_abi"),
        clockGraphicsMHz: .error(domain: "rm", reason: "46"),
        clockMemoryMHz: .error(domain: "rm", reason: "46"),
        clockVideoMHz: .error(domain: "rm", reason: "46"),
        powerDrawW: .error(domain: "rm", reason: "46"),
        powerAverageW: .error(domain: "rm", reason: "46"),
        gpuUtilizationPercent: .error(domain: "rm", reason: "46"),
        memoryUtilizationPercent: .error(domain: "rm", reason: "46"),
        performanceState: .value("P0"),
        pcieGeneration: .value(3),
        pcieWidth: .value(16),
        vramTotalBytes: .value(8_589_934_592),
        vramUsedBytes: .value(1_208_811_520),
        vramFreeBytes: .value(7_381_123_072),
        bar1TotalBytes: .value(268_435_456),
        bar1UsedBytes: .value(251_133_952),
        bar1FreeBytes: .value(17_301_504),
        bar1LargestFreeBytes: .value(2_097_152),
        bar1GrantBudgetBytes: .value(243_073_024),
        bar1GrantMappedBytes: .value(238_288_896),
        processVRAM: .value([
            ProcessVRAMUsage(pid: 2170, privateBytes: 143_327_232, sharedOwnedBytes: 0, sharedDupedBytes: 18_219_008),
            ProcessVRAMUsage(pid: 1924, privateBytes: 84_869_120, sharedOwnedBytes: 0, sharedDupedBytes: 103_415_808),
        ])
    )
}

nonisolated enum GPUTelemetryJSON {
    /// Tolerant decode of probe JSON: missing keys and `{"domain","error"}` objects become readings, never zeros.
    static func decode(from data: Data) throws -> GPUTelemetry {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = root as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Telemetry JSON root must be an object.")
            )
        }
        return decode(from: object)
    }

    static func decode(fromUTF8 string: String) throws -> GPUTelemetry {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Telemetry JSON is not valid UTF-8.")
            )
        }
        return try decode(from: data)
    }

    static func decode(from object: [String: Any]) -> GPUTelemetry {
        var telemetry = GPUTelemetry()
        telemetry.schemaVersion = intValue(object["schema_version"])
        telemetry.timestampUnixS = doubleValue(object["timestamp_unix_s"])
        if let probe = object["probe"] as? String {
            telemetry.probeStatus = probe
        } else if case .error(let domain, let reason) = reading(object["probe"], as: { $0 as? String }) {
            telemetry.probeStatus = "\(domain):\(reason)"
        }

        telemetry.gpuName = reading(object["gpu_name"], as: { $0 as? String })
        telemetry.gpuUUID = reading(object["gpu_uuid"], as: { $0 as? String })
        telemetry.driverVersion = reading(object["driver_version"], as: { $0 as? String })
        telemetry.gspFirmwareVersion = reading(object["gsp_firmware_version"], as: { $0 as? String })
        telemetry.vbiosVersion = reading(object["vbios_version"], as: { $0 as? String })

        telemetry.temperatureCoreC = reading(object["temperature_core_c"], as: doubleValue)
        telemetry.temperatureMemoryC = reading(object["temperature_memory_c"], as: doubleValue)
        telemetry.temperatureHotspotC = reading(object["temperature_hotspot_c"], as: doubleValue)

        telemetry.fanRPMSlots = reading(object["fan_rpm_slots"], as: intArrayValue)
        telemetry.fanPercent = reading(object["fan_percent"], as: intValue)

        telemetry.clockGraphicsMHz = reading(object["clock_graphics_mhz"], as: doubleValue)
        telemetry.clockMemoryMHz = reading(object["clock_memory_mhz"], as: doubleValue)
        telemetry.clockVideoMHz = reading(object["clock_video_mhz"], as: doubleValue)

        telemetry.powerDrawW = reading(object["power_draw_w"], as: doubleValue)
        telemetry.powerAverageW = reading(object["power_average_w"], as: doubleValue)

        telemetry.gpuUtilizationPercent = reading(object["gpu_utilization_percent"], as: doubleValue)
        telemetry.memoryUtilizationPercent = reading(object["memory_utilization_percent"], as: doubleValue)

        telemetry.performanceState = reading(object["performance_state"], as: { $0 as? String })
        telemetry.pcieGeneration = reading(object["pcie_generation"], as: intValue)
        telemetry.pcieWidth = reading(object["pcie_width"], as: intValue)

        telemetry.vramTotalBytes = reading(object["vram_total_bytes"], as: uint64Value)
        telemetry.vramUsedBytes = reading(object["vram_used_bytes"], as: uint64Value)
        telemetry.vramFreeBytes = reading(object["vram_free_bytes"], as: uint64Value)

        telemetry.bar1TotalBytes = reading(object["bar1_total_bytes"], as: uint64Value)
        telemetry.bar1UsedBytes = reading(object["bar1_used_bytes"], as: uint64Value)
        telemetry.bar1FreeBytes = reading(object["bar1_free_bytes"], as: uint64Value)
        telemetry.bar1LargestFreeBytes = reading(object["bar1_largest_free_bytes"], as: uint64Value)
        telemetry.bar1GrantBudgetBytes = reading(object["bar1_grant_budget_bytes"], as: uint64Value)
        telemetry.bar1GrantMappedBytes = reading(object["bar1_grant_mapped_bytes"], as: uint64Value)

        telemetry.processVRAM = decodeProcessVRAM(object["process_vram"])
        return telemetry
    }

    private static func reading<Value>(
        _ raw: Any?,
        as convert: (Any) -> Value?
    ) -> MetricReading<Value> {
        guard let raw else { return .unavailable }
        if let error = errorObject(raw) {
            return .error(domain: error.domain, reason: error.reason)
        }
        guard let value = convert(raw) else { return .unavailable }
        return .value(value)
    }

    private static func errorObject(_ raw: Any) -> (domain: String, reason: String)? {
        guard let object = raw as? [String: Any], object["error"] != nil else { return nil }
        let domain = (object["domain"] as? String) ?? "probe"
        let reason: String
        if let string = object["error"] as? String {
            reason = string
        } else if let number = object["error"] as? NSNumber {
            reason = number.stringValue
        } else {
            reason = String(describing: object["error"]!)
        }
        return (domain, reason)
    }

    private static func decodeProcessVRAM(_ raw: Any?) -> MetricReading<[ProcessVRAMUsage]> {
        guard let raw else { return .unavailable }
        if let error = errorObject(raw) {
            return .error(domain: error.domain, reason: error.reason)
        }
        guard let rows = raw as? [Any] else { return .unavailable }
        var parsed: [ProcessVRAMUsage] = []
        parsed.reserveCapacity(rows.count)
        for row in rows {
            guard let object = row as? [String: Any], let pid = intValue(object["pid"]) else { continue }
            guard let vramRaw = object["vram"] else { continue }
            if let error = errorObject(vramRaw) {
                parsed.append(
                    ProcessVRAMUsage(
                        pid: Int32(pid),
                        privateBytes: 0,
                        sharedOwnedBytes: 0,
                        sharedDupedBytes: 0,
                        vramErrorHelp: "\(error.domain): \(error.reason)"
                    )
                )
                continue
            }
            guard let vram = vramRaw as? [String: Any] else { continue }
            parsed.append(
                ProcessVRAMUsage(
                    pid: Int32(pid),
                    privateBytes: uint64Value(vram["private_bytes"]) ?? 0,
                    sharedOwnedBytes: uint64Value(vram["shared_owned_bytes"]) ?? 0,
                    sharedDupedBytes: uint64Value(vram["shared_duped_bytes"]) ?? 0
                )
            )
        }
        return .value(parsed)
    }

    private static func doubleValue(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return nil
    }

    private static func intValue(_ raw: Any) -> Int? { intValue(Optional(raw)) }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.uint64Value }
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private static func uint64Value(_ raw: Any) -> UInt64? { uint64Value(Optional(raw)) }

    private static func intArrayValue(_ raw: Any) -> [Int]? {
        guard let array = raw as? [Any] else { return nil }
        var values: [Int] = []
        values.reserveCapacity(array.count)
        for element in array {
            guard let value = intValue(element) else { return nil }
            values.append(value)
        }
        return values
    }
}

nonisolated enum ProcessNameLookup {
    /// Best-effort short name from `proc_name`; falls back to a localized PID label.
    static func name(forPID pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        if length > 0 {
            return String(cString: buffer)
        }
        return String(localized: "PID \(pid)")
    }
}
