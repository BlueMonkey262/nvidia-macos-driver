#!/usr/bin/env python3
# Copyright (c) 2026 BlueMonkey
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Linux-runnable mirror of PointerNudgeLogic.decide / PointerNudgeLogicCheck.

Run from the worktree root:
  python3 tests/pointer_nudge_selfcheck.py
Exit 0 on pass, 1 on failure.
"""

from __future__ import annotations

DEFAULT_POLL_INTERVAL = 1.0 / 60.0
DEFAULT_MIN_NUDGE_INTERVAL = 0.25


def decide(
    *,
    position_changed: bool,
    seconds_since_last_mouse_moved: float,
    position_change_max_age: float,
    mouse_button_down: bool,
    cursor_visible: bool,
    already_showed_cursor_this_hidden_episode: bool,
    seconds_since_last_nudge: float,
    min_nudge_interval: float,
) -> tuple[bool, bool]:
    """Return (should_nudge, should_show_cursor). Must match PointerNudgeLogic.swift."""
    if mouse_button_down:
        return False, False

    is_warp = position_changed and (
        seconds_since_last_mouse_moved > position_change_max_age
    )
    if not is_warp:
        return False, False

    rate_limited = seconds_since_last_nudge < min_nudge_interval
    should_nudge = not rate_limited
    should_show_cursor = (
        should_nudge
        and not cursor_visible
        and not already_showed_cursor_this_hidden_episode
    )
    return should_nudge, should_show_cursor


def resolve_status(
    *,
    binary_installed: bool,
    plist_installed: bool,
    launchd_loaded: bool,
    state_file_value: str | None,
) -> str:
    """Mirror PointerHelperStatusLogic.resolve — returns status name."""
    if state_file_value == "needs_accessibility":
        return "needsAccessibility"
    if launchd_loaded and binary_installed:
        return "installedAndRunning"
    if binary_installed or plist_installed:
        if not launchd_loaded:
            return "error"
        return "installedAndRunning"
    return "notInstalled"


def main() -> int:
    poll = DEFAULT_POLL_INTERVAL
    min_nudge = DEFAULT_MIN_NUDGE_INTERVAL
    failures: list[str] = []

    def check(name: str, expect_nudge: bool, expect_show: bool, **kwargs: object) -> None:
        nudge, show = decide(**kwargs)  # type: ignore[arg-type]
        if nudge != expect_nudge:
            failures.append(f"{name}: shouldNudge want {expect_nudge} got {nudge}")
        if show != expect_show:
            failures.append(f"{name}: shouldShowCursor want {expect_show} got {show}")

    check(
        "warp_nudges",
        True,
        False,
        position_changed=True,
        seconds_since_last_mouse_moved=1.0,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=True,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "warp_shows_when_hidden",
        True,
        True,
        position_changed=True,
        seconds_since_last_mouse_moved=1.0,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "no_show_twice_per_episode",
        True,
        False,
        position_changed=True,
        seconds_since_last_mouse_moved=1.0,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=True,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "real_mouse_moved_not_warp",
        False,
        False,
        position_changed=True,
        seconds_since_last_mouse_moved=poll / 2,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "no_position_change",
        False,
        False,
        position_changed=False,
        seconds_since_last_mouse_moved=5.0,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "button_down_blocks",
        False,
        False,
        position_changed=True,
        seconds_since_last_mouse_moved=1.0,
        position_change_max_age=poll,
        mouse_button_down=True,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge,
        min_nudge_interval=min_nudge,
    )
    check(
        "rate_limited",
        False,
        False,
        position_changed=True,
        seconds_since_last_mouse_moved=1.0,
        position_change_max_age=poll,
        mouse_button_down=False,
        cursor_visible=False,
        already_showed_cursor_this_hidden_episode=False,
        seconds_since_last_nudge=min_nudge / 2,
        min_nudge_interval=min_nudge,
    )

    status_cases = [
        (
            "not_installed",
            "notInstalled",
            dict(
                binary_installed=False,
                plist_installed=False,
                launchd_loaded=False,
                state_file_value=None,
            ),
        ),
        (
            "running",
            "installedAndRunning",
            dict(
                binary_installed=True,
                plist_installed=True,
                launchd_loaded=True,
                state_file_value="running",
            ),
        ),
        (
            "needs_a11y",
            "needsAccessibility",
            dict(
                binary_installed=True,
                plist_installed=True,
                launchd_loaded=True,
                state_file_value="needs_accessibility",
            ),
        ),
        (
            "installed_not_running",
            "error",
            dict(
                binary_installed=True,
                plist_installed=True,
                launchd_loaded=False,
                state_file_value=None,
            ),
        ),
    ]
    for name, expect, kwargs in status_cases:
        got = resolve_status(**kwargs)
        if got != expect:
            failures.append(f"status {name}: want {expect} got {got}")

    if failures:
        for line in failures:
            print(f"FAIL: {line}")
        return 1
    print(f"ok: {7 + len(status_cases)} pointer nudge / status cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
