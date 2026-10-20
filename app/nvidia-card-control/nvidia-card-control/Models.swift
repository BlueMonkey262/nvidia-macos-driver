// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// JSON from `nvmtlctl status --json`.
struct DriverStatus: Codable, Equatable, Sendable {
    var tool: String
    var macos: String
    var build: String
    var package: String
    var gpu: String
    var metal: String
    var kexts: String
    var pluginSha8: String
    var pluginBytes: Int
    var turingH264EncoderLib: String
    var turingHevcEncoderLib: String
    var bootArgs: String
    var cacheKey: String

    enum CodingKeys: String, CodingKey {
        case tool, macos, build, package, gpu, metal, kexts
        case pluginSha8 = "plugin_sha8"
        case pluginBytes = "plugin_bytes"
        case turingH264EncoderLib = "turing_h264_encoder_lib"
        case turingHevcEncoderLib = "turing_hevc_encoder_lib"
        case bootArgs = "boot_args"
        case cacheKey = "cache_key"
    }

    var hasGPU: Bool {
        let trimmed = gpu.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    var hasLoadedKexts: Bool {
        let trimmed = kexts.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    var reportsMetalSupport: Bool {
        let trimmed = metal.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}

/// One row from `nvmtlctl conf list --json`.
struct ConfEntry: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var defaultValue: String
    var value: String
    var description: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case defaultValue = "default"
        case value
        case description
    }

    var isAtDefault: Bool {
        value == defaultValue
    }

    var isEnabledFlag: Bool {
        value != "0"
    }
}

/// JSON from `nvmtlctl caches status --json`.
struct CachesStatus: Codable, Equatable, Sendable {
    var count: Int
    var paths: [String]
}

/// Knobs the control panel edits. Values must match `nvmtlctl` KNOBS names.
nonisolated enum ConfKey {
    static let framebufferFetchWS = "NVMTL_FBFETCH_WS"
    static let videoBitrateControl = "NVMTL_VT_RC"
    static let nvencHEVC = "NVMTL_NVENC_HEVC"
    static let noNVENC = "NVMTL_NO_NVENC"
    static let noVTSpecHook = "NVMTL_NO_VT_SPEC_HOOK"
    static let poolKeep = "NVMTL_POOL_KEEP"
    static let asyncTexUpload = "NVMTL_ASYNC_TEX_UPLOAD"
    static let vramHeadroomMB = "NVMTL_VRAM_HEADROOM_MB"

    /// Characters `nvmtlctl conf set` accepts in a value.
    static let allowedValueCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    static func isValidConfValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { allowedValueCharacterSet.contains($0) }
    }

    static func clampPoolKeep(_ value: Int) -> Int {
        min(256, max(0, value))
    }
}

nonisolated enum JSONDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static func decodeStatus(from data: Data) throws -> DriverStatus {
        try decoder.decode(DriverStatus.self, from: data)
    }

    static func decodeConfList(from data: Data) throws -> [ConfEntry] {
        try decoder.decode([ConfEntry].self, from: data)
    }

    static func decodeCachesStatus(from data: Data) throws -> CachesStatus {
        try decoder.decode(CachesStatus.self, from: data)
    }

    static func decodeStatus(fromUTF8 string: String) throws -> DriverStatus {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Status JSON is not valid UTF-8.")
            )
        }
        return try decodeStatus(from: data)
    }

    static func decodeConfList(fromUTF8 string: String) throws -> [ConfEntry] {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Conf list JSON is not valid UTF-8.")
            )
        }
        return try decodeConfList(from: data)
    }

    static func decodeCachesStatus(fromUTF8 string: String) throws -> CachesStatus {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Caches status JSON is not valid UTF-8.")
            )
        }
        return try decodeCachesStatus(from: data)
    }
}

extension DriverStatus {
    static let previewSample = DriverStatus(
        tool: "0.1",
        macos: "26.0",
        build: "25A354",
        package: "2.3.7-v0.2",
        gpu: "NVIDIA GeForce RTX 2080 Ti",
        metal: "Metal GPUFamily macOS 2",
        kexts: "com.nullmoth.NVRM (1.0),com.nullmoth.NMDRM (1.0)",
        pluginSha8: "abcd1234",
        pluginBytes: 4_200_000,
        turingH264EncoderLib: "yes",
        turingHevcEncoderLib: "yes",
        bootArgs: "-v keepsyms=1",
        cacheKey: "25A354+2.3.7-v0.2+abcd1234"
    )
}

extension ConfEntry {
    static let previewSamples: [ConfEntry] = [
        ConfEntry(
            key: ConfKey.framebufferFetchWS,
            defaultValue: "0",
            value: "0",
            description: "Let WindowServer read the framebuffer in shaders (off by default; unproven)"
        ),
        ConfEntry(
            key: ConfKey.videoBitrateControl,
            defaultValue: "0",
            value: "1",
            description: "Bitrate control for hardware video encode (H.264/HEVC on Turing)"
        ),
        ConfEntry(
            key: ConfKey.nvencHEVC,
            defaultValue: "0",
            value: "0",
            description: "Hardware HEVC encode on Turing (experimental)"
        ),
        ConfEntry(
            key: ConfKey.noNVENC,
            defaultValue: "0",
            value: "0",
            description: "Keep video encode on Apple's encoder"
        ),
        ConfEntry(
            key: ConfKey.noVTSpecHook,
            defaultValue: "0",
            value: "0",
            description: "Turn off the VideoToolbox low-latency fix that Sunshine needs"
        ),
        ConfEntry(
            key: ConfKey.poolKeep,
            defaultValue: "16",
            value: "16",
            description: "Command pools kept per process (0-256); lower avoids the per-process client limit"
        ),
        ConfEntry(
            key: ConfKey.asyncTexUpload,
            defaultValue: "0",
            value: "1",
            description: "Upload textures without waiting for the GPU (faster loading)"
        ),
        ConfEntry(
            key: ConfKey.vramHeadroomMB,
            defaultValue: "256",
            value: "256",
            description: "VRAM kept free before images spill to system memory"
        ),
    ]
}

extension CachesStatus {
    static let previewSample = CachesStatus(
        count: 2,
        paths: [
            "/Library/Caches/com.apple.iconservices.store",
            "/private/var/folders/xx/yyyy/C/com.apple.iconservices",
        ]
    )
}
