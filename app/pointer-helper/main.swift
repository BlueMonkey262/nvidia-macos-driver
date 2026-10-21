// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

/// Exit when Accessibility is not granted (`--check`). Distinct so the app can show
/// “Needs Accessibility access” without treating it as a generic failure.
private let exitNeedsAccessibility: Int32 = 78

private let helperLabel = "gpucontrol-pointerhelper"
private let stateFileName = "pointerhelper.state"

@main
enum PointerHelperMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--reveal") {
            revealPointer()
            exit(0)
        }
        if args.contains("--check") {
            if AXIsProcessTrusted() {
                writeState("trusted")
                exit(0)
            }
            fputs("\(helperLabel): Accessibility access is required to post pointer events.\n", stderr)
            writeState("needs_accessibility")
            exit(exitNeedsAccessibility)
        }

        if !AXIsProcessTrusted() {
            // Log once, then wait under KeepAlive until the user grants access.
            fputs("\(helperLabel): Accessibility access is required to post pointer events.\n", stderr)
            writeState("needs_accessibility")
            // Ask once so macOS shows its prompt and lists this binary under Accessibility.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            waitUntilTrusted()
        }

        writeState("running")
        runLoop()
    }

    private static func waitUntilTrusted() {
        while !AXIsProcessTrusted() {
            writeState("needs_accessibility")
            Thread.sleep(forTimeInterval: 5)
        }
        writeState("running")
    }

    private static func runLoop() {
        let pollInterval = PointerNudgeLogic.defaultPollInterval
        let minNudgeInterval = PointerNudgeLogic.defaultMinNudgeInterval
        // Generous leeway keeps idle wakeups cheap; stay well under 1 % CPU when idle.
        let leewayMs = max(1, Int((pollInterval * 0.5) * 1000))

        var lastPosition: CGPoint?
        var lastNudgeAt = Date.distantPast
        var typingSeen = false
        var lastRevealAt = Date.distantPast

        // Serial queue so ticks never overlap (shared nudge / cursor episode state).
        let queue = DispatchQueue(label: "com.bluemonkey.gpucontrol.pointerhelper")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: pollInterval,
            leeway: .milliseconds(leewayMs)
        )
        timer.setEventHandler {
            let now = Date()
            let position = CGEvent(source: nil)?.location ?? .zero
            let positionChanged: Bool
            if let lastPosition {
                positionChanged = position.x != lastPosition.x || position.y != lastPosition.y
            } else {
                positionChanged = false
            }
            lastPosition = position

            // CGCursorIsVisible() is unavailable on current macOS, so the hidden state cannot be read.
            // Only a real (genuine-looking) mouse-moved event is posted; the show/hide counter is not touched.
            let cursorVisible = true
            let secondsSinceMouseMoved = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .mouseMoved
            )
            let buttonDown = mouseButtonDown()
            let secondsSinceLastNudge = now.timeIntervalSince(lastNudgeAt)

            let decision = PointerNudgeLogic.decide(
                PointerNudgeLogic.Input(
                    positionChanged: positionChanged,
                    secondsSinceLastMouseMoved: secondsSinceMouseMoved,
                    positionChangeMaxAge: pollInterval,
                    mouseButtonDown: buttonDown,
                    cursorVisible: cursorVisible,
                    alreadyShowedCursorThisHiddenEpisode: false,
                    secondsSinceLastNudge: secondsSinceLastNudge,
                    minNudgeInterval: minNudgeInterval
                )
            )

            // The hide-while-typing pointer stays hidden until a new process registers with
            // WindowServer (VM-tested: a fresh process calling CGSMainConnectionID restores it;
            // repeated calls from a long-running process do not). Once typing pauses, spawn one.
            let secondsSinceKey = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .keyDown
            )
            if secondsSinceKey < 0.5 {
                typingSeen = true
            } else if typingSeen && now.timeIntervalSince(lastRevealAt) >= 5 {
                typingSeen = false
                lastRevealAt = now
                spawnReveal()
            }

            if decision.shouldNudge {
                postNudge(at: position)
                lastNudgeAt = now
            }
        }
        timer.resume()

        dispatchMain()
    }

    /// Re-run this binary with `--reveal`; the new process does the work and exits.
    private static let revealBundleName = "GPU Control Pointer.app"

    /// Only a Dock-visible app launched through LaunchServices that creates an NSApplication
    /// restores the pointer (VM-tested: a raw child process and an LSUIElement app did not). The helper builds that tiny app itself:
    /// its own binary plus an Info.plist and the GPU Control icon.
    private static func spawnReveal() {
        guard let bundle = ensureRevealBundle() else {
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        child.arguments = ["-n", bundle.path, "--args", "--reveal"]
        try? child.run()
    }

    private static func ensureRevealBundle() -> URL? {
        let fm = FileManager.default
        let bundle = supportDirectory().appendingPathComponent(revealBundleName, isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let executable = macOS.appendingPathComponent("gpucontrol-pointerreveal")
        let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Refresh the copy when the helper binary changed (same size and date means unchanged).
        func stamp(_ url: URL) -> String {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return "\(attrs?[.size] ?? 0)-\(attrs?[.modificationDate] ?? Date.distantPast)"
        }
        if fm.fileExists(atPath: executable.path), stamp(executable) == stamp(selfURL) {
            return bundle
        }
        do {
            try? fm.removeItem(at: bundle)
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try fm.copyItem(at: selfURL, to: executable)
            try? fm.setAttributes([.modificationDate: (try? selfURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()], ofItemAtPath: executable.path)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>gpucontrol-pointerreveal</string>
            <key>CFBundleIdentifier</key><string>com.bluemonkey.gpucontrol.pointerreveal</string>
            <key>CFBundleName</key><string>GPU Control</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleIconFile</key><string>AppIcon</string>
            </dict></plist>
            """
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
            let icon = URL(fileURLWithPath: "/Applications/nvidia-card-control.app/Contents/Resources/AppIcon.icns")
            if fm.fileExists(atPath: icon.path) {
                try? fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
            }
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["-f", "-s", "-", bundle.path]
            try sign.run()
            sign.waitUntilExit()
            return bundle
        } catch {
            return nil
        }
    }

    /// Creating the NSApplication is what restores the pointer (VM-tested: a process that only
    /// connected to SkyLight, or linked AppKit without creating it, did not).
    private static func revealPointer() {
        _ = NSApplication.shared
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func mouseButtonDown() -> Bool {
        for button in [CGMouseButton.left, .right, .center] {
            if CGEventSource.buttonState(.combinedSessionState, button: button) {
                return true
            }
        }
        return false
    }

    /// Hide-while-typing (per app) clears on a mouseMoved that carries real movement; Sunshine's
    /// absolute moves have zero delta, so nudge one pixel and straight back with non-zero deltas.
    private static func postNudge(at location: CGPoint) {
        let out = CGPoint(x: location.x + 1, y: location.y)
        postMove(to: out, dx: 1, dy: 0)
        postMove(to: location, dx: -1, dy: 0)
    }

    private static func postMove(to point: CGPoint, dx: Int64, dy: Int64) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        event.post(tap: .cghidEventTap)
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPU Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func writeState(_ value: String) {
        let url = supportDirectory().appendingPathComponent(stateFileName)
        let body = "state=\(value)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
