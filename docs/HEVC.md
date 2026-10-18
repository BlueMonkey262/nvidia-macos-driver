# HEVC encode on Turing

Status: **experimental, untested on hardware.** The patcher and the host checks have been run on the dev machine. Nothing here has been run on a GPU.

`tools/make_nvenc_hevc_t2d.py` rewrites two LEAs in `libnvenc_hevc.dylib` (sha256 prefix `aa6b8b2e76bd`, the same bytes in the 2.2.0 and 2.3.6 packages) so 8-bit luma and chroma call `sw_t2d` instead of the Blackwell swizzles. The indirect calls stay. No code cave is written, and the H.264 reference clamp is not applied. The tool then compares the register form of `sw_t2d` with the gob formula for y = 0..63 and x stepping by 8 across pitch 2048 (16384 points) and requires 0 mismatches. That compare is emulation only.

The plugin registers HEVC on Blackwell as before (`libnvenc_hevc.dylib`, no environment variable). On Turing it loads `libnvenc_hevc_t2d.dylib` only when `NVMTL_NVENC_HEVC=1`, so Sunshine and screen sharing do not pick the encoder up before a PSNR run. `NVMTL_NO_NVENC_HEVC=1` keeps the process on Apple's encoder. The VideoToolbox hook drops `EnableLowLatencyRateControl` for `'hvc1'` as well as `'avc1'`, and keeps a separate supported-property cache so a failed HEVC lookup cannot return the H.264 dictionary.

## Build

```bash
python3 tools/make_nvenc_hevc_t2d.py libnvenc_hevc.dylib libnvenc_hevc_t2d.dylib   # refuses any other input library
codesign -f -s - libnvenc_hevc_t2d.dylib
# copy next to NVMTLDriver in /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/
# leave the stock libnvenc_hevc.dylib in place (Blackwell, and rollback)
```

Build the plugin from this tree. A release build clears `NVMTL_*` from the environment at load and reads `/Library/GPUBundles/nvmtl/nvrm610.conf`, so the opt-in there is a line `NVMTL_NVENC_HEVC=1`. A debug plugin sees the process environment.

## Running the PSNR test

On the Mac, with the driver and `libnvenc_hevc_t2d.dylib` installed:

```bash
python3 tools/test_nvenc_hevc.py --log ~/nvenc-hevc.log
```

The test sets `NVMTL_NVENC_HEVC=1` and `NVMTL_NO_NVDEC_HEVC=1` on the encode tool (`NVMTL_NO_NVDEC` does not cover HEVC decode). On a release plugin those variables have to be in `nvrm610.conf` as well, because the process environment is cleared. It builds `tools/nvenc_psnr_hevc.m`, encodes at four sizes (1280x720, 1920x1080, 1366x768, 2560x1440), decodes with Apple's software decoder, and requires mean and minimum Y PSNR of at least 40 dB. 1366 is not a multiple of 16; the library aligns the coded size to 32. It then runs `tools/hevc_refs.py` on each Annex B dump. Exit 0 passes, 1 fails, 77 means skipped (not macOS).

The log should say the HEVC encoder is REGISTERED and the library path ends in `_t2d`. A wrong tile is the 17-28 dB band; a correct picture on the H.264 clip was about 42 dB or more. Overlap (a second session while the first is open) is expected to fail with -12908, one engine per process. The test records it and does not fail the run unless `--overlap-required` is given.

`tools/hevc_refs.py FILE.hevc` exits 0 only when every IDR is preceded by VPS, SPS and PPS, the stream is 8-bit 4:2:0, no slice sets SAO while the SPS disables it, and no P slice's active L0 count exceeds sub-layer 0 `sps_max_dec_pic_buffering_minus1`. It prints max CTU log2. 5 (32x32) is the expected value. A 6 is recorded and does not fail. More than one reference does not fail by itself.

## If a VM run fails

Read the `nve265:` lines before changing the LEAs again.

- Channel error, engine dead, or a nonzero ucode, and no picture: the setup image was rejected. Do not touch the LEAs. That is the expected first outcome of a tiling-only library, not a failed patch.
- A picture decodes, Y PSNR is under 40, and the channel stays healthy: the tile formula is wrong on this card. Only then put a cave at `0xc160` and point both LEAs at it. The indirect calls stay.
- Y PSNR is at least 40 and `hevc_refs.py` exits 0: drop the `NVMTL_NVENC_HEVC` getenv in a separate change, then one Sunshine to Moonlight HEVC stream (`hevc_videotoolbox`, 1080p60).
- Y PSNR is at least 40 and `hevc_refs.py` exits 1: patch only the field that failed. The ref-count candidate is `0x8f9a` (`cmp r12d, 4; mov eax, 4` becomes `cmp r12d, 1; mov eax, 1`). It is not in `make_nvenc_hevc_t2d.py`.

## Rollback

`unset NVMTL_NVENC_HEVC`, or set `NVMTL_NO_NVENC_HEVC=1`, and delete `libnvenc_hevc_t2d.dylib`. Remove the conf line if one was added. No kext, OpenCore, or host change. Blackwell keeps using the stock `libnvenc_hevc.dylib`.

## Known limits

- Constant QP: `AverageBitRate` is accepted and ignored by the library. Not measured for HEVC.
- One engine per process. A second session is refused (-12908). Not measured for HEVC; this is what the H.264 library does.
- CPU-side tiling through the 256 MB BAR1. Not measured for HEVC.
- 10-bit (Main10, P010) waits until the 8-bit PSNR gate passes. The LEA patch already points 10-bit luma at `sw_t2d`.
- Not tested on hardware.
