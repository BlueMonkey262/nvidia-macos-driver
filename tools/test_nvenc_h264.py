#!/usr/bin/env python3
"""Hardware H.264 encode picture check on a real NVIDIA GPU (needs the driver installed and macOS).

Builds tools/nvenc_psnr.m, encodes synthetic frames at several sizes (1366x768 is not a multiple of 16 wide), decodes
them with Apple's software decoder and requires the PSNR to stay above a threshold. A wrongly tiled encoder gives
17-28 dB; a correct one gives about 42 dB or more. Then it opens two sessions at once, as Sunshine does.

usage: test_nvenc_h264.py [--log FILE] [--overlap-required]
Output goes to the log file too, because the display is often not visible. The overlap check is reported but only
fails the run with --overlap-required (upstream issue #206: a second session while the first is open is refused).
Exit codes: 0 pass, 1 fail, 77 skipped (not macOS, or no clang)."""
import argparse
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SIZES = [(1280, 720), (1920, 1080), (1366, 768), (2560, 1440)]
FRAMES = 30
FRAMEWORKS = ["Foundation", "VideoToolbox", "CoreMedia", "CoreVideo", "Metal"]

ap = argparse.ArgumentParser()
ap.add_argument("--log", default=os.path.join(tempfile.gettempdir(), "test_nvenc_h264.log"))
ap.add_argument("--overlap-required", action="store_true")
args = ap.parse_args()

logf = open(args.log, "w")


def say(msg):
    print(msg)
    logf.write(msg + "\n")
    logf.flush()


if platform.system() != "Darwin" or not shutil.which("xcrun"):
    say("SKIP: needs macOS with the command line tools (nothing was tested)")
    sys.exit(77)

fails = 0


def arm(name, ok, detail=""):
    global fails
    say(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    fails += not ok


with tempfile.TemporaryDirectory() as d:
    exe = os.path.join(d, "nvenc_psnr")
    cmd = ["xcrun", "clang", "-fobjc-arc", "-O1", "-o", exe, str(ROOT / "tools/nvenc_psnr.m")]
    for f in FRAMEWORKS:
        cmd += ["-framework", f]
    built = subprocess.run(cmd, capture_output=True, text=True)
    if built.returncode:
        say(built.stderr)
        arm("nvenc_psnr builds", False)
        sys.exit(1)
    env = dict(os.environ, NVMTL_NO_NVDEC="1")   # the same software decoder checks every run

    def run(argv, **extra_env):
        p = subprocess.run([exe] + argv, capture_output=True, text=True, env=dict(env, **extra_env), timeout=300)
        out = "\n".join(l for l in p.stdout.splitlines() if not l.startswith("nvrm:"))
        say("--- nvenc_psnr " + " ".join(argv) + (" [" + " ".join(extra_env) + "]" if extra_env else "") + f" -> exit {p.returncode}\n" + out)
        return p.returncode, out

    for w, h in SIZES:
        rc, out = run([str(w), str(h), str(FRAMES)])
        arm(f"{w}x{h}: hardware H.264 encode, {FRAMES} frames, PSNR above threshold", rc == 0, f"exit {rc}")

    # what ffmpeg/Sunshine ask for in low-delay mode; VideoToolbox refuses it with -12902 unless the plugin drops it
    rc, out = run(["1920", "1080", str(FRAMES)], NVENC_PSNR_LOW_LATENCY="1")
    arm("1920x1080: session with EnableLowLatencyRateControl opens and encodes", rc == 0, f"exit {rc}")

    # ffmpeg looks up the encoder's supported properties while its session is open; VideoToolbox answers -12908 for that
    # unless the plugin serves it from a cache (the library allows one engine per process)
    rc, out = run(["--props-open", "1920", "1080"])
    arm("supported-property lookup works while a session is open (ffmpeg/Sunshine)", rc == 0, f"exit {rc}")

    rc, out = run(["--overlap", "1920", "1080"])
    ok = rc == 0
    if args.overlap_required:
        arm("two overlapping hardware sessions both encode", ok, f"exit {rc}")
    else:
        say(("info " if ok else "WARN ") + f"two overlapping hardware sessions: exit {rc} (not counted; use --overlap-required)")

say(f"{fails} failed; log: {args.log}")
sys.exit(1 if fails else 0)
