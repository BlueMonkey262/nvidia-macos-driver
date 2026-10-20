// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// One parameter from `nvmtlctl test list --json`.
nonisolated struct TestParamSpec: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case choice
        case int
    }

    enum DefaultValue: Equatable, Sendable {
        case string(String)
        case int(Int)
    }

    var key: String
    var label: String
    var kind: Kind
    var choices: [String]
    var defaultValue: DefaultValue
    var min: Int?
    var max: Int?

    var id: String { key }

    var defaultString: String {
        switch defaultValue {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        }
    }

    init(
        key: String,
        label: String,
        kind: Kind,
        choices: [String],
        defaultValue: DefaultValue,
        min: Int?,
        max: Int?
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.choices = choices
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
    }
}

extension TestParamSpec: Codable {
    enum CodingKeys: String, CodingKey {
        case key, label, type, choices, min, max
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(String.self, forKey: .label)
        let typeRaw = try container.decode(String.self, forKey: .type)
        guard let decodedKind = Kind(rawValue: typeRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown test param type '\(typeRaw)'."
            )
        }
        kind = decodedKind
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        min = try container.decodeIfPresent(Int.self, forKey: .min)
        max = try container.decodeIfPresent(Int.self, forKey: .max)

        if let stringDefault = try? container.decode(String.self, forKey: .defaultValue) {
            defaultValue = .string(stringDefault)
        } else if let intDefault = try? container.decode(Int.self, forKey: .defaultValue) {
            defaultValue = .int(intDefault)
        } else if let doubleDefault = try? container.decode(Double.self, forKey: .defaultValue) {
            defaultValue = .int(Int(doubleDefault))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .defaultValue,
                in: container,
                debugDescription: "Param default must be a string or number."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(kind.rawValue, forKey: .type)
        if !choices.isEmpty {
            try container.encode(choices, forKey: .choices)
        }
        try container.encodeIfPresent(min, forKey: .min)
        try container.encodeIfPresent(max, forKey: .max)
        switch defaultValue {
        case .string(let value):
            try container.encode(value, forKey: .defaultValue)
        case .int(let value):
            try container.encode(value, forKey: .defaultValue)
        }
    }
}

/// One test from `nvmtlctl test list --json`.
nonisolated struct TestDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var group: String
    var description: String
    var needsRoot: Bool
    var available: Bool
    var unavailableReason: String?
    var estimatedSeconds: Int
    var params: [TestParamSpec]

    enum CodingKeys: String, CodingKey {
        case id, title, group, description, available, params
        case needsRoot = "needs_root"
        case unavailableReason = "unavailable_reason"
        case estimatedSeconds = "estimated_seconds"
    }
}

/// Outcome status from `nvmtlctl test run` / `run-all`.
nonisolated enum TestRunStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case skip
    case error

    var displayName: String {
        switch self {
        case .pass:
            return String(localized: "Passed")
        case .fail:
            return String(localized: "Failed")
        case .skip:
            return String(localized: "Skipped")
        case .error:
            return String(localized: "Error")
        }
    }

    var systemImage: String {
        switch self {
        case .pass:
            return "checkmark.circle.fill"
        case .fail:
            return "xmark.circle.fill"
        case .skip:
            return "arrow.forward.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

/// JSON number that accepts int or floating JSON values.
nonisolated struct FlexibleJSONNumber: Codable, Equatable, Hashable, Sendable {
    var value: Double

    init(_ value: Double) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let intValue = try? container.decode(Int.self) {
            value = Double(intValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Metric value must be a number."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// One result from `nvmtlctl test run ID --json` or an element of `run-all --json`.
nonisolated struct TestRunResult: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var status: TestRunStatus
    var started: String
    var durationSeconds: Double
    var summary: String
    var metrics: [String: Double]
    var details: String
    var hint: String?

    enum CodingKeys: String, CodingKey {
        case id, status, started, summary, metrics, details, hint
        case durationSeconds = "duration_s"
    }

    init(
        id: String,
        status: TestRunStatus,
        started: String,
        durationSeconds: Double,
        summary: String,
        metrics: [String: Double],
        details: String,
        hint: String?
    ) {
        self.id = id
        self.status = status
        self.started = started
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.metrics = metrics
        self.details = details
        self.hint = hint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(TestRunStatus.self, forKey: .status)
        started = try container.decode(String.self, forKey: .started)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        hint = try container.decodeIfPresent(String.self, forKey: .hint)

        if let flexible = try container.decodeIfPresent([String: FlexibleJSONNumber].self, forKey: .metrics) {
            metrics = flexible.mapValues(\.value)
        } else {
            metrics = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(started, forKey: .started)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(summary, forKey: .summary)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(details, forKey: .details)
        try container.encodeIfPresent(hint, forKey: .hint)
    }
}

/// Ordered group of tests for the list UI.
nonisolated struct TestGroupSection: Equatable, Identifiable, Sendable {
    var name: String
    var tests: [TestDefinition]

    var id: String { name }
}
