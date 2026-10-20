# Manual test plan — gpucontrol-pointerhelper (macOS VM)

Nothing here was compiled on Linux. Build on the Intel macOS 15.6+ (or 26) VM first.

## Build and install into the app folder

```bash
# From the feat/pointer-helper worktree root:
./app/scripts/build-pointer-helper.sh
cp app/pointer-helper/gpucontrol-pointerhelper \
  app/nvidia-card-control/nvidia-card-control/gpucontrol-pointerhelper
```

Open `app/nvidia-card-control/nvidia-card-control.xcodeproj` in Xcode, confirm `gpucontrol-pointerhelper` appears next to `nvmtlctl` (File System Synchronized Root Group), App Sandbox off, then build and run GPU Control.

## App UI

1. Sidebar has no separate Pointer row; Video → Sunshine only.
2. Sunshine → Service / Display / Encoding / Troubleshooting still show the hammer “Preview only” banner.
3. Sunshine → Pointer has no mock banner.
4. Toggle **Keep the pointer visible while typing** on.
5. If Helper shows **Needs Accessibility access**, click **Open Privacy Settings…**, enable GPU Control’s helper (`gpucontrol-pointerhelper`) under Accessibility, wait a few seconds, revisit the page (or toggle off/on). Helper should become **Running**.
6. Confirm `~/Library/LaunchAgents/com.bluemonkey.gpucontrol.pointerhelper.plist` exists, `launchctl print gui/$(id -u)/com.bluemonkey.gpucontrol.pointerhelper` succeeds, and the binary is under `~/Library/Application Support/GPU Control/` owned by the user (not root).
7. Toggle off: LaunchAgent removed, helper stops.

## Streamed pointer regression (the measured bug)

Setup: Sunshine streaming the macOS VM to Moonlight (absolute mouse). Moonlight remote-desktop mouse option already tried; leave absolute moves as Sunshine does today (`CGWarpMouseCursorPosition`).

1. Helper **Running**, Accessibility granted.
2. On the client, open TextEdit in the stream and type several characters so macOS hides the pointer while typing.
3. Move the pointer **only** via Sunshine absolute moves (client mouse move → warp on host). Do **not** click.
4. **Pass:** pointer becomes visible again within about a second of moving, without clicking the desktop.
5. **Fail (old behaviour):** pointer stays hidden until a real click on the desktop.
6. While holding a mouse button down on the client, warps must not nudge (no jitter). Release and move again — nudge resumes.
7. CPU: with no warps, Activity Monitor should show the helper well under 1 % idle.

## Helper probe

```bash
"~/Library/Application Support/GPU Control/gpucontrol-pointerhelper" --check
# exit 0 if trusted; exit 78 if Accessibility missing
cat "~/Library/Application Support/GPU Control/pointerhelper.state"
```
