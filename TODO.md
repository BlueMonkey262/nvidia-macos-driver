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
| Surface upload blocking policy needs VM validation | Surface uploads scope a thread-local NVK policy: event wait immediately, or 50 us timed sleep when events are off/unavailable. Scoped event errors fall back for that call without changing process-wide policy; existing completion/fault/deadline checks remain. Rebuild NVK as well as the plugin; older NVK keeps the old policy. `tools/test_metal_surface_wait.m` reports CPU time, fault retries and actual thread-local policy restoration. | read from source; not tested |
| Surface upload seed probe packaging needs VM validation | Claude reports the hand-loaded plugin builds with 0 errors and its seed path passes on the macOS 26.7.1 Turing VM when the probe's unlock interposer is in a linked dylib; the installed driver fails the unlock-error retry assertion. The committed probe now links `tools/nvmtl_interposer_surface_seed.c` separately. This packaging is not tested; the unchanged-seed skip already existed and no speedup is claimed. | VM-tested on Turing (seed plugin, reported by Claude); probe packaging not tested |
| A second H.264 encode session is refused | The encoder library allows one engine per process and keeps it reserved until the session object is released (`CFRelease`; `VTCompressionSessionInvalidate` alone is not enough). A second hardware session while the first is open fails with -12908 ("engine already in use in this process"). Upstream #206 reports the same on an RTX 2070 Super. | VM-tested on Turing |
| The encoder needs about 33 MiB (1080p) to 81 MiB (4K) of BAR1 unless built with `--low-bar` | The library maps its working buffers through the BAR1 window and zero-fills them. On a card with a 256 MB BAR1 and a busy desktop the map can fail and the session fails with -12908 ("engine bring-up failed"). `make_nvenc_t2d.py --low-bar` releases the windows after the zero-fill (see docs/H264.md); the peak while a session opens is still about 17 MB at 1080p and 67 MB at 4K. | VM-tested on Turing |
| Bitrate control is opt-in | Without `NVMTL_VT_RC=1` the encoder runs at constant QP 23 and ignores `AverageBitRate` (about 12 Mbit/s at 1080p on the synthetic clip, far more on noisy content). The controller holds a requested bitrate in short tests; it has not been run on varied content, at other resolutions or on other cards. | VM-tested on Turing |
| HEVC encode is off | Upstream reports a bitstream problem separate from the tiling one. | not tested here |
| The encoder is registered in every process that makes a Metal device | That includes `ScreensharingAgent` and `loginwindow`, so a bad encoder would show up in screen sharing too. | read from logs, VM |
| Only one encoder library build is supported | `tools/make_nvenc_t2d.py` refuses any build other than the 2.2.0 `libnvenc_h264.dylib`; the 2.3.6 package ships the same bytes. | VM-tested on Turing |
| No display connected at boot means no GPU desktop | With 0 connected displays NVRMFB refuses to start framebuffer 0 and WindowServer renders in software until the next boot with a display. A dummy plug fixes it. | VM-tested on Turing |
| Test coverage is thin for video | The H.264 test uses a synthetic clip, 30 frames, four sizes. No real content, no long runs, no Parsec end to end. | VM-tested on Turing |
| Plugin specialization review fixes need VM validation | Both async function APIs now do creation off the caller; both FC translator entry sites share a leaf mutex. Expanded `tools/test_metal_async_specialize.m` checks snapshots, sync/async concurrency, errors and GPU results. The portable fake-translator lock harness passes; Metal probe not built here. | read from source; not tested on VM |
| Device-loss quarantine review needs VM validation | Ahead/direct `-2` inflights now transfer to an explicit process-lifetime quarantine, preserving the created fence and prologue; uncertain GPU resources stay retained. Portable ownership harness passes with fake Vulkan types; real loss/timeout cleanup not tested. | read from source; not tested on VM |
| Kernel timing review fixes need VM validation | `kernelStartTime`/`kernelEndTime` report the CPU scheduling window of the first part only, remain readable in scheduled handlers, and now return zero on error. Expanded `tools/test_metal_kernel_timing.m` covers post-scheduling error, repeated reads and a subsequent empty buffer; ratings document the multipart limitation. | read from source; not tested on VM |
| Map diagnostics review needs VM validation | Own-map census and failure counts are atomic; failures 1..8 and every 512th emit one combined diagnostic. Portable fake-mapper harness verifies throttling, all fields and concurrent bucket totals; real allocation-failure stress not tested. | read from source; not tested on VM |
| Pool retention tuning needs a busy-workload benchmark | `NVMTL_POOL_KEEP` now validates 0..256 with `strtol`, defaults to 16 on invalid input, logs OFF at zero, and initializes limit/reuse state with `pthread_once`. Portable parser/concurrent-initialization harness passes; benchmark default 16 with more than 16 buffers in flight on VM before shipping. | read from source; not tested on VM |
| Residency batch ownership review | Pending textures now use `CFTypeRef` to express the existing manual retain/release. The pager snapshots already hold textures strongly; this is defensive ownership documentation, not a reproduced crash fix. No Metal-observable behavior changed. | read from source; not tested |
| Purple regression fixes need VM validation | CPU scheduling timestamps, LOD sampler variant lifetime, background function specialization, and legal stencil store options have source fixes and four focused `tools/test_metal_*.m` probes. Run installed/new plugin comparisons, including synchronous and ahead submission for timing. | read from source; not tested |
| ICB blit copy/reset run at encode time | Both methods mutate CPU slots immediately. Deferring only the mutations to commit breaks later render/compute ICB executes, which replay at encode time. Correct ordering needs command recording across encoders and event boundaries, with retained replay resources; keep both methods purple. `tools/test_metal_icb_copy.m` covers copy/reset then execute, late CPU source/destination encodes, and chained operations for render and both compute dispatch forms. | read from source; regression VM-tested on Turing (12 pass, 9 fail) |
| Ampere, Ada, laptops, macOS 26 | Not tested with any fork change. Upstream says macOS 26 works for some users. | not tested |
| Upstream issues that also affect this fork | See the upstream tracker: small-BAR flicker (#169, #183), Chromium/WebKit video decode (#175), plugin memory-safety crashes (#251, #150), OpenGL speed (#261). | not tested here |

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
3. **Make the encoder cheaper on CPU.** Opt-in `--direct-row` and `--short-zero` already cut idle-VM CPU at 1080p from
   about 2.3 ms to 2.2 (`--direct-row`), 2.1 (`--short-zero`) and 1.9 together (table in docs/H264.md); they do not separate CPU time from wall time. Suspect the
   remaining cost is the CPU writing the tiled frame through the BAR1 mapping; a GPU copy would remove it. Done when
   `tools/bench_nvenc_h264.py` shows CPU ms/frame well below wall ms/frame. Needs: hardware.
4. **Validate bitrate control and decide its default.** Run `NVMTL_VT_RC=1` on real content (games, video, text) at
   720p to 4K and several client bitrates; record bitrate error and visible quality (PSNR with
   `tools/nvenc_psnr.m`). Done when the results are in `docs/H264.md` and the default is changed, or the reason it
   stays opt-in is written down. Needs: hardware.
5. **A repeatable H.264 benchmark and a Linux comparison.** `tools/bench_nvenc_h264.py` measures this side; the
   comparison needs the same card under Linux (ffmpeg `h264_nvenc`). Done when both numbers are in `docs/H264.md`.
6. **HEVC encode.** Find the second bitstream problem. Needs: hardware.
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
