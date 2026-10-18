#!/usr/bin/env python3
"""The VideoToolbox specification hook (plugin/nvmtl_vt_spec_hook.h) must catch calls however the caller's image binds
VTCompressionSessionCreate: a lazy pointer that is still unbound when the hook installs, a pointer bound at load, and
chained fixups. tools/vt_hook_probe.m includes the header with stubs, installs it and calls the function with the
low-latency key in the specification, for H.264 and for HEVC ('hvc1'); the hook has to drop the key for both. A control
run with NVMTL_NO_VT_SPEC_HOOK=1 must not. The probe was not compiled here: it needs macOS with the command line tools
and no GPU. Exit codes: 0 pass, 1 fail, 77 skipped (not macOS or no clang)."""
import os, pathlib, platform, shutil, subprocess, sys, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
hook_src = (ROOT / "plugin/nvmtl_vt_spec_hook.h").read_text()
probe_src = (ROOT / "tools/vt_hook_probe.m").read_text()
if ("hvc1" not in hook_src or "com.nvmtl.videoencoder.hevc.nvenc" not in hook_src
        or "g_vt_cache_id[NVMTL_VT_SLOTS]" not in hook_src or "kCMVideoCodecType_HEVC" not in probe_src
        or "kCMVideoCodecType_H264" not in probe_src):
    print("FAIL: the hook or the probe does not carry the hvc1 slot (source check, not a run)")
    sys.exit(1)
if platform.system() != "Darwin" or not shutil.which("xcrun"):
    print("SKIP: needs macOS with the command line tools (hvc1 probe was not compiled or run; not tested)")
    sys.exit(77)
fails = 0
def arm(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else "")); fails += not ok
variants = [("lazy pointers (macOS 10.15 target)", ["-mmacosx-version-min=10.15"]),
            ("bound at load (bind_at_load)", ["-mmacosx-version-min=10.15", "-Wl,-bind_at_load"]),
            ("chained fixups (macOS 13 target)", ["-mmacosx-version-min=13.0"])]
header = os.environ.get("HOOK_HEADER", str(ROOT / "plugin/nvmtl_vt_spec_hook.h"))
with tempfile.TemporaryDirectory() as d:
    for name, flags in variants:
        exe = os.path.join(d, "probe")
        b = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wno-deprecated-declarations", *flags, f'-DHOOK_HEADER="{header}"', "-o", exe,
                            str(ROOT / "tools/vt_hook_probe.m"), "-framework", "Foundation", "-framework", "VideoToolbox", "-framework", "CoreMedia"],
                           capture_output=True, text=True)
        if b.returncode: print(b.stderr[-600:]); arm(f"{name}: probe builds", False); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=60)
        arm(f"{name}: the hook drops the low-latency key for avc1 and hvc1", r.returncode == 0, f"exit {r.returncode}: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-120:]}")
        c = subprocess.run([exe], capture_output=True, text=True, timeout=60, env=dict(os.environ, NVMTL_NO_VT_SPEC_HOOK="1"))
        arm(f"{name}: control with NVMTL_NO_VT_SPEC_HOOK=1 leaves the call alone", c.returncode == 0,
            f"exit {c.returncode}: {c.stdout.strip().splitlines()[-1] if c.stdout.strip() else ''}")
print(f"{fails} failed"); sys.exit(1 if fails else 0)
