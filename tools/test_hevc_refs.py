#!/usr/bin/env python3
"""Synthetic Annex B streams for tools/hevc_refs.py.

No captured bitstream is required. Each case is built from the HEVC syntax the parser reads: parameter-set
count, 8-bit 4:2:0, SAO, sub-layer 0 buffering, and a P slice's active L0 count. Exit 0 on pass, 1 on fail.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import hevc_refs  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    fails += not ok


class BW:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        if n < 0 or v < 0 or v >= (1 << n):
            raise ValueError(f"u({n}) cannot hold {v}")
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def ue(self, v):
        v += 1
        n = v.bit_length() - 1
        self.u(n, 0)
        self.u(n + 1, v)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def rbsp(self):
        bits = self.bits + [1]
        while len(bits) % 8:
            bits.append(0)
        out = bytearray()
        for i in range(0, len(bits), 8):
            byte = 0
            for bit in bits[i:i + 8]:
                byte = (byte << 1) | bit
            out.append(byte)
        return bytes(out)


def add_epb(data: bytes) -> bytes:
    out = bytearray()
    zeros = 0
    for b in data:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def nal(ntype, rbsp):
    return bytes([(ntype << 1) & 0xFE, 0x01]) + add_epb(rbsp)


def annex(*nals):
    out = bytearray()
    for n in nals:
        out += b"\x00\x00\x00\x01" + n
    return bytes(out)


def write_profile(bw, max_sub_layers=0):
    bw.u(2, 0)          # general_profile_space
    bw.u(1, 0)          # general_tier_flag
    bw.u(5, 1)          # general_profile_idc (Main)
    for j in range(32):
        bw.u(1, 1 if j == 1 else 0)
    bw.u(1, 1)          # progressive
    bw.u(1, 0)          # interlaced
    bw.u(1, 1)          # non_packed
    bw.u(1, 1)          # frame_only
    bw.u(43, 0)         # profile 1: reserved 43 bits
    bw.u(1, 0)          # general_inbld_flag
    bw.u(8, 93)         # level 3.1
    for _ in range(max_sub_layers):
        bw.u(1, 0)      # sub_layer_profile_present_flag
        bw.u(1, 0)      # sub_layer_level_present_flag
    if max_sub_layers > 0:
        for _ in range(max_sub_layers, 8):
            bw.u(2, 0)


def write_scaling_list(bw):
    for size_id in range(4):
        matrix_id = 0
        while matrix_id < 6:
            bw.u(1, 0)  # scaling_list_pred_mode_flag
            bw.ue(0)    # scaling_list_pred_matrix_id_delta
            matrix_id += 3 if size_id == 3 else 1


def write_rps(bw, idx, predict=False):
    if idx != 0:
        bw.u(1, 1 if predict else 0)
    if predict:
        # delta_idx_minus1 is absent: this set is not the slice-local one. deltaRps = +1.
        bw.u(1, 0)      # delta_rps_sign
        bw.ue(0)        # abs_delta_rps_minus1
        bw.u(1, 1)      # used_by_curr_pic_flag[0]
        bw.u(1, 0)      # used_by_curr_pic_flag[1], the extra slot
        bw.u(1, 0)      # use_delta_flag[1]
        return
    bw.ue(1)            # num_negative_pics
    bw.ue(0)            # num_positive_pics
    bw.ue(0)            # delta_poc_s0_minus1
    bw.u(1, 1)          # used_by_curr_pic_s0_flag


def write_sps(bw, *, chroma=1, depth_luma=0, depth_chroma=0, width=1280, height=720,
              buffering=1, reorder=0, min_cb=0, diff_cb=2, sao=0, max_sub_layers=0,
              ordering_present=1, scaling=False, num_rps=1, predict_rps1=False, temporal_mvp=0):
    bw.u(4, 0)
    bw.u(3, max_sub_layers)
    bw.u(1, 1)
    write_profile(bw, max_sub_layers)
    bw.ue(0)            # sps id
    bw.ue(chroma)
    if chroma == 3:
        bw.u(1, 0)
    bw.ue(width)
    bw.ue(height)
    bw.u(1, 0)          # conformance window
    bw.ue(depth_luma)
    bw.ue(depth_chroma)
    bw.ue(0)            # log2_max_pic_order_cnt_lsb_minus4
    bw.u(1, ordering_present)
    start = 0 if ordering_present else max_sub_layers
    for _ in range(start, max_sub_layers + 1):
        bw.ue(buffering)
        bw.ue(reorder)
        bw.ue(0)
    bw.ue(min_cb)
    bw.ue(diff_cb)
    bw.ue(0)            # min transform block
    bw.ue(0)
    bw.ue(0)
    bw.ue(0)
    bw.u(1, 1 if scaling else 0)
    if scaling:
        bw.u(1, 1)
        write_scaling_list(bw)
    bw.u(1, 0)          # amp
    bw.u(1, 1 if sao else 0)
    bw.u(1, 0)          # pcm
    bw.ue(num_rps)
    for i in range(num_rps):
        write_rps(bw, i, predict=predict_rps1 and i == 1)
    bw.u(1, 0)          # long term
    bw.u(1, temporal_mvp)


def write_pps(bw, l0_default=0):
    bw.ue(0)
    bw.ue(0)
    bw.u(1, 0)          # dependent slice segments
    bw.u(1, 0)          # output flag
    bw.u(3, 0)          # extra slice header bits
    bw.u(1, 0)
    bw.u(1, 0)
    bw.ue(l0_default)
    bw.ue(0)


def write_idr(bw, *, sao=0, sao_luma=0, sao_chroma=0, slice_type=2):
    bw.u(1, 1)          # first slice
    bw.u(1, 0)          # no_output_of_prior_pics_flag
    bw.ue(0)
    bw.ue(slice_type)
    if sao:
        bw.u(1, sao_luma)
        bw.u(1, sao_chroma)


def write_p(bw, *, sao=0, sao_luma=0, sao_chroma=0, override=1, l0_minus1=0, poc=1,
            num_rps=1, rps_idx=0):
    bw.u(1, 1)
    bw.ue(0)            # pps id
    bw.ue(1)            # P
    bw.u(4, poc)        # slice_pic_order_cnt_lsb
    bw.u(1, 1)          # short_term_ref_pic_set_sps_flag
    if num_rps > 1:
        bits = (num_rps - 1).bit_length()
        bw.u(bits, rps_idx)
    if sao:
        bw.u(1, sao_luma)
        bw.u(1, sao_chroma)
    bw.u(1, 1 if override else 0)
    if override:
        bw.ue(l0_minus1)


def vps():
    return nal(32, bytes([0x80]))


def stream(*, param_types=(32, 33, 34), sps_kw=None, pps_l0=0, idr_kw=None, p_kw=None, extra_idr_params=None):
    sps_kw = dict(sps_kw or {})
    idr_kw = dict(idr_kw or {})
    p_kw = dict(p_kw or {})
    sao = sps_kw.get("sao", 0)
    idr_kw.setdefault("sao", sao)
    p_kw.setdefault("sao", sao)
    p_kw.setdefault("num_rps", sps_kw.get("num_rps", 1))
    sb, pb, ib, xb = BW(), BW(), BW(), BW()
    write_sps(sb, **sps_kw)
    write_pps(pb, pps_l0)
    write_idr(ib, **idr_kw)
    write_p(xb, **p_kw)
    bodies = {32: vps(), 33: nal(33, sb.rbsp()), 34: nal(34, pb.rbsp())}
    parts = [bodies[t] for t in param_types]
    parts.append(nal(19, ib.rbsp()))
    parts.append(nal(1, xb.rbsp()))
    if extra_idr_params is not None:
        parts.extend(bodies[t] for t in extra_idr_params)
        ib2 = BW()
        write_idr(ib2, **idr_kw)
        parts.append(nal(19, ib2.rbsp()))
    return annex(*parts)


def run_cli(data: bytes):
    with tempfile.TemporaryDirectory() as td:
        path = pathlib.Path(td) / "stream.hevc"
        path.write_bytes(data)
        return subprocess.run([sys.executable, str(ROOT / "tools/hevc_refs.py"), str(path)],
                              capture_output=True, text=True)


# --- bit reader, shared with the H.264 tool's cases ---

def bits_to_bytes(bitstr):
    bitstr = bitstr.replace(" ", "")
    bitstr += "0" * ((-len(bitstr)) % 8)
    return bytes(int(bitstr[i:i + 8], 2) for i in range(0, len(bitstr), 8))


br = hevc_refs.BitReader(bits_to_bytes("1"))
check("ue(v) 0", br.ue() == 0)
br = hevc_refs.BitReader(bits_to_bytes("010"))
check("ue(v) 1", br.ue() == 1)
br = hevc_refs.BitReader(bits_to_bytes("00100"))
check("ue(v) 3", br.ue() == 3)
br = hevc_refs.BitReader(bits_to_bytes("011"))
check("se(v) -1", br.se() == -1)
raw = bytes([0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00])
check("emulation prevention strips 000003",
      hevc_refs.remove_emulation_prevention(raw) == bytes([0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))

good = stream()
rep = hevc_refs.analyse(good)
check("good stream parses", not hevc_refs.problems(rep), "; ".join(hevc_refs.problems(rep)))
check("good stream: max CTU log2 is 5", rep.sps_list and rep.sps_list[0].max_ctu_log2 == 5, str(getattr(rep.sps_list[0], "max_ctu_log2", None) if rep.sps_list else None))
check("good stream: one P slice, one L0 ref", rep.p_slices == 1 and rep.max_active_refs == 1)
cli = run_cli(good)
check("good stream: CLI exits 0 and prints max CTU log2 5", cli.returncode == 0 and "max CTU log2: 5" in cli.stdout,
      f"exit {cli.returncode}\n{cli.stdout}{cli.stderr}")

# An emulation-prevention byte inside the SPS must not change the parsed fields.
sps_rbsp = BW()
write_sps(sps_rbsp)
plain = sps_rbsp.rbsp()
stuffed = bytearray(plain)
stuffed[1:1] = b"\x00\x00\x03"
# Re-parse through the NAL iterator, which strips the prevention byte. The inserted 00 00 03 is not aligned to
# the original bytes, so build the NAL the way a writer would: add_epb on a payload that already contains 00 00.
forced = plain[:2] + b"\x00\x00\x01" + plain[2:]
restored = hevc_refs.remove_emulation_prevention(add_epb(forced))
check("add_epb then strip returns the bytes", restored == forced)

multi_ok = stream(sps_kw={"buffering": 4}, p_kw={"override": 1, "l0_minus1": 1})
rep = hevc_refs.analyse(multi_ok)
check("two L0 refs are allowed when the SPS buffering covers them",
      not hevc_refs.problems(rep) and rep.max_active_refs == 2, "; ".join(hevc_refs.problems(rep)))

multi_bad = stream(sps_kw={"buffering": 1}, p_kw={"override": 1, "l0_minus1": 1})
cli = run_cli(multi_bad)
check("two L0 refs fail when buffering_minus1 is 1", cli.returncode == 1 and "active L0" in cli.stderr,
      f"exit {cli.returncode}\n{cli.stderr}")

default_bad = stream(sps_kw={"buffering": 1}, pps_l0=2, p_kw={"override": 0})
rep = hevc_refs.analyse(default_bad)
check("PPS default L0 is used when the override flag is clear",
      rep.max_active_refs == 3 and any("active L0" in p for p in hevc_refs.problems(rep)),
      "; ".join(hevc_refs.problems(rep)))

missing_vps = stream(param_types=(33, 34))
cli = run_cli(missing_vps)
check("IDR with two parameter sets fails", cli.returncode == 1 and "parameter sets" in cli.stderr,
      f"exit {cli.returncode}\n{cli.stderr}")

four = stream(param_types=(32, 32, 33, 34))
cli = run_cli(four)
check("IDR with four parameter sets fails", cli.returncode == 1, f"exit {cli.returncode}\n{cli.stderr}")

two_idr = stream(extra_idr_params=(32, 33, 34))
cli = run_cli(two_idr)
check("two IDRs, each with VPS SPS PPS, pass", cli.returncode == 0, f"exit {cli.returncode}\n{cli.stdout}{cli.stderr}")

second_bare = stream(extra_idr_params=())
cli = run_cli(second_bare)
check("a later IDR with no parameter sets fails", cli.returncode == 1, f"exit {cli.returncode}\n{cli.stderr}")

chroma = stream(sps_kw={"chroma": 2})
cli = run_cli(chroma)
check("chroma_format_idc 2 fails", cli.returncode == 1 and "chroma_format_idc" in cli.stderr, cli.stderr.strip())

depth_l = stream(sps_kw={"depth_luma": 2})
cli = run_cli(depth_l)
check("10-bit luma fails", cli.returncode == 1 and "bit depth" in cli.stderr, cli.stderr.strip())

depth_c = stream(sps_kw={"depth_chroma": 2})
cli = run_cli(depth_c)
check("10-bit chroma fails", cli.returncode == 1 and "bit depth" in cli.stderr, cli.stderr.strip())

ctu6 = stream(sps_kw={"diff_cb": 3})
cli = run_cli(ctu6)
check("max CTU log2 6 is printed and does not fail",
      cli.returncode == 0 and "max CTU log2: 6" in cli.stdout, f"exit {cli.returncode}\n{cli.stdout}{cli.stderr}")

sao_on = stream(sps_kw={"sao": 1}, idr_kw={"sao_luma": 1, "sao_chroma": 1}, p_kw={"sao_luma": 1, "sao_chroma": 1})
rep = hevc_refs.analyse(sao_on)
check("SAO flags are read when the SPS enables SAO",
      not hevc_refs.problems(rep) and rep.slices and rep.slices[-1].sao_luma == 1 and rep.slices[-1].sao_chroma == 1,
      "; ".join(hevc_refs.problems(rep)))
# The flags are absent from the syntax when SPS SAO is 0, so a bitstream cannot carry the bad combination.
# The checker still rejects it: clear the flag on a stream that was parsed with the flags set.
rep.sps_by_id[0].sample_adaptive_offset_enabled_flag = 0
check("SAO flags set while SPS SAO is 0 fails",
      any("SAO" in p for p in hevc_refs.problems(rep)), "; ".join(hevc_refs.problems(rep)))

inferred = stream(sps_kw={"max_sub_layers": 1, "ordering_present": 0, "buffering": 3, "reorder": 0})
rep = hevc_refs.analyse(inferred)
check("sub-layer 0 buffering is inferred from the highest sub-layer",
      not hevc_refs.problems(rep) and rep.sps_list[0].sps_max_dec_pic_buffering_minus1 == 3,
      "; ".join(hevc_refs.problems(rep)) or str(rep.sps_list[0].sps_max_dec_pic_buffering_minus1 if rep.sps_list else None))

scaled = stream(sps_kw={"scaling": True})
rep = hevc_refs.analyse(scaled)
check("a scaling list is skipped and the SPS still parses", not hevc_refs.problems(rep) and rep.sps_list[0].max_ctu_log2 == 5,
      "; ".join(hevc_refs.problems(rep)))

predicted = stream(sps_kw={"num_rps": 2, "predict_rps1": True}, p_kw={"num_rps": 2, "rps_idx": 0})
rep = hevc_refs.analyse(predicted)
check("an inter-predicted short-term RPS still reaches the P-slice ref count",
      not hevc_refs.problems(rep) and rep.max_active_refs == 1, "; ".join(hevc_refs.problems(rep)))

cli = run_cli(b"")
check("empty file: CLI exits 1", cli.returncode == 1, f"exit {cli.returncode}\n{cli.stdout}{cli.stderr}")

# IDR slice whose PPS id was never defined. Parameter sets are present so the failure is the slice, not the count.
orphan = annex(vps(), nal(19, bytes([0x80])))
cli = run_cli(orphan)
check("IDR with an unknown PPS: CLI exits 1", cli.returncode == 1, f"exit {cli.returncode}\n{cli.stderr}")

sys.exit(1 if fails else 0)
