# Known issues and work queue

This file is the fork's list of known problems and of work anyone with spare time or tokens can pick up. Each item says
what is known, what "done" looks like, and what it needs (hardware, a human at the machine). Labels on results follow
[CONTRIBUTING.md](CONTRIBUTING.md): read from source / builds / VM-tested on Turing / not tested. Reference hardware is
one RTX 2060 Super in a macOS 15.8.1 VM; nothing else has been tested.

When you finish or learn something, edit this file in the same change.

## Known issues

| Issue | What is known | Label |
|---|---|---|
| Second H.264 encode session is refused | Opening a second hardware session while the first is open fails with -12908 (`libnvenc_h264` logs "engine already in use in this process"). Sunshine does this and falls back to software x264. Upstream #206 reports the same on an RTX 2070 Super. | VM-tested on Turing |
| Bitrate is ignored | The encoder runs at constant QP 23, so `AverageBitRate` has no effect (about 12 Mbit/s at 1080p, 20 Mbit/s at 1440p on the synthetic test clip). | VM-tested on Turing |
| HEVC encode is off | Upstream reports a bitstream problem separate from the tiling one. | not tested here |
| The encoder is registered in every process that makes a Metal device | That includes `ScreensharingAgent` and `loginwindow`, so a bad encoder would show up in screen sharing too. | read from logs, VM |
| Only the 2.2.0 encoder library is supported | `tools/make_nvenc_t2d.py` refuses any other build. Whether 2.3.x packages ship the same encoder is not checked. | read from source |
| No display connected at boot means no GPU desktop | With 0 connected displays NVRMFB refuses to start framebuffer 0 and WindowServer renders in software until the next boot with a display. A dummy plug fixes it. | VM-tested on Turing |
| Test coverage is thin for video | The H.264 test uses a synthetic clip, 30 frames, four sizes. No real content, no long runs, no Sunshine/Parsec end to end. | VM-tested on Turing |
| Ampere, Ada, laptops, macOS 26 | Not tested with any fork change. Upstream says macOS 26 works for some users. | not tested |
| Upstream issues that also affect this fork | See the upstream tracker: small-BAR flicker (#169, #183), Chromium/WebKit video decode (#175), plugin memory-safety crashes (#251, #150), OpenGL speed (#261). | not tested here |

## Work queue

Roughly in order of value per effort. "Hardware" means it needs a real card and cannot be checked by reading code.

1. **Let Sunshine open its second session.** Read the "engine already in use" check in `libnvenc_h264.dylib` and decide:
   a plugin-side workaround (release the first session when a second is requested), another binary patch, or accept it
   (the 2060 Super has one NVENC engine). Done when `tools/test_nvenc_h264.py --overlap-required` passes, or
   `docs/H264.md` says why it cannot. Needs: hardware, a human to run Sunshine. Risk: low (user space).
2. **Honour `AverageBitRate`.** Find where the encoder sets its QP and whether rate control can be driven from
   VideoToolbox properties. Done when the bitrate follows the requested value within about 20% on the test clip.
   Needs: hardware. Risk: medium (more binary patching).
3. **Sync with upstream.** Merge `upstream/main` (2.3.x), re-check that the encoder library is unchanged, re-run the
   H.264 test. Deploying anything under `kexts/` needs a human to boot it. Needs: hardware. Risk: medium.
4. **A repeatable H.264 benchmark and a Linux comparison.** `tools/bench_nvenc_h264.py` measures this side; the
   comparison needs the same card under Linux (ffmpeg `h264_nvenc`). Done when both numbers are in `docs/H264.md`.
5. **Native encoder (research, architectural: ask first).** Today's encoder is upstream's closed binary with a patch.
   A native one means driving the NVENC engine (class 0xC4B7) ourselves; the engine's method interface is not
   documented, so this is reverse engineering. Done when a design note exists with what is known and what is not.
   Needs: hardware, a lot of time.
6. **Ampere/Ada encode.** Upstream issue #65 measured the classic layout at 42-49 dB on an RTX 3070 Laptop with a
   similar change. The gate is Turing-only. Needs: a tester with the card.
7. **HEVC encode.** Find the second bitstream problem. Needs: hardware.
8. **OpenGL bind cost.** On Minecraft the render thread is CPU-bound at about 50k binds/s (about 20 us each) while the
   GPU idles; about 75% of descriptor sets are rebuilt, mostly on buffer-offset-only changes. First turn the ad-hoc
   counters into an env-gated, release-stripped feature plus a script, then try dynamic offsets. Needs: hardware.
9. **Small-BAR (256 MB) characterization.** Script a load that fills BAR1 and record the counters (#169). Read-only.
10. **CI.** The 47 `tools/test_*.py` tests mostly need macOS and are not run by anything. A macOS runner that runs the
    ones that need no GPU would catch regressions. Adding CI is a dependency decision: ask first.
11. **Pascal research note.** Whether the kernel side can work without GSP firmware. Research only, no code.
