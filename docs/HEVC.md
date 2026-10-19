# HEVC encode on Turing

The baseline encoder works on an RTX 2060 Super, macOS 15.8.1 VM. Turing support stays opt-in.
The optional CPU speed patches below pass machine-code emulation and the four-size hardware quality regression.
Direct-row copying improves the measured 1080p throughput by about 6%. The new HEVC bitrate-control hook tracks
2/4/8 Mbit/s targets in a standalone hardware probe. Picture correctness while QP changes and real-content streaming
through the new hook remain unqualified; the installed plugin still lacks HEVC feedback.

## Baseline fix and measured results

`tools/make_nvenc_hevc_t2d.py` accepts the stock `libnvenc_hevc.dylib` with SHA-256 prefix `aa6b8b2e76bd`
(the 2.2.0 and 2.3.6 packages ship identical bytes). It redirects the luma and chroma swizzle pointers to `sw_t2d`.
It also disables sign data hiding in the PPS writer and both engine setup templates. With sign hiding enabled,
Turing writes coefficient signs in a different order from the HEVC syntax; changing the header alone does not fix it.
The default changes six bytes. Every site is checked before patching, and other library builds are refused.

The baseline hardware regression, 30 frames per size, produced:

| Size | Mean / minimum Y PSNR | P-slice active references |
|---|---|---|
| 1280×720 | 44.7 / 44.2 dB | 1 |
| 1920×1080 | 44.4 / 43.9 dB | 1 |
| 1366×768 | 44.7 / 44.1 dB | 1 |
| 2560×1440 | 44.3 / 43.8 dB | 1 |

The stream checker passed at every size. The low-latency session and the supported-property lookup with an open
session passed. A second overlapping session was refused, as expected. **VM-tested on Turing.**
A prior 1080p60 Sunshine/Moonlight desktop run reported 60.1 fps, 0.00% network drops and 0.78 ms decode time;
noisy content fell to 39.6 fps. These are short runs, not a game-content or stability qualification.

The unoptimized baseline benchmark at 1080p, 500 frames × 3 runs on an idle VM, was 284 fps, 3.43 ms median
latency and 3.19 ms CPU per frame. H.264 in the same session was 425 fps, 2.31 ms and 2.35 ms CPU per frame.
Neither codec had its optional CPU speed patches enabled in that comparison.

## Build and opt-in

```bash
python3 tools/make_nvenc_hevc_t2d.py libnvenc_hevc.dylib libnvenc_hevc_t2d.dylib
codesign -f -s - libnvenc_hevc_t2d.dylib
# Place the signed result alongside NVMTLDriver in the installed bundle.
# Preserve the stock library for Blackwell and a copy of the installed files for rollback.
```

Build the plugin from this tree. Turing registration requires `NVMTL_NVENC_HEVC=1`. A release plugin reads it
from `/Library/GPUBundles/nvmtl/nvrm610.conf`; it clears `NVMTL_*` process environment variables at load.
`NVMTL_NO_NVENC_HEVC=1` suppresses registration. Blackwell continues using the stock library.

The VideoToolbox hook removes `EnableLowLatencyRateControl` for H.264 and HEVC, and caches supported properties
by both codec and frame size. This handles Sunshine's low-delay specification and its property lookup while an
encoder session is already open.

## Optional CPU speed patches

All default to off and compose with the baseline fix and each other:

- `--inline-tile` replaces the per-8-byte indirect helper call with the same address arithmetic. A pointer comparison
  retains the original indirect call if the session selected another swizzle, including a 10-bit layout override.
- `--direct-row` reads aligned 8-bit rows directly, skipping their staging `memmove`. Rows needing edge padding keep
  the original copy and fill. All 10-bit rows retain staging because the encoder can shift their samples in place.
- `--short-zero` clears 4096 bytes of the status buffer instead of the full mapping. This remains experimental:
  the GPU may have requirements beyond the status header the CPU reads.

```bash
python3 tools/make_nvenc_hevc_t2d.py --inline-tile --direct-row --short-zero INPUT OUTPUT
NVENC_HEVC_DYLIB=INPUT python3 tools/test_hevc_perf_patch.py
```

Readable reference assembly is in `tools/nvenc_hevc_perf.S`; the test checks that GNU as reproduces the embedded
bytes when the assembler tools are available. The machine-code test requires Unicorn and Capstone. It executes the actual original and patched row loops at a
relocated load address: 32 comparisons, including both planes, padded widths, 8/10-bit inputs and another swizzle.
It also checks the other helper fallback, preserved registers, branch destinations, all flag combinations,
unchanged input data, and rejection of changed sites or occupied caves. **Host emulation passed; no GPU involved.**
The default patcher and HEVC stream-parser tests also pass.

### Hardware A/B results, 2026-10-18

Each flag separately and all three combined passed the four-size, 30-frame-per-size regression with zero failures.
Reported mean/minimum Y PSNR values matched the baseline table above; reference, low-latency and property-lookup
checks also passed. The installed baseline library was restored and its hash verified after the experiments.
These tests cover 8-bit synthetic content on the reference Turing card, not Main10 or long-session stability.

`bench_nvenc` required hardware encoding and checked every output sample's codec. Each result below is the median
of three 600-frame runs; session setup and synthetic-frame generation are excluded. Baseline repeats bracketed the
variants: 720p was 662–664 fps and 1080p was 299–301 fps. The initial 720p baseline used 300 frames per run;
the 600-frame repeat agreed. The synthetic eight-frame ring measures encode throughput, not screen capture.

| HEVC library | 720p fps | 1080p fps | 1440p fps | 1080p p50 / p95 ms | 1080p CPU ms/frame |
|---|---:|---:|---:|---:|---:|
| Baseline | 664 | 301 | 173 | 3.30 / 3.42 | 3.32 |
| `--inline-tile` | 670 | 304 | 174 | 3.27 / 3.40 | 3.29 |
| `--direct-row` | 690 | 318 | 181 | 3.13 / 3.24 | 3.15 |
| `--short-zero` | 651 | 297 | 169 | 3.33 / 3.56 | 3.37 |
| All three | 679 | 315 | 182 | 3.15 / 3.25 | 3.18 |

Direct-row is the strongest individual candidate (about 6% at 1080p). Inline tiling's roughly 1% difference needs
more repetitions to establish a useful gain. Short-zero showed no benefit and had 32–35 ms outliers at 720p/1080p;
keep it off. Combining all flags did not beat direct-row at 1080p. All flags remain opt-in.

The same-session installed H.264 baseline, with its low-BAR patch but without optional speed flags, measured
847 fps at 720p and 421 fps at 1080p (1080p p50 2.34 ms, CPU 2.38 ms/frame).

## Sunshine/Moonlight measurements, 2026-10-18

These used the restored baseline library and existing plugin, HEVC 8-bit SDR, a Linux Moonlight client with hardware
Vulkan decoding, and a windowed performance overlay. Each connection was stopped after about 37 seconds. The table
uses the final roughly 22-second interval after client renderer resets; startup intervals had queue overflows,
IDR requests and substantially worse drops/decode times. These are short tests, not whole-session stability results.

| Content and requested setting | Incoming / rendered fps | Decode ms | Network loss / jitter drops | Video IP Mbit/s | Sunshine sampled %CPU |
|---|---:|---:|---:|---:|---:|
| Static desktop, 1080p60, 25 Mbit/s | 60.34 / 60.14 | 1.77 | 0% / 0.33% | 3.03 | 21.5 |
| Static desktop, 1080p60, 10 Mbit/s | 60.35 / 60.15 | 1.92 | 0% / 0.33% | 2.89 | 21.3 |
| Moving noise/gradient, 1080p60, 25 Mbit/s | 60.39 / 60.25 | 2.22 | 0% / 0.23% | 202.83 | 87.5 |

Wire rates come from an eight-second server-side sample of video UDP packets, counting IP/UDP headers and FEC,
excluding audio and Ethernet overhead, and dropping the partial first/last seconds. CPU is the mean of eight
`ps %cpu` samples (100% represents one core), not a process-CPU-time delta. The moving-content app remained active
through the measured stream. Lower requested bitrate is not a demonstrated quality or bandwidth improvement:
the installed HEVC library logs that `AverageBitRate` is accepted but still uses constant QP 23. It substantially
exceeds the requested rate on noisy content. The new HEVC feedback hook was not installed for these streams.

Connections are unreliable. Some 720p60, 1080p30 and 1440p60 attempts, and the moving-content 1080p60/10 Mbit/s
retry, received no video because encoder creation repeatedly failed with -12908. Verbose engine logs show CPU-map
and usermode-map failures during bring-up; capture uploads also reported mapping failures. The responsible mapping
and whether BAR1 pressure, resource lifetime or another error causes it remain unresolved. A successfully negotiated
stream format alone is not evidence that any frames arrived. Fix connection reliability before treating these
settings as supported presets.

## HEVC bitrate control

`NVMTL_VT_RC=1` now wraps hardware HEVC callbacks as well as H.264. The HEVC library reloads its QP each frame,
and its Quality setter uses the same conversion: `qp = trunc(-41 * quality + 51.5)`. The existing controller
therefore uses the same inverse. HEVC sync-frame attachments use the same `NotSync` key.

The controller header passes its host simulations. A macOS test with fake VT functions checks feedback on both
codecs, IDR handling, software-session pass-through and the opt-out. The plugin and probe compile on macOS.

The standalone probe installs the new hook in its own process before creating the Metal device; the installed
plugin was not replaced. At 720p60, 360 frames per session, the mean after the first second was:

| Target | Hook | Actual mean Mbit/s | Result |
|---|---|---:|---|
| 2 Mbit/s | off | 3.76 | Outside ±25%, expected negative control |
| No target | on | 3.76 | Constant-QP control |
| 2 Mbit/s | on | 2.05 | Pass |
| 4 Mbit/s | on | 3.88 | Pass |
| 8 Mbit/s | on | 7.91 | Pass |
| 4 Mbit/s, nine sequential sessions | on | 3.88 each | All nine pass |

Every session returned all 360 frames. H.264 with the same new hook also passed a 2 Mbit/s probe at 2.33 Mbit/s.
These rates use encoded sample sizes and nominal video time, unlike the live IP measurements above. They check
average bitrate and session-table reuse, not peak bursts, decoded-picture quality, or full-plugin integration.
**VM-tested on Turing for synthetic bitrate tracking; decode correctness with changing QP remains pending.**

```bash
clang -fobjc-arc -O1 -o vt_rc_hook_test tools/vt_rc_hook_test.m \
  -framework Foundation -framework VideoToolbox -framework CoreMedia
./vt_rc_hook_test
clang -fobjc-arc -O1 -o vt_rc_probe tools/vt_rc_probe.m \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal
PROBE_CODEC=hevc NVMTL_VT_RC=1 ./vt_rc_probe 2000000 360 1
```

The bitrate probe requires every submitted frame to return and checks the ±25% mean-bitrate window for both one
session and repeated sessions. Use a constant-QP run with target 0 as a control, then several targets and at least
nine sequential sessions to exercise table replacement. A passing bitrate result still needs a decode-quality check.

## Hardware validation still required

The speed-flag A/B test and standalone synthetic bitrate tracking are complete for short 8-bit runs. Next verify
HEVC decode correctness with changing QP, then run the equivalent H.264 regression after the plugin changes.
Test Sunshine/Moonlight on varied game content with bitrate control. Watch for encoder
creation failures, decode errors, drops and actual wire bitrate. The 10-bit paths are protected by fallback checks
in emulation but remain unqualified on hardware. Other cards and long-running sessions are untested.

## Rollback and limits

Restore the saved plugin and library, or remove the Turing opt-in from the configuration and restart affected apps.
No kext or bootloader changes are needed. One simultaneous session per process remains the measured limit.
Small-BAR mapping pressure can still prevent session creation even with free VRAM; the H.264 low-BAR patch has
not been ported to HEVC. The closed library alone ignores `AverageBitRate` and runs at constant QP.
