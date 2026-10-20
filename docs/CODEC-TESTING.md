# Hardware codec stress probes

`tools/nvenc_matrix.m` tests H.264 and HEVC through VideoToolbox on the installed driver. It includes the current
`nvmtl_vt_spec_hook.h` and installs that hook in the test process before creating a Metal device. This permits
comparison of the current source's bitrate feedback with an opt-out, without replacing the installed plugin.
Record the installed library build separately: changing the test hook does not apply optional binary speed patches.

Build on macOS with the command line tools:

```sh
clang -fobjc-arc -O1 tools/nvenc_matrix.m -o nvenc_matrix \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal
clang -fobjc-arc -O1 tools/nvenc_gpu_load.m -o nvenc_gpu_load -framework Foundation -framework Metal
```

The codec probe takes ten arguments: codec, width, height, frame count, nominal frame rate, target bits/second,
pattern, sequential session count, run label and output JSON path. It requires hardware encoding, checks every
sample's codec, requests software decoding and checks that the decoder actually reports software use. Each frame
is decoded and compared with a regenerated source; missing or duplicate frames, wrong dimensions, decoder errors,
failed required property calls and failed property lookup make the correctness result fail. Low-bitrate PSNR is
reported rather than held to the constant-QP regression's 40 dB gate. Mean PSNR is the mean of frame PSNR values.
The existing `test_nvenc_h264.py` and `test_nvenc_hevc.py` remain the independent baseline quality/header checks.

```sh
# Six nominal seconds of 1080p60 motion, a 4 Mbit/s request, one session.
NVMTL_VT_RC=1 ./nvenc_matrix hevc 1920 1080 360 60 4000000 motion 1 hevc-4m result.json
# Identical source with feedback disabled in this process.
NVMTL_VT_RC=0 ./nvenc_matrix h264 1920 1080 360 60 4000000 motion 1 h264-off control.json
# Exercise session-table replacement in a single process.
NVMTL_VT_RC=1 ./nvenc_matrix hevc 1280 720 180 60 2000000 motion 16 repeat16 repeated.json
```

Patterns are `static`, `motion`, `edges`, `noise`, and `cuts`. The latter cycles through static detail, motion,
independent per-frame noise and flat content in two-second blocks. These are synthetic 8-bit NV12 sources, not
recorded game footage. The dimensions must be even; the 1366-pixel case exercises coded-width padding.

Useful environment options:

- `TEST_GOP`: keyframe interval in frames; defaults to one nominal second. Compare 60, 240 and 100000 at 60 fps.
- `TEST_TARGET2`: changes the requested bitrate halfway through a session. Its per-second rates, rather than the
  whole-run target-window flag, describe response to the two different targets.
- `TEST_PACE=1`: pace 30-frame batches to nominal video time for bounded-duration soak tests. Generation and
  software decode still occur between batches; this does not model evenly spaced real-time capture submissions.
- `TEST_DUMP`: write Annex B, including parameter sets before keyframes. Use one session when preserving a dump;
  later sessions overwrite the same path. This permits independent FFmpeg decode and the existing reference parsers.

The JSON separates correctness from the ±25% bitrate window. Rates exclude the first nominal second and use only
complete subsequent seconds; they are encoded sample bytes over nominal video time, not network traffic. The
output also includes per-second rates, mean/minimum Y PSNR, UV PSNR, keyframe byte totals, observed next-frame QP
range, creation time, callback latency and frames exceeding the nominal frame budget. The QP range is read from
the process-local test hook, not the closed encoder's actual engine commands.

Encode service throughput divides frame count by accumulated `EncodeFrame` and `CompleteFrames` wall time. CPU
cost covers those calls too. Source generation, software decode and pacing sleeps are excluded. This measures
encode service, not end-to-end capture FPS; a low-bitrate run at higher QP is not a fair speed comparison against a
constant-QP run. Compressed samples are retained in batches of at most 30 rather than for the entire soak.

The companion holds touched private Metal buffers and optionally runs repeated compute dispatches. It prints
`READY` only after buffer initialization and pipeline creation, then checks memory sentinels before exiting.
Limits are 32–3072 MiB and 1–1800 seconds. Buffer allocation requested from Metal is not proof of physical VRAM
residency: the driver's placement and eviction policy still applies. Its command-wait wall time is not a GPU
utilization counter. Termination is handled between bounded dispatches.

```sh
# Run this in a separate process, wait for READY, then run the encoder probe.
./nvenc_gpu_load 90 1536 1 > companion.log 2>&1 &
load_pid=$!
NVMTL_VT_RC=1 ./nvenc_matrix h264 1920 1080 360 60 8000000 cuts 1 loaded loaded.json
kill -TERM "$load_pid"
wait "$load_pid"
```

A stress report should keep standalone hook results separate from real Sunshine/Moonlight sessions, record the
actual selected encoder, count no-video attempts, distinguish startup/reset intervals from final stream statistics,
and measure video wire bitrate including its FEC/packet overhead separately from sample bitrate. Preserve installed
file hashes before and after tests and distinguish same-process session refusal from cross-process concurrency.
