// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CoreGraphics
import Foundation

/// Tiny CLI bundled next to nvmtlctl: list displays as JSON, or launch Sunshine after
/// resolving a stable display choice into today's `output_name`.
@main
enum SunshineToolMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fputs("usage: gpucontrol-sunshine-tool displays --json | launch\n", stderr)
            exit(2)
        }
        switch command {
        case "displays":
            if !args.contains("--json") {
                fputs("usage: gpucontrol-sunshine-tool displays --json\n", stderr)
                exit(2)
            }
            do {
                let json = try DisplaysCommand.encodeJSON(DisplaysCommand.enumerate())
                fputs(json, stdout)
                if !json.hasSuffix("\n") { fputs("\n", stdout) }
                exit(0)
            } catch {
                fputs("gpucontrol-sunshine-tool: \(error)\n", stderr)
                exit(1)
            }
        case "launch":
            do {
                try LaunchCommand.run()
                exit(0)
            } catch {
                fputs("gpucontrol-sunshine-tool: \(error)\n", stderr)
                // Never fail to start Sunshine because of a display mismatch.
                _ = openSunshine()
                exit(1)
            }
        default:
            fputs("usage: gpucontrol-sunshine-tool displays --json | launch\n", stderr)
            exit(2)
        }
    }
}

// MARK: - displays --json

nonisolated enum DisplaysCommand {
    static func enumerate() -> [SunshineDisplayInfo] {
        let mainID = CGMainDisplayID()
        let online = SunshineDisplayMirroring.onlineDisplayIDs()
        let screensByID = screenMap()
        return online.map { id in
            let bounds = CGDisplayBounds(id)
            let pixels = pixelSize(id)
            let refresh = refreshRate(id)
            let mirrored = CGDisplayMirrorsDisplay(id)
            let mirrorOf: UInt32? = mirrored == kCGNullDirectDisplay ? nil : UInt32(mirrored)
            let name: String
            if let screen = screensByID[id] {
                let localized = screen.localizedName
                name = localized.isEmpty ? "Display \(id)" : localized
            } else {
                name = "Display \(id)"
            }
            return SunshineDisplayInfo(
                id: UInt32(id),
                name: name,
                pixelWidth: pixels.width,
                pixelHeight: pixels.height,
                pointWidth: Double(bounds.width),
                pointHeight: Double(bounds.height),
                refreshHz: refresh > 0 ? refresh : nil,
                isMain: id == mainID,
                mirrorOf: mirrorOf,
                builtIn: CGDisplayIsBuiltin(id) != 0,
                gpu: nil
            )
        }
    }

    static func encodeJSON(_ displays: [SunshineDisplayInfo]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(displays)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SunshineToolError.jsonNotUTF8
        }
        return text
    }

    private static func screenMap() -> [CGDirectDisplayID: NSScreen] {
        var map: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                map[CGDirectDisplayID(number.uint32Value)] = screen
            }
        }
        return map
    }

    private static func pixelSize(_ id: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(id) {
            return (Int(mode.pixelWidth), Int(mode.pixelHeight))
        }
        return (Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }

    private static func refreshRate(_ id: CGDirectDisplayID) -> Double {
        if let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 {
            return mode.refreshRate
        }
        return 0
    }
}

// MARK: - launch

nonisolated enum LaunchCommand {
    static func run() throws {
        let choice = SunshineDisplayChoiceStore.load()
        let displays = DisplaysCommand.enumerate()
        let mainID = CGMainDisplayID()

        let useMain: Bool
        let resolvedID: CGDirectDisplayID
        if choice.useMainDisplay {
            useMain = true
            resolvedID = mainID
        } else if let name = choice.matchName,
                  let w = choice.matchPixelWidth,
                  let h = choice.matchPixelHeight,
                  let match = displays.first(where: {
                      $0.name == name && $0.pixelWidth == w && $0.pixelHeight == h
                  })
        {
            useMain = false
            resolvedID = CGDirectDisplayID(match.id)
        } else {
            useMain = true
            resolvedID = mainID
        }

        try applyOutputName(displayID: resolvedID, useMain: useMain)

        if choice.mirrorEnabled {
            SunshineDisplayMirroring.setMirrored(true, rootDisplay: resolvedID)
        }

        if !openSunshine() {
            throw SunshineToolError.openFailed
        }
    }

    private static func applyOutputName(displayID: CGDirectDisplayID, useMain: Bool) throws {
        let store = SunshineConfigStore()
        var doc = try store.load()
        if useMain {
            doc.removeValue(forKey: "output_name")
        } else {
            doc.setValue(String(displayID), forKey: "output_name")
        }
        try store.save(doc)
    }
}

@discardableResult
nonisolated func openSunshine() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Sunshine"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

nonisolated enum SunshineToolError: Error, CustomStringConvertible {
    case jsonNotUTF8
    case openFailed

    var description: String {
        switch self {
        case .jsonNotUTF8: return "JSON was not UTF-8"
        case .openFailed: return "open -a Sunshine failed"
        }
    }
}
