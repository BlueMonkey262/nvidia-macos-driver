// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Pure helpers for `nvmtlctl test` argv, decoding, timeouts and report text.
nonisolated enum TestHelpers {
    /// Timeout for one test run: at least 120 s, or three times the estimate.
    static func timeoutSeconds(estimatedSeconds: Int) -> TimeInterval {
        let estimate = max(0, estimatedSeconds)
        return max(120, TimeInterval(estimate * 3))
    }

    static func listArguments() -> [String] {
        ["test", "list", "--json"]
    }

    static func runAllArguments() -> [String] {
        ["test", "run-all", "--json"]
    }

    /// Builds `test run ID [--param key=value ...] --json` with stable param order.
    static func runArguments(testID: String, params: [String: String]) -> [String] {
        var arguments = ["test", "run", testID]
        for key in params.keys.sorted() {
            guard let value = params[key] else { continue }
            arguments.append("--param")
            arguments.append("\(key)=\(value)")
        }
        arguments.append("--json")
        return arguments
    }

    /// Default editable values for each param on a definition.
    static func defaultParamValues(for definition: TestDefinition) -> [String: String] {
        var values: [String: String] = [:]
        for param in definition.params {
            values[param.key] = param.defaultString
        }
        return values
    }

    /// Clamps an int param draft to its declared bounds when present.
    static func clampIntParam(_ raw: Int, spec: TestParamSpec) -> Int {
        var value = raw
        if let min = spec.min {
            value = max(min, value)
        }
        if let max = spec.max {
            value = min(max, value)
        }
        return value
    }

    /// Groups tests by `group`, preserving list order of first appearance.
    static func groupedSections(from definitions: [TestDefinition]) -> [TestGroupSection] {
        var order: [String] = []
        var buckets: [String: [TestDefinition]] = [:]
        for definition in definitions {
            if buckets[definition.group] == nil {
                order.append(definition.group)
                buckets[definition.group] = []
            }
            buckets[definition.group, default: []].append(definition)
        }
        return order.map { name in
            TestGroupSection(name: name, tests: buckets[name] ?? [])
        }
    }

    static func formatEstimatedDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(localized: "About \(seconds) s")
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return String(localized: "About \(minutes) min")
        }
        return String(localized: "About \(minutes) min \(remainder) s")
    }

    static func formatMetricValue(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    /// Plain-text report for the pasteboard.
    static func plainTextReport(
        macos: String,
        gpu: String,
        toolVersion: String,
        definitions: [TestDefinition],
        results: [TestRunResult]
    ) -> String {
        let titles = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.title) })
        var lines: [String] = []
        lines.append("GPU Control test report")
        lines.append("macOS: \(displayField(macos))")
        lines.append("GPU: \(displayField(gpu))")
        lines.append("nvmtlctl: \(displayField(toolVersion))")
        lines.append("")

        if results.isEmpty {
            lines.append("No results yet.")
            return lines.joined(separator: "\n")
        }

        for result in results {
            let title = titles[result.id] ?? result.id
            lines.append("\(title) (\(result.id))")
            lines.append("  Status: \(result.status.displayName)")
            lines.append("  Started: \(result.started)")
            lines.append("  Duration: \(String(format: "%.1f", result.durationSeconds)) s")
            if !result.summary.isEmpty {
                lines.append("  Summary: \(result.summary)")
            }
            let metricKeys = result.metrics.keys.sorted()
            if !metricKeys.isEmpty {
                lines.append("  Metrics:")
                for key in metricKeys {
                    let value = result.metrics[key] ?? 0
                    lines.append("    \(key): \(formatMetricValue(value))")
                }
            }
            if let hint = result.hint, !hint.isEmpty {
                lines.append("  Hint: \(hint)")
            }
            if !result.details.isEmpty {
                lines.append("  Details:")
                for detailLine in result.details.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(detailLine)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private static func displayField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}

extension JSONDecoding {
    static func decodeTestList(from data: Data) throws -> [TestDefinition] {
        try decoder.decode([TestDefinition].self, from: data)
    }

    static func decodeTestList(fromUTF8 string: String) throws -> [TestDefinition] {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Test list JSON is not valid UTF-8.")
            )
        }
        return try decodeTestList(from: data)
    }

    static func decodeTestRunResult(from data: Data) throws -> TestRunResult {
        try decoder.decode(TestRunResult.self, from: data)
    }

    static func decodeTestRunResult(fromUTF8 string: String) throws -> TestRunResult {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Test run JSON is not valid UTF-8.")
            )
        }
        return try decodeTestRunResult(from: data)
    }

    static func decodeTestRunResults(from data: Data) throws -> [TestRunResult] {
        try decoder.decode([TestRunResult].self, from: data)
    }

    static func decodeTestRunResults(fromUTF8 string: String) throws -> [TestRunResult] {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Test run-all JSON is not valid UTF-8.")
            )
        }
        return try decodeTestRunResults(from: data)
    }
}

extension TestDefinition {
    static let previewSamples: [TestDefinition] = [
        TestDefinition(
            id: "encode-h264",
            title: "H.264 encode",
            group: "Video encode",
            description: "Hardware H.264 encode at the chosen size and pattern; checks every frame decodes and reports PSNR, bitrate and latency.",
            needsRoot: false,
            available: true,
            unavailableReason: nil,
            estimatedSeconds: 15,
            params: [
                TestParamSpec(
                    key: "size",
                    label: "Size",
                    kind: .choice,
                    choices: ["720p", "1080p", "1440p"],
                    defaultValue: .string("1080p"),
                    min: nil,
                    max: nil
                ),
                TestParamSpec(
                    key: "pattern",
                    label: "Pattern",
                    kind: .choice,
                    choices: ["static", "motion", "edges", "noise", "cuts"],
                    defaultValue: .string("motion"),
                    min: nil,
                    max: nil
                ),
                TestParamSpec(
                    key: "bitrate_mbps",
                    label: "Bitrate (Mbit/s)",
                    kind: .int,
                    choices: [],
                    defaultValue: .int(8),
                    min: 1,
                    max: 100
                ),
                TestParamSpec(
                    key: "seconds",
                    label: "Length (s)",
                    kind: .int,
                    choices: [],
                    defaultValue: .int(6),
                    min: 2,
                    max: 60
                ),
            ]
        ),
        TestDefinition(
            id: "gpu-compute",
            title: "GPU compute",
            group: "Metal",
            description: "A small compute kernel that checks results.",
            needsRoot: false,
            available: false,
            unavailableReason: "Test program missing from the bundle.",
            estimatedSeconds: 5,
            params: []
        ),
    ]
}

extension TestRunResult {
    static let previewSample = TestRunResult(
        id: "encode-h264",
        status: .pass,
        started: "2026-10-19T19:00:00Z",
        durationSeconds: 12.4,
        summary: "360 of 360 frames, 10.2 Mbit/s, PSNR 40.8 dB",
        metrics: [
            "fps": 237.0,
            "psnr_db": 40.8,
            "p95_ms": 7.0,
            "bitrate_mbps": 10.2,
        ],
        details: "frame 0 ok\nframe 1 ok\n...",
        hint: nil
    )
}
