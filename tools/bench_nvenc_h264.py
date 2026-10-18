#!/usr/bin/env python3
"""Hardware H.264 encode speed on a real NVIDIA GPU (macOS, driver installed). Builds tools/bench_nvenc.m and measures
throughput, per-frame latency and CPU cost at three sizes, 300 frames, five runs each, and prints the medians.

usage: bench_nvenc_h264.py [--log FILE] [--frames N] [--runs N]
Run it on an idle desktop (nothing streaming, no builds): the load average is printed and a high one is flagged,
because a busy machine makes every number meaningless. The numbers are for comparing builds of this driver and, with
the same card under Linux (ffmpeg h264_nvenc), for judging how much headroom there is; they are not a pass/fail test.
Exit codes: 0 done, 1 a size produced no result, 77 skipped (not macOS)."""
import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SIZES = [(1280, 720), (1920, 1080), (2560, 1440)]
FRAMEWORKS = ["Foundation", "VideoToolbox", "CoreMedia", "CoreVideo", "Metal"]

ap = argparse.ArgumentParser()
ap.add_argument("--log", default=os.path.join(tempfile.gettempdir(), "bench_nvenc_h264.log"))
ap.add_argument("--frames", type=int, default=300)
ap.add_argument("--runs", type=int, default=5)
args = ap.parse_args()
logf = open(args.log, "w")


def say(msg):
    print(msg)
    logf.write(msg + "\n")
    logf.flush()


if platform.system() != "Darwin" or not shutil.which("xcrun"):
    say("SKIP: needs macOS with the command line tools (nothing was measured)")
    sys.exit(77)

load = os.getloadavg()[0]
say(f"load average before starting: {load:.2f}" + ("   <-- busy: results will be unreliable" if load > 1.0 else ""))
rows = []
with tempfile.TemporaryDirectory() as d:
    exe = os.path.join(d, "bench_nvenc")
    cmd = ["xcrun", "clang", "-fobjc-arc", "-O1", "-o", exe, str(ROOT / "tools/bench_nvenc.m")]
    for f in FRAMEWORKS:
        cmd += ["-framework", f]
    built = subprocess.run(cmd, capture_output=True, text=True)
    if built.returncode:
        say(built.stderr)
        say("FAIL bench_nvenc does not build")
        sys.exit(1)
    for w, h in SIZES:
        p = subprocess.run([exe, str(w), str(h), str(args.frames), str(args.runs)], capture_output=True, text=True,
                           env=dict(os.environ, NVMTL_NO_NVDEC="1"), timeout=900)
        out = "\n".join(l for l in p.stdout.splitlines() if not l.startswith("nvrm:"))
        say(f"--- bench_nvenc {w} {h} {args.frames} {args.runs} -> exit {p.returncode}\n{out}")
        res = [l.split() for l in out.splitlines() if l.startswith("RESULT ")]
        if res:
            rows.append(res[-1][1:])

say("\nsize        fps(med)  fps(min)  p50 ms  p95 ms  max ms  cpu ms/frame")
for r in rows:
    say(f"{r[0]}x{r[1]:<6} {r[2]:>8} {r[3]:>9} {r[4]:>7} {r[5]:>7} {r[6]:>7} {r[7]:>12}")
say(f"load average at the end: {os.getloadavg()[0]:.2f}; log: {args.log}")
sys.exit(0 if len(rows) == len(SIZES) else 1)
