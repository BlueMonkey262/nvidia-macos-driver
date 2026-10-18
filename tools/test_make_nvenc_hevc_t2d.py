#!/usr/bin/env python3
"""Host checks for tools/make_nvenc_hevc_t2d.py.

The 16384-point sw_t2d compare always runs (emulation only, no GPU). A synthetic image with the known bytes at
the LEA and call sites is patched with the hash check skipped, and a wrong image is refused. When a real
libnvenc_hevc.dylib is passed as an argument, or NVENC_HEVC_DYLIB is set, the script is also run on that file
and the output is checked byte for byte. That library is not in the repo.

Exit 0 on pass, 1 on fail.
"""
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import make_nvenc_hevc_t2d as tool  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    fails += not ok


bad, n = tool.count_mismatches()
check("sw_t2d: 16384 points, 0 mismatches", bad == 0 and n == 16384, f"{bad} of {n}")

# The two replacement LEAs are the ones the plan names, and both resolve to sw_t2d.
rcx = tool._lea(bytes.fromhex("488d0d"), tool.LEA_RCX, tool.SW_T2D)
rax = tool._lea(bytes.fromhex("488d05"), tool.LEA_RAX, tool.SW_T2D)
check("0x5226 replacement is 48 8d 0d a3 05 00 00", rcx == bytes.fromhex("488d0da3050000"), rcx.hex())
check("0x52aa replacement is 48 8d 05 1f 05 00 00", rax == bytes.fromhex("488d051f050000"), rax.hex())


def plant(buf):
    buf = bytearray(buf)
    buf[tool.LEA_RCX:tool.LEA_RCX + 7] = tool.OLD_RCX
    buf[tool.LEA_RAX:tool.LEA_RAX + 7] = tool.OLD_RAX
    buf[tool.CALL_LUMA:tool.CALL_LUMA + 5] = tool.CALL_LUMA_BYTES
    buf[tool.CALL_CHROMA:tool.CALL_CHROMA + 4] = tool.CALL_CHROMA_BYTES
    buf[tool.SW_T2D:tool.SW_T2D + len(tool.SW_T2D_BYTES)] = tool.SW_T2D_BYTES
    return buf


synthetic = plant(bytearray(75488))
patched, pn = tool.patch_buffer(synthetic, check_hash=False)
check("synthetic: both LEAs land on sw_t2d", tool.rip_target(patched, tool.LEA_RCX) == tool.SW_T2D
      and tool.rip_target(patched, tool.LEA_RAX) == tool.SW_T2D)
changed = [i for i, (a, b) in enumerate(zip(synthetic, patched)) if a != b]
lea_span = set(range(tool.LEA_RCX, tool.LEA_RCX + 7)) | set(range(tool.LEA_RAX, tool.LEA_RAX + 7))
check("synthetic: only LEA bytes change", set(changed) <= lea_span and len(changed) > 0, f"{len(changed)} bytes")
check("synthetic: sites are the sw_t2d LEAs",
      patched[tool.LEA_RCX:tool.LEA_RCX + 7] == rcx and patched[tool.LEA_RAX:tool.LEA_RAX + 7] == rax)
check("synthetic: calls and 0xc160 are untouched",
      patched[tool.CALL_LUMA:tool.CALL_LUMA + 5] == tool.CALL_LUMA_BYTES
      and patched[tool.CALL_CHROMA:tool.CALL_CHROMA + 4] == tool.CALL_CHROMA_BYTES
      and not any(patched[0xC160:0xC170]))
check("synthetic: emulation still 0 of 16384", pn == 16384)

inlined = plant(bytearray(75488))
inlined[tool.CALL_LUMA:tool.CALL_LUMA + 5] = b"\x90" * 5
try:
    tool.patch_buffer(inlined, check_hash=False)
    check("inlined luma call is refused", False)
except SystemExit as e:
    check("inlined luma call is refused", "not indirect" in str(e), str(e))

wrong = bytearray(b"not an encoder")
try:
    tool.patch_buffer(wrong)
    check("wrong hash is refused", False)
except SystemExit as e:
    check("wrong hash is refused", tool.KNOWN in str(e), str(e))


def run_on(src: pathlib.Path):
    with tempfile.TemporaryDirectory() as td:
        dst = pathlib.Path(td) / "libnvenc_hevc_t2d.dylib"
        p = subprocess.run([sys.executable, str(ROOT / "tools/make_nvenc_hevc_t2d.py"), str(src), str(dst)],
                           capture_output=True, text=True)
        print(p.stdout.strip())
        if p.returncode:
            print(p.stderr.strip())
        check("real library: tool exits 0", p.returncode == 0, f"exit {p.returncode}")
        if p.returncode:
            return
        check("real library: prints 0 mismatches in 16384", "0 mismatches in 16384" in p.stdout)
        out = dst.read_bytes()
        raw = src.read_bytes()
        changed = [i for i, (a, b) in enumerate(zip(raw, out)) if a != b]
        check("real library: output differs only inside the two LEAs",
              set(changed) <= {i for i in range(0x5226, 0x5226 + 7)} | {i for i in range(0x52AA, 0x52AA + 7)}
              and out[0x5226:0x522D] == bytes.fromhex("488d0da3050000")
              and out[0x52AA:0x52B1] == bytes.fromhex("488d051f050000"),
              f"{len(changed)} bytes")
        check("real library: both targets are 0x57d0",
              tool.rip_target(out, 0x5226) == 0x57D0 and tool.rip_target(out, 0x52AA) == 0x57D0)
        check("real library: sha256 prefix was the known encoder",
              hashlib.sha256(raw).hexdigest().startswith(tool.KNOWN))
        again = subprocess.run([sys.executable, str(ROOT / "tools/make_nvenc_hevc_t2d.py"), str(dst), str(dst) + ".2"],
                               capture_output=True, text=True)
        check("real library: patching the output is refused", again.returncode != 0, again.stderr.strip()[:160])


lib = None
if len(sys.argv) > 1:
    lib = pathlib.Path(sys.argv[1])
elif os.environ.get("NVENC_HEVC_DYLIB"):
    lib = pathlib.Path(os.environ["NVENC_HEVC_DYLIB"])
if lib and lib.is_file():
    run_on(lib)
else:
    print("SKIP: no libnvenc_hevc.dylib given (emulation above still ran; the real file is not in the repo)")

sys.exit(1 if fails else 0)
