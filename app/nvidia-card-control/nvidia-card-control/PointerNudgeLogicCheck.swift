// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Small nudge-decision self-check (no XCTest target). Call `failures()` from a DEBUG assert.
/// Mirror of `tests/pointer_nudge_selfcheck.py` — keep the cases in sync.
nonisolated enum PointerNudgeLogicCheck {
    static func failures() -> [String] {
        var failures: [String] = []
        let poll = PointerNudgeLogic.defaultPollInterval
        let minNudge = PointerNudgeLogic.defaultMinNudgeInterval

        func check(
            _ name: String,
            input: PointerNudgeLogic.Input,
            expectNudge: Bool,
            expectShow: Bool
        ) {
            let decision = PointerNudgeLogic.decide(input)
            if decision.shouldNudge != expectNudge {
                failures.append("\(name): shouldNudge want \(expectNudge) got \(decision.shouldNudge)")
            }
            if decision.shouldShowCursor != expectShow {
                failures.append("\(name): shouldShowCursor want \(expectShow) got \(decision.shouldShowCursor)")
            }
        }

        check(
            "warp_nudges",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: 1.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: true,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: true,
            expectShow: false
        )

        check(
            "warp_shows_when_hidden",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: 1.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: true,
            expectShow: true
        )

        check(
            "no_show_twice_per_episode",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: 1.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: true,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: true,
            expectShow: false
        )

        check(
            "real_mouse_moved_not_warp",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: poll / 2,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: false,
            expectShow: false
        )

        check(
            "no_position_change",
            input: PointerNudgeLogic.Input(
                positionChanged: false,
                secondsSinceLastMouseMoved: 5.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: false,
            expectShow: false
        )

        check(
            "button_down_blocks",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: 1.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: true,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge,
                minNudgeInterval: minNudge
            ),
            expectNudge: false,
            expectShow: false
        )

        check(
            "rate_limited",
            input: PointerNudgeLogic.Input(
                positionChanged: true,
                secondsSinceLastMouseMoved: 1.0,
                positionChangeMaxAge: poll,
                mouseButtonDown: false,
                cursorVisible: false,
                alreadyShowedCursorThisHiddenEpisode: false,
                secondsSinceLastNudge: minNudge / 2,
                minNudgeInterval: minNudge
            ),
            expectNudge: false,
            expectShow: false
        )

        return failures
    }
}
