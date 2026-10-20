# Known issues and work queue

This file is the fork's list of known problems and of work anyone with spare time or tokens can pick up. Each item says
what is known, what "done" looks like, and what it needs (hardware, a human at the machine). Labels on results follow
[CONTRIBUTING.md](CONTRIBUTING.md): read from source / builds / VM-tested on Turing / not tested. Reference hardware is
one RTX 2060 Super in a macOS 15.8.1 VM; nothing else has been tested.

When you finish or learn something, edit this file in the same change.

## Known issues

Only open problems are listed here. What has been fixed and measured is in [docs/H264.md](docs/H264.md).

| Issue | What is known | Label |
|---|---|---|
| A second H.264 encode session is refused | The encoder library allows one engine per process and keeps it reserved until the session object is released (`CFRelease`; `VTCompressionSessionInvalidate` alone is not enough). A second hardware session while the first is open fails with -12908 ("engine already in use in this process"). Upstream #206 reports the same on an RTX 2070 Super. | VM-tested on Turing |
| The encoder needs about 33 MiB (1080p) to 81 MiB (4K) of BAR1 unless built with `--low-bar` | The library maps its working buffers through the BAR1 window and zero-fills them. On a card with a 256 MB BAR1 and a busy desktop the map can fail and the session fails with -12908 ("engine bring-up failed"). `make_nvenc_t2d.py --low-bar` releases the windows after the zero-fill (see docs/H264.md); the peak while a session opens is still about 17 MB at 1080p and 67 MB at 4K. | VM-tested on Turing |
| Bitrate control is opt-in | Without `NVMTL_VT_RC=1` the encoder runs at constant QP 23 and ignores `AverageBitRate` (about 12 Mbit/s at 1080p on the synthetic clip, far more on noisy content). The controller holds a requested bitrate in short tests; it has not been run on varied content, at other resolutions or on other cards. | VM-tested on Turing |
| HEVC is experimental and opt-in | Baseline and optional speed flags pass four-size quality checks (44.3–44.7 dB mean Y PSNR). Direct-row reaches 318 vs 301 fps at 1080p; short-zero shows no gain. Standalone HEVC feedback tracks 2/4/8 Mbit/s, but changing-QP decode quality and full-plugin streaming need validation. Installed HEVC ignores bitrate requests and sent 203 Mbit/s on moving noise at a requested 25 Mbit/s. See docs/HEVC.md. | 8-bit speed/quality and standalone bitrate tracking VM-tested on Turing |
| No Man's Sky fails during initial loading/rendering | The native Intel build spends about 17 minutes loading shaders, then shows its fatal-error dialog. A captured signal-handler stack reaches address zero from `NVMTLArgumentEncoder setTexture:atIndex:` at its initial texture-retain call. Immediately beforehand the driver reports its 7472 MB heap budget exhausted, failed private-buffer allocations and texture spills to system RAM. The causal link between memory pressure and the null call is not yet established. See [docs/GAME-COMPATIBILITY.md](docs/GAME-COMPATIBILITY.md). | failure observed on Turing; stack/logs inspected; root cause unresolved |
| The encoder is registered in every process that makes a Metal device | That includes `ScreensharingAgent` and `loginwindow`, so a bad encoder would show up in screen sharing too. | read from logs, VM |
| Only one encoder library build is supported | `tools/make_nvenc_t2d.py` refuses any build other than the 2.2.0 `libnvenc_h264.dylib`; the 2.3.6 package ships the same bytes. | VM-tested on Turing |
| No display connected at boot means no GPU desktop | With 0 connected displays NVRMFB refuses to start framebuffer 0 and WindowServer renders in software until the next boot with a display. A dummy plug fixes it. | VM-tested on Turing |
| Test coverage is thin for video | The H.264 test uses a synthetic clip, 30 frames, four sizes. No real content, no long runs, no Parsec end to end. | VM-tested on Turing |
| Purple regression fixes need VM validation | CPU scheduling timestamps, LOD sampler variant lifetime, background function specialization, and legal stencil store options have source fixes and four focused `tools/test_metal_*.m` probes. Run installed/new plugin comparisons, including synchronous and ahead submission for timing. | read from source; not tested |
| ICB blit copy/reset run at encode time | Both methods mutate CPU slots immediately. Deferring only the mutations to commit breaks later render/compute ICB executes, which replay at encode time. Correct ordering needs command recording across encoders and event boundaries, with retained replay resources; keep both methods purple. `tools/test_metal_icb_copy.m` covers copy/reset then execute, late CPU source/destination encodes, and chained operations for render and both compute dispatch forms. | read from source; regression VM-tested on Turing (12 pass, 9 fail) |
| Ampere, Ada, laptops, macOS 26 | Not tested with any fork change. Upstream says macOS 26 works for some users. | not tested |
| Upstream issues that also affect this fork | See the upstream tracker: small-BAR flicker (#169, #183), Chromium/WebKit video decode (#175), plugin memory-safety crashes (#251, #150), OpenGL speed (#261). | not tested here |

## Telemetry

`tools/gpu_telemetry.m` and `nvmtlctl telemetry --json` provide an r610 read-only probe (read from source; not built or card-tested).
Build against NVIDIA 610.57.04 headers with `app/scripts/build-telemetry.sh` (or the clang line in that script). Run `tools/test_metal_telemetry.m` on macOS.
RUSD cached fan RPM/power/clocks/utilisation require firmware data already being published; freshness is unverified.
Fan percent, hotspot, normalized maximum clocks and the macOS per-PID user-client quota count need further ABI work.
The Status page polls `nvmtlctl telemetry --json` at 1 Hz while visible (value-or-error tiles; no fabricated zeros). Plugin stats publication remains design-only; see the telemetry research report in `.scratch/agents/`.

## Work queue

Roughly in order of value per effort. "Hardware" means it needs a real card and cannot be checked by reading code.

1. **Make `--low-bar` the default and shrink its peak.** Run `--low-bar` through longer sessions, other resolutions,
   moving content and repeated connects; then make it the default. Separately, the 8x-luma pool is still one contiguous
   map while it is zeroed (about 67 MB at 4K): zero it in pieces or let the GPU clear it. Done when a 4K session opens
   on a 256 MB-BAR card with a game and a screen-capture app running, and `tools/test_nvenc_h264.py` still passes.
   Needs: hardware. Risk: medium (binary patching).
2. **Let a second session open.** Decide between a plugin-side workaround (release the first session when a second is
   requested), another binary patch, or documenting why not (the 2060 Super has one NVENC engine). Done when
   `tools/test_nvenc_h264.py --overlap-required` passes, or `docs/H264.md` says why it cannot. Needs: hardware.
3. **Make the encoder cheaper on CPU.** The latest installed 1080p baselines cost 2.38 ms CPU/frame for H.264
   (421 fps) and 3.32 ms for HEVC (301 fps), close to their median callback latency. HEVC direct-row reduces this
   to 3.15 ms (318 fps). Profile capture, conversion, tiled writes and waits before attempting a GPU copy/tiling
   path. Opt-in `--direct-row` and `--short-zero` already cut H.264 idle-VM CPU from about 2.3 ms to 1.9 together
   (table in docs/H264.md). Done when throughput improves and CPU ms/frame falls in a repeatable hardware comparison. Needs: hardware.
4. **Validate bitrate control and decide its default.** Run `NVMTL_VT_RC=1` on real content (games, video, text) at
   720p to 4K and several client bitrates; record bitrate error and visible quality (PSNR with
   `tools/nvenc_psnr.m`). Done when the results are in `docs/H264.md` and the default is changed, or the reason it
   stays opt-in is written down. Needs: hardware.
5. **A repeatable H.264 benchmark and a Linux comparison.** `tools/bench_nvenc_h264.py` measures this side; the
   comparison needs the same card under Linux (ffmpeg `h264_nvenc`). Done when both numbers are in `docs/H264.md`.
6. **HEVC optimization and bitrate control.** All optional speed flags pass the four-size GPU quality regression.
   Direct-row improves 1080p throughput about 6%; short-zero showed no gain and remains off. Standalone feedback
   tracks 2/4/8 Mbit/s and passes nine sequential sessions. Next verify decode correctness with changing QP and
   full-plugin integration. Investigate capture-time engine bring-up mapping failures, then finish with a real game
   stream. Needs: an idle GPU; see docs/HEVC.md.
7. **Ampere/Ada encode.** Upstream issue #65 measured the classic layout at 42-49 dB on an RTX 3070 Laptop with a
   similar change. The gate is Turing-only. Needs: a tester with the card.
8. **Native encoder (research, architectural: ask first).** Today's encoder is upstream's closed binary with a patch.
   A native one means driving the NVENC engine (class 0xC4B7) ourselves; the engine's method interface is not
   documented, so this is reverse engineering. Done when a design note exists with what is known and what is not.
   Needs: hardware, a lot of time.
9. **OpenGL bind cost.** On Minecraft the render thread is CPU-bound at about 50k binds/s (about 20 us each) while the
   GPU idles; about 75% of descriptor sets are rebuilt, mostly on buffer-offset-only changes. First turn the ad-hoc
   counters into an env-gated, release-stripped feature plus a script, then try dynamic offsets. Needs: hardware.
10. **Small-BAR (256 MB) characterization.** Script a load that fills BAR1 and record the counters (#169). Read-only.
11. **CI.** The `tools/test_*.py` tests mostly need macOS and are not run by anything. A macOS runner that runs the
    ones that need no GPU would catch regressions. Adding CI is a dependency decision: ask first.
12. **Pascal research note.** Whether the kernel side can work without GSP firmware. Research only, no code.
13. **No Man's Sky loading/rendering crash.** Reproduce the null call from the first texture-retain instruction in
    `NVMTLArgumentEncoder setTexture:atIndex:`. Capture the original signal context and inspect the texture argument,
    its lifetime and the Objective-C retain import. Investigate the preceding GPU-memory exhaustion separately;
    lower texture pressure is an experiment, not a proven fix. Done when the native game reaches playable gameplay
    without the fatal dialog and a focused binding/lifetime regression passes. Needs: hardware and a controlled game
    run; preserve the shader cache. See [docs/GAME-COMPATIBILITY.md](docs/GAME-COMPATIBILITY.md).

## First non-prerelease target

The release target is playable native macOS No Man's Sky and a small model running in llama.cpp on the GPU.
Launching either process alone does not satisfy the target. Record the card, OS, settings/model, rendering or
inference correctness, performance and stability. For llama.cpp, compare with CPU output.

Current game observations on the RTX 2060 Super VM: Terraria works fine according to the tester (no measured FPS
or stability qualification yet). Factorio fails during mipmap staging with a buffer-map
allocation error after more than 127,000 live buffers; investigate buffer lifetime and allocation pressure.
KSP reaches atmospheric flight through OpenGL 4.1 but has low performance, disabled shader caching and BC7
decompression warnings. No Man's Sky fails during initial loading/rendering after shader translation, with a
null-call signal in argument-buffer texture binding and preceding GPU-memory exhaustion; gameplay is blocked.
These observations are baselines, not release qualification. llama.cpp remains untested.
