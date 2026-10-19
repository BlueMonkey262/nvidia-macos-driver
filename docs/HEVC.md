# HEVC encode on Turing

The baseline encoder works on an RTX 2060 Super, macOS 15.8.1 VM. Turing support stays opt-in.
The optional CPU speed patches below have passed machine-code emulation; their hardware quality and speed checks
are pending. The existing bitrate controller remains H.264-only; HEVC uses constant QP.

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
session passed. A second overlapping session was refused, as expected. **VM-tested on Turing, baseline only.**
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
The default patcher and HEVC stream-parser tests also pass. No performance gain is claimed for these flags yet.

## Hardware validation still required

When games and streaming are idle, back up the installed files and test each speed flag separately before the
combined build. Run `tools/test_nvenc_hevc.py` for each: four sizes × 30 frames, mean and minimum Y PSNR ≥40 dB,
parameter sets and L0-reference checks, low-latency creation and the property lookup. Then compare
`BENCH_CODEC=hevc bench_nvenc 1920 1080 500 3` and 720p against the baseline in the same idle session.
Restore the installed files on failures or timeouts. Run the equivalent H.264 regression after the plugin changes.

Only after those pass, test Sunshine/Moonlight on varied game content with bitrate control. Watch for encoder
creation failures, decode errors, drops and actual wire bitrate. The 10-bit paths are protected by fallback checks
in emulation but remain unqualified on hardware. Other cards and long-running sessions are untested.

## Rollback and limits

Restore the saved plugin and library, or remove the Turing opt-in from the configuration and restart affected apps.
No kext or bootloader changes are needed. One simultaneous session per process remains the measured limit.
Small-BAR mapping pressure can still prevent session creation even with free VRAM; the H.264 low-BAR patch has
not been ported to HEVC. The closed library alone ignores `AverageBitRate` and runs at constant QP.
