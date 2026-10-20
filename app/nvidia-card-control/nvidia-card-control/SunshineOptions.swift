// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Sunshine options we expose in GPU Control. Labels/descriptions are shortened from
/// `.scratch/sunshine-ref/en.json` (`config` keys). Do not invent keys.
nonisolated enum SunshineOptionSpec {
    static let defaultEncoder = "videotoolbox"
    static let defaultFecPercentage = 20
    static let defaultPort = 47989
    static let defaultMinLogLevel = "info"
    static let defaultHevcMode = 0
    static let defaultAv1Mode = 0

    /// macOS-sensible encoder values (en.json documents `encoder` / `encoder_software`;
    /// `videotoolbox` is what this host uses and what Sunshine accepts on macOS).
    static var encoders: [(value: String, title: String)] {
        [
            ("videotoolbox", String(localized: "VideoToolbox")),
            ("software", String(localized: "Software")),
        ]
    }

    static var hevcModes: [(value: Int, title: String)] {
        [
            (0, String(localized: "Based on encoder capabilities (recommended)")),
            (1, String(localized: "Do not advertise HEVC")),
            (2, String(localized: "HEVC Main profile")),
            (3, String(localized: "HEVC Main and Main10 (HDR)")),
        ]
    }

    static var av1Modes: [(value: Int, title: String)] {
        [
            (0, String(localized: "Based on encoder capabilities (recommended)")),
            (1, String(localized: "Do not advertise AV1")),
            (2, String(localized: "AV1 Main 8-bit")),
            (3, String(localized: "AV1 Main 8-bit and 10-bit (HDR)")),
        ]
    }

    static var logLevels: [(value: String, title: String)] {
        [
            ("verbose", String(localized: "Verbose")),
            ("debug", String(localized: "Debug")),
            ("info", String(localized: "Info")),
            ("warning", String(localized: "Warning")),
            ("error", String(localized: "Error")),
            ("fatal", String(localized: "Fatal")),
            ("none", String(localized: "None")),
        ]
    }

    // Descriptions: shortened en.json wording.
    static var encoderDescription: String {
        String(localized: "Force a specific encoder, otherwise Sunshine will select the best available option.")
    }
    static var hevcModeDescription: String {
        String(localized: "Allows the client to request HEVC Main or HEVC Main10 video streams.")
    }
    static var av1ModeDescription: String {
        String(localized: "Allows the client to request AV1 Main 8-bit or 10-bit video streams.")
    }
    static var fecPercentageDescription: String {
        String(localized: "Percentage of error correcting packets per data packet in each video frame.")
    }
    static var sunshineNameDescription: String {
        String(localized: "The name displayed by Moonlight. If not specified, the PC's hostname is used.")
    }
    static var minLogLevelDescription: String {
        String(localized: "The minimum log level printed to standard out.")
    }
    static var upnpDescription: String {
        String(localized: "Automatically configure port forwarding for streaming over the Internet.")
    }
    static var portDescription: String {
        String(localized: "Set the family of ports used by Sunshine.")
    }
    static var outputNameDescription: String {
        String(localized: "During Sunshine startup, you should see the list of detected displays. Use the id value inside the parenthesis.")
    }

    static func clampFecPercentage(_ value: Int) -> Int {
        min(255, max(1, value))
    }

    static func clampPort(_ value: Int) -> Int {
        min(65535, max(1024, value))
    }

    static func clampHevcMode(_ value: Int) -> Int {
        min(3, max(0, value))
    }

    static func clampAv1Mode(_ value: Int) -> Int {
        min(3, max(0, value))
    }

    static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    static func isEnabledFlag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "enabled" || v == "true" || v == "1" || v == "yes" || v == "on"
    }

    static func enabledFlagString(_ on: Bool) -> String {
        on ? "enabled" : "disabled"
    }
}

/// One row from `gpucontrol-sunshine-tool displays --json`.
nonisolated struct SunshineDisplayInfo: Codable, Equatable, Identifiable, Sendable {
    var id: UInt32
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var pointWidth: Double
    var pointHeight: Double
    var refreshHz: Double?
    var isMain: Bool
    var mirrorOf: UInt32?
    var builtIn: Bool
    var gpu: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case pointWidth = "point_width"
        case pointHeight = "point_height"
        case refreshHz = "refresh_hz"
        case isMain = "is_main"
        case mirrorOf = "mirror_of"
        case builtIn = "built_in"
        case gpu
    }

    var pickerLabel: String {
        var parts: [String] = [name, "\(pixelWidth) × \(pixelHeight)"]
        if isMain { parts.append(String(localized: "main")) }
        if mirrorOf != nil { parts.append(String(localized: "mirrored")) }
        if builtIn { parts.append(String(localized: "built-in")) }
        return parts.joined(separator: ", ")
    }
}

/// Stable display choice persisted for `gpucontrol-sunshine-tool launch`.
nonisolated struct SunshineDisplayChoice: Codable, Equatable, Sendable {
    var schemaVersion: Int
    /// When true, `output_name` is removed so Sunshine uses the main display.
    var useMainDisplay: Bool
    var matchName: String?
    var matchPixelWidth: Int?
    var matchPixelHeight: Int?
    var mirrorEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case useMainDisplay = "use_main_display"
        case matchName = "match_name"
        case matchPixelWidth = "match_pixel_width"
        case matchPixelHeight = "match_pixel_height"
        case mirrorEnabled = "mirror_enabled"
    }

    static let currentSchema = 1

    static func mainDisplay(mirror: Bool = false) -> SunshineDisplayChoice {
        SunshineDisplayChoice(
            schemaVersion: currentSchema,
            useMainDisplay: true,
            matchName: nil,
            matchPixelWidth: nil,
            matchPixelHeight: nil,
            mirrorEnabled: mirror
        )
    }

    static func matched(
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        mirror: Bool
    ) -> SunshineDisplayChoice {
        SunshineDisplayChoice(
            schemaVersion: currentSchema,
            useMainDisplay: false,
            matchName: name,
            matchPixelWidth: pixelWidth,
            matchPixelHeight: pixelHeight,
            mirrorEnabled: mirror
        )
    }
}

nonisolated enum SunshineDisplayChoiceStore {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPU Control", isDirectory: true)
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent("sunshine-display.json")
    }

    static func load(fileManager: FileManager = .default) -> SunshineDisplayChoice {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SunshineDisplayChoice.self, from: data)
        else {
            return .mainDisplay()
        }
        return decoded
    }

    static func save(_ choice: SunshineDisplayChoice, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(choice)
        let temp = fileURL.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: temp, to: fileURL)
    }
}
