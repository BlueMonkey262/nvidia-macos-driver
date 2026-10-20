// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Small decoding self-check (no XCTest target in this project). Call `failures()` from a DEBUG assert or paste into a Swift REPL.
nonisolated enum GPUTelemetryDecodingCheck {
    /// Returns human-readable failure lines; empty means every fixture decoded as expected.
    static func failures() -> [String] {
        var failures: [String] = []

        do {
            let telemetry = try GPUTelemetryJSON.decode(fromUTF8: workingAndErrorSample)
            expect(telemetry.temperatureCoreC.value == 52, "temperature_core_c should be 52", into: &failures)
            expect(telemetry.temperatureCoreC.helpReason == nil, "temperature_core_c should have no help", into: &failures)
            expect(telemetry.fanRPMSlots.value == nil, "fan_rpm_slots error must not yield a value", into: &failures)
            expect(telemetry.fanRPM == nil, "fanRPM must be nil when slots are an error (never 0)", into: &failures)
            expect(
                telemetry.fanRPMSlots.helpReason == "rm: 46",
                "fan_rpm_slots help should name domain and reason",
                into: &failures
            )
            expect(telemetry.clockGraphicsMHz.value == nil, "clock error must not yield 0 MHz", into: &failures)
            expect(telemetry.coreClockMHz == nil, "coreClockMHz must be nil on clock error", into: &failures)
            expect(telemetry.powerWatts == nil, "power error must not yield 0 W", into: &failures)
            expect(telemetry.vramTotalBytes.value == 8_589_934_592, "vram_total_bytes", into: &failures)
            expect(telemetry.vramUsedBytes.value == 1_208_811_520, "vram_used_bytes", into: &failures)
            expect(telemetry.bar1GrantMappedBytes.value == 238_288_896, "bar1_grant_mapped_bytes", into: &failures)
            expect(telemetry.pcieGeneration.value == 3, "pcie_generation", into: &failures)
            expect(telemetry.pcieWidth.value == 16, "pcie_width", into: &failures)
            expect(telemetry.performanceState.value == "P0", "performance_state", into: &failures)
            expect(telemetry.gpuName.value == "NVIDIA GeForce RTX 2060 SUPER", "gpu_name", into: &failures)
            expect(telemetry.driverVersion.value == "610.57.04", "driver_version", into: &failures)
            expect(telemetry.gspFirmwareVersion.value == "610.57.04", "gsp_firmware_version", into: &failures)
            expect(telemetry.vbiosVersion.value == "90.06.44.40.72", "vbios_version", into: &failures)
            guard let processes = telemetry.processVRAM.value else {
                failures.append("process_vram should decode as an array")
                return failures
            }
            expect(processes.count == 2, "process_vram row count", into: &failures)
            expect(processes.first?.pid == 2170, "first process pid", into: &failures)
            expect(processes.first?.privateBytes == 143_327_232, "first process private", into: &failures)
            expect(processes.first?.sharedDupedBytes == 18_219_008, "first process shared_duped", into: &failures)
        } catch {
            failures.append("workingAndErrorSample decode threw: \(error)")
        }

        do {
            let telemetry = try GPUTelemetryJSON.decode(fromUTF8: #"{"schema_version":1}"#)
            expect(telemetry.temperatureCoreC == .unavailable, "missing temperature stays unavailable", into: &failures)
            expect(telemetry.fanRPM == nil, "missing fan stays nil", into: &failures)
            expect(telemetry.processVRAM == .unavailable, "missing process_vram stays unavailable", into: &failures)
        } catch {
            failures.append("minimal sample decode threw: \(error)")
        }

        do {
            let telemetry = try GPUTelemetryJSON.decode(fromUTF8: fanSlotsSample)
            expect(telemetry.fanRPMSlots.value == [0, 1200, 0], "fan_rpm_slots array", into: &failures)
            expect(telemetry.fanRPM == 1200, "fanRPM picks first non-zero slot", into: &failures)
        } catch {
            failures.append("fanSlotsSample decode threw: \(error)")
        }

        return failures
    }

    private static func expect(_ condition: Bool, _ message: String, into failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    private static let workingAndErrorSample = """
    {
      "schema_version": 1,
      "temperature_core_c": 52,
      "fan_rpm_slots": {"domain": "rm", "error": 46},
      "fan_percent": {"domain": "probe", "error": "no_verified_public_abi"},
      "clock_graphics_mhz": {"domain": "rm", "error": 46},
      "power_draw_w": {"domain": "rm", "error": 46},
      "power_average_w": {"domain": "rm", "error": 46},
      "vram_total_bytes": 8589934592,
      "vram_used_bytes": 1208811520,
      "vram_free_bytes": 7381123072,
      "bar1_total_bytes": 268435456,
      "bar1_used_bytes": 251133952,
      "bar1_free_bytes": 17301504,
      "bar1_largest_free_bytes": 2097152,
      "bar1_grant_budget_bytes": 243073024,
      "bar1_grant_mapped_bytes": 238288896,
      "pcie_generation": 3,
      "pcie_width": 16,
      "performance_state": "P0",
      "gpu_name": "NVIDIA GeForce RTX 2060 SUPER",
      "gpu_uuid": "GPU-c86e1267-a8d3-00b2-dccf-e97f80728d97",
      "driver_version": "610.57.04",
      "gsp_firmware_version": "610.57.04",
      "vbios_version": "90.06.44.40.72",
      "process_vram": [
        {"pid": 2170, "vram": {"private_bytes": 143327232, "shared_duped_bytes": 18219008, "shared_owned_bytes": 0}},
        {"pid": 1924, "vram": {"private_bytes": 84869120, "shared_duped_bytes": 103415808, "shared_owned_bytes": 0}}
      ]
    }
    """

    private static let fanSlotsSample = #"{"schema_version":1,"fan_rpm_slots":[0,1200,0]}"#
}
