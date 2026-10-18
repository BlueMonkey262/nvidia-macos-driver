#!/usr/bin/env python3
"""Unit and capture checks for tools/h264_refs.py.

Synthetic tests cover Exp-Golomb, emulation prevention and small generated streams. Capture tests need local
files (not committed) in the directory named by H264_CAPTURES: sr-move.h264 must
pass with 119 one-reference P slices; reassembled.h264 must report >1 active refs and fail.

Exit 0 on pass (the capture checks are skipped when the files are absent), 1 on fail.
"""
import os
import pathlib
import subprocess
import tempfile
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import h264_refs  # noqa: E402

CAPTURES = pathlib.Path(os.environ.get("H264_CAPTURES", "captures"))
SR = CAPTURES / "sr-move.h264"
MULTI = CAPTURES / "reassembled.h264"

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    fails += not ok


# --- Exp-Golomb / emulation prevention (synthetic) ---

def bits_to_bytes(bitstr: str) -> bytes:
    bitstr = bitstr.replace(" ", "")
    pad = (-len(bitstr)) % 8
    bitstr += "0" * pad
    return bytes(int(bitstr[i : i + 8], 2) for i in range(0, len(bitstr), 8))


br = h264_refs.BitReader(bits_to_bytes("1"))  # ue = 0
check("ue(v) 0 is a single 1 bit", br.ue() == 0)

br = h264_refs.BitReader(bits_to_bytes("010"))  # ue = 1
check("ue(v) 1 is 010", br.ue() == 1)

br = h264_refs.BitReader(bits_to_bytes("011"))  # ue = 2
check("ue(v) 2 is 011", br.ue() == 2)

br = h264_refs.BitReader(bits_to_bytes("00100"))  # ue = 3
check("ue(v) 3 is 00100", br.ue() == 3)

br = h264_refs.BitReader(bits_to_bytes("00101"))  # ue = 4
check("ue(v) 4 is 00101", br.ue() == 4)

# se: 1 -> 0? Actually se(0)=1 (ue 0), se(1)=010 (ue 1), se(-1)=011 (ue 2)
br = h264_refs.BitReader(bits_to_bytes("1"))
check("se(v) 0 is ue 0", br.se() == 0)
br = h264_refs.BitReader(bits_to_bytes("010"))
check("se(v) +1 is ue 1", br.se() == 1)
br = h264_refs.BitReader(bits_to_bytes("011"))
check("se(v) -1 is ue 2", br.se() == -1)
br = h264_refs.BitReader(bits_to_bytes("00100"))
check("se(v) +2 is ue 3", br.se() == 2)
br = h264_refs.BitReader(bits_to_bytes("00101"))
check("se(v) -2 is ue 4", br.se() == -2)

raw = bytes([0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00])
rbsp = h264_refs.remove_emulation_prevention(raw)
check("emulation 00000301 becomes 000001", rbsp == bytes([0x00, 0x00, 0x01, 0x00, 0x00, 0x00]), rbsp.hex())
check("plain bytes without 000003 pass through", h264_refs.remove_emulation_prevention(b"\x01\x02\x03") == b"\x01\x02\x03")



class BitWriter:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        self.bits += [(v >> (n - 1 - i)) & 1 for i in range(n)]

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0)
        self.u(n, v)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def rbsp(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)
        return bytes(int("".join(map(str, self.bits[i:i + 8])), 2) for i in range(0, len(self.bits), 8))


def nal(header, rbsp):
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return b"\x00\x00\x00\x01" + bytes([header]) + bytes(out)


def synthetic_stream(p_refs, max_num_ref_frames=3):
    """A 64x64 baseline-profile stream: SPS, PPS, one IDR slice header and one P slice header per entry of p_refs (the
    number of active L0 references each P slice names). Slice data is absent: the checker only reads headers."""
    sps = BitWriter()
    sps.u(8, 66); sps.u(8, 0); sps.u(8, 30); sps.ue(0)          # profile, constraints, level, sps id
    sps.ue(0); sps.ue(0); sps.ue(0)                              # log2_max_frame_num-4, poc type 0, log2_max_poc_lsb-4
    sps.ue(max_num_ref_frames); sps.u(1, 0)                      # max_num_ref_frames, gaps
    sps.ue(3); sps.ue(3); sps.u(1, 1); sps.u(1, 1)               # 4x4 macroblocks, frame_mbs_only, direct_8x8
    sps.u(1, 0); sps.u(1, 0)                                     # no cropping, no VUI
    pps = BitWriter()
    pps.ue(0); pps.ue(0); pps.u(1, 0); pps.u(1, 0); pps.ue(0)   # ids, CAVLC, no bottom-field POC, one slice group
    pps.ue(0); pps.ue(0); pps.u(1, 0); pps.u(2, 0)               # default refs, no weighted prediction
    pps.se(0); pps.se(0); pps.se(0); pps.u(1, 1); pps.u(1, 0); pps.u(1, 0)   # QP, QS, chroma offset, deblocking control
    out = nal(0x67, sps.rbsp()) + nal(0x68, pps.rbsp())
    idr = BitWriter()
    idr.ue(0); idr.ue(7); idr.ue(0); idr.u(4, 0); idr.ue(0); idr.u(4, 0)   # I slice, frame_num 0, idr_pic_id, POC lsb
    idr.u(1, 0); idr.u(1, 0); idr.se(0); idr.ue(1)               # no output of prior pics, not long term, qp delta, no deblock
    out += nal(0x65, idr.rbsp())
    for i, refs in enumerate(p_refs):
        h = BitWriter()
        h.ue(0); h.ue(5); h.ue(0); h.u(4, (i + 1) & 15); h.u(4, ((i + 1) * 2) & 15)   # P slice, frame_num, POC lsb
        h.u(1, 1); h.ue(refs - 1)                                # num_ref_idx_active_override_flag, l0 count - 1
        h.u(1, 0); h.u(1, 0); h.se(0); h.ue(1)                   # no list modification, sliding window, qp delta, no deblock
        out += nal(0x41, h.rbsp())
    return out


r = h264_refs.analyse(synthetic_stream([1, 1, 1]))
check("synthetic: three one-reference P slices counted", r.p_slices == 3 and r.max_active_refs == 1, f"{r.p_slices}, max {r.max_active_refs}")
r = h264_refs.analyse(synthetic_stream([1, 3, 2]))
check("synthetic: a P slice with 3 references is reported", r.p_slices == 3 and r.max_active_refs == 3, f"{r.p_slices}, max {r.max_active_refs}")

with tempfile.TemporaryDirectory() as td:
    for name, refs, want in (("one_ref.h264", [1, 1, 1], 0), ("multi_ref.h264", [1, 2, 1], 1)):
        f = pathlib.Path(td) / name
        f.write_bytes(synthetic_stream(refs))
        rc = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(f)], capture_output=True, text=True)
        check(f"synthetic {name}: CLI exits {want}", rc.returncode == want, f"exit {rc.returncode}\n{rc.stdout}")
    f = pathlib.Path(td) / "i_only.h264"
    f.write_bytes(synthetic_stream([]))
    rc = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(f)], capture_output=True, text=True)
    check("synthetic I-only stream: CLI exits 1 (nothing to check)", rc.returncode == 1, f"exit {rc.returncode}\n{rc.stdout}")
    rc = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), "--allow-no-p", str(f)], capture_output=True, text=True)
    check("synthetic I-only stream with --allow-no-p: CLI exits 0", rc.returncode == 0, f"exit {rc.returncode}\n{rc.stdout}")

# --- checker must not pass when it checked nothing (no capture needed) ---
with tempfile.TemporaryDirectory() as td:
    empty = pathlib.Path(td) / "empty.h264"; empty.write_bytes(b"")
    rc0 = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(empty)], capture_output=True, text=True)
    check("empty file: CLI exits 1 (nothing was checked)", rc0.returncode == 1, f"exit {rc0.returncode}\n{rc0.stdout}")
    junk = pathlib.Path(td) / "unknown_pps.h264"; junk.write_bytes(bytes([0, 0, 1, 0x41, 0xC3, 0xE0]))   # P slice naming PPS id 30, never defined
    rc1 = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(junk)], capture_output=True, text=True)
    check("P slice with an unknown PPS: CLI exits 1", rc1.returncode == 1, f"exit {rc1.returncode}\n{rc1.stdout}")

if not SR.is_file() or not MULTI.is_file():
    print("note: capture checks skipped (set H264_CAPTURES to a directory with sr-move.h264 and reassembled.h264)"
          + ("; checks above FAILED" if fails else ""))
    sys.exit(1 if fails else 0)

# --- capture: single-reference stream ---
r = h264_refs.analyse(SR.read_bytes())
check("sr-move: 119 P slices", r.p_slices == 119, f"{r.p_slices}")
check("sr-move: every P slice has 1 active L0 ref", r.max_active_refs == 1 and all(
    s.num_ref_idx_l0_active == 1 for s in r.slices if s.is_p
), f"max={r.max_active_refs}")
rc = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(SR)], capture_output=True, text=True)
check("sr-move: CLI exits 0", rc.returncode == 0, f"exit {rc.returncode}\n{rc.stdout}")

# --- capture: multi-reference (unpatched encoder) ---
r2 = h264_refs.analyse(MULTI.read_bytes())
check("reassembled: reports more than 1 active ref", r2.max_active_refs > 1, f"max={r2.max_active_refs}")
rc2 = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(MULTI)], capture_output=True, text=True)
check("reassembled: CLI exits 1", rc2.returncode == 1, f"exit {rc2.returncode}\n{rc2.stdout}")

# --- a good stream followed by a slice that cannot be parsed must not pass ---
with tempfile.TemporaryDirectory() as td:
    tail = pathlib.Path(td) / "good_then_bad.h264"; tail.write_bytes(SR.read_bytes() + bytes([0, 0, 1, 0x41, 0xC3, 0xE0]))
    rc3 = subprocess.run([sys.executable, str(ROOT / "tools/h264_refs.py"), str(tail)], capture_output=True, text=True)
    check("good stream + unparsable P slice: CLI exits 1", rc3.returncode == 1, f"exit {rc3.returncode}\n{rc3.stdout}")

sys.exit(1 if fails else 0)
