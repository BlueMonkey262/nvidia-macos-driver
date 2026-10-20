// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Pure “when to nudge” decisions for the pointer helper.
/// No CoreGraphics — the helper samples CG state and feeds this.
/// Kept free of AppKit so the same cases can be mirrored by the Linux self-check.
nonisolated enum PointerNudgeLogic {
    /// Default poll period (~60 Hz). Timer leeway is applied by the helper.
    static let defaultPollInterval: Double = 1.0 / 60.0

    /// Cap nudges to a few per second so a busy warp stream cannot flood HID.
    static let defaultMinNudgeInterval: Double = 0.25

    struct Input: Equatable, Sendable {
        /// Cursor location changed since the previous poll tick.
        var positionChanged: Bool
        /// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .mouseMoved)`.
        var secondsSinceLastMouseMoved: Double
        /// Upper bound on how long ago the position change happened (one poll interval).
        var positionChangeMaxAge: Double
        var mouseButtonDown: Bool
        var cursorVisible: Bool
        /// `CGDisplayShowCursor` was already paired for this hide episode.
        var alreadyShowedCursorThisHiddenEpisode: Bool
        var secondsSinceLastNudge: Double
        var minNudgeInterval: Double
    }

    struct Decision: Equatable, Sendable {
        var shouldNudge: Bool
        /// Call `CGDisplayShowCursor` once while hidden; never unbalance the show/hide counter.
        var shouldShowCursor: Bool
    }

    /// Sunshine absolute moves use `CGWarpMouseCursorPosition`, which does not post a mouse-moved
    /// event, so WindowServer’s “hide pointer while typing” state stays set. A warp is a position
    /// change whose last real HID mouse-moved event is older than that change.
    static func decide(_ input: Input) -> Decision {
        if input.mouseButtonDown {
            return Decision(shouldNudge: false, shouldShowCursor: false)
        }

        let isWarp = input.positionChanged
            && input.secondsSinceLastMouseMoved > input.positionChangeMaxAge
        if !isWarp {
            return Decision(shouldNudge: false, shouldShowCursor: false)
        }

        let rateLimited = input.secondsSinceLastNudge < input.minNudgeInterval
        let shouldNudge = !rateLimited
        let shouldShowCursor = shouldNudge
            && !input.cursorVisible
            && !input.alreadyShowedCursorThisHiddenEpisode
        return Decision(shouldNudge: shouldNudge, shouldShowCursor: shouldShowCursor)
    }
}
