// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import ApplicationServices
import CoreGraphics
import Foundation

/// Exit when Accessibility is not granted (`--check`). Distinct so the app can show
/// “Needs Accessibility access” without treating it as a generic failure.
private let exitNeedsAccessibility: Int32 = 78

private let helperLabel = "gpucontrol-pointerhelper"
private let stateFileName = "pointerhelper.state"

@main
enum PointerHelperMain {
    static func main() {
        let args = CommandLine.arguments
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

            if decision.shouldNudge {
                postNudge(at: position)
                lastNudgeAt = now
            }
        }
        timer.resume()

        dispatchMain()
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
