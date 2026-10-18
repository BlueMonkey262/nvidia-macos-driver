#!/usr/bin/env python3
"""Parse Annex B HEVC far enough to check an encoder dump against its own headers.

A key frame in the dump must carry VPS, SPS and PPS (three parameter sets) before its slice. The test clip is
8-bit 4:2:0. A slice may not set SAO when the SPS turned SAO off. A P slice's active L0 count may not exceed the
SPS sub-layer 0 buffering (sps_max_dec_pic_buffering_minus1). More than one reference is fine on its own:
Moonlight's SPS fixup runs only for H.264, and HEVC NALs are copied through, so multi-ref is a conformance bug
only when the slice and the SPS disagree.

Max CTU log2 is printed. The library aligns width and height to 32, so 5 is the expected value. A 6 is recorded
and does not fail the file.

usage: hevc_refs.py FILE.hevc
Exit 0 only if at least one IDR was found, every SPS/PPS/slice NAL parsed, and none of the checks above failed.
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple


class BitReader:
    """MSB-first bit reader over an RBSP (emulation prevention already removed)."""

    def __init__(self, data: bytes):
        self.data = data
        self.bitpos = 0

    def remaining_bits(self) -> int:
        return len(self.data) * 8 - self.bitpos

    def u(self, n: int) -> int:
        if n < 0 or self.bitpos + n > len(self.data) * 8:
            raise ValueError(f"need {n} bits at bit {self.bitpos}, have {self.remaining_bits()}")
        v = 0
        for _ in range(n):
            byte = self.data[self.bitpos >> 3]
            bit = (byte >> (7 - (self.bitpos & 7))) & 1
            v = (v << 1) | bit
            self.bitpos += 1
        return v

    def ue(self) -> int:
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 31:
                raise ValueError("ue(v) leading zeros overflow")
        if zeros == 0:
            return 0
        return (1 << zeros) - 1 + self.u(zeros)

    def se(self) -> int:
        code = self.ue()
        if code & 1:
            return (code + 1) // 2
        return -(code // 2)


def remove_emulation_prevention(nal: bytes) -> bytes:
    """Strip 0x03 bytes inserted after 0x0000 (H.265 7.3.1.1, same rule as H.264)."""
    out = bytearray()
    i = 0
    n = len(nal)
    while i < n:
        if i + 2 < n and nal[i] == 0 and nal[i + 1] == 0 and nal[i + 2] == 3:
            out.append(0)
            out.append(0)
            i += 3
            continue
        out.append(nal[i])
        i += 1
    return bytes(out)


def _find_start_codes(data: bytes) -> List[Tuple[int, int]]:
    starts: List[Tuple[int, int]] = []
    i = 0
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        if j > 0 and data[j - 1] == 0:
            starts.append((j - 1, j + 3))
        else:
            starts.append((j, j + 3))
        i = j + 3
    return starts


def iter_annex_b_nals(data: bytes, slice_header_cap: int = 512):
    """Yield (nal_unit_type, rbsp_without_the_2_byte_header) for each Annex B NAL."""
    n = len(data)
    starts = _find_start_codes(data)
    for idx, (_sc, payload) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else n
        if payload + 2 > end:
            continue
        nal = data[payload:end]
        while len(nal) > 2 and nal[-1] == 0:
            nal = nal[:-1]
        ntype = (nal[0] >> 1) & 0x3F
        body = nal[2:]
        if ntype <= 31 and len(body) > slice_header_cap:
            body = body[:slice_header_cap]
        yield ntype, remove_emulation_prevention(body)


def _ceil_log2(n: int) -> int:
    if n <= 1:
        return 0
    return (n - 1).bit_length()


def _profile_ids(profile_idc: int, compat: List[int], ids: Tuple[int, ...]) -> bool:
    if profile_idc in ids:
        return True
    return any(compat[i] for i in ids)


def _profile_present(br: BitReader) -> None:
    """The bits inside profile_tier_level's profilePresentFlag arm (general or a sub-layer)."""
    profile_idc = br.u(2 + 1 + 5) & 0x1F  # profile_space, tier, profile_idc
    compat = [br.u(1) for _ in range(32)]
    br.u(4)  # progressive, interlaced, non_packed, frame_only
    if _profile_ids(profile_idc, compat, (4, 5, 6, 7, 8, 9, 10, 11)):
        br.u(9)  # the nine constraint flags through general_lower_bit_rate_constraint_flag
        if _profile_ids(profile_idc, compat, (5, 9, 10, 11)):
            br.u(1 + 33)  # max_14bit + reserved 33
        else:
            br.u(34)
    elif profile_idc == 2 or compat[2]:
        br.u(7 + 1 + 35)
    else:
        br.u(43)
    br.u(1)  # general_inbld_flag, or the reserved zero bit


def _profile_tier_level(br: BitReader, max_sub_layers_minus1: int) -> None:
    _profile_present(br)
    br.u(8)  # general_level_idc
    sub_profile = []
    sub_level = []
    for _ in range(max_sub_layers_minus1):
        sub_profile.append(br.u(1))
        sub_level.append(br.u(1))
    if max_sub_layers_minus1 > 0:
        for _ in range(max_sub_layers_minus1, 8):
            br.u(2)
    for i in range(max_sub_layers_minus1):
        if sub_profile[i]:
            _profile_present(br)
        if sub_level[i]:
            br.u(8)


def _skip_scaling_list(br: BitReader) -> None:
    for size_id in range(4):
        matrix_id = 0
        while matrix_id < 6:
            if br.u(1) == 0:
                br.ue()  # scaling_list_pred_matrix_id_delta
            else:
                coef_num = min(64, 1 << (4 + (size_id << 1)))
                if size_id > 1:
                    br.se()  # scaling_list_dc_coef_minus8
                for _ in range(coef_num):
                    br.se()
            matrix_id += 3 if size_id == 3 else 1


@dataclass
class RPS:
    num_neg: int
    num_pos: int
    dpoc_s0: List[int] = field(default_factory=list)
    dpoc_s1: List[int] = field(default_factory=list)


def _parse_st_ref_pic_set(br: BitReader, st_rps_idx: int, num_sets: int, sets: List[RPS]) -> RPS:
    inter = br.u(1) if st_rps_idx != 0 else 0
    if inter:
        delta_idx = br.ue() if st_rps_idx == num_sets else 0
        ref_idx = st_rps_idx - (delta_idx + 1)
        if ref_idx < 0 or ref_idx >= len(sets):
            raise ValueError(f"st_ref_pic_set predicts from {ref_idx}, have {len(sets)}")
        ref = sets[ref_idx]
        sign = br.u(1)
        delta_rps = (1 - 2 * sign) * (br.ue() + 1)
        num_delta = ref.num_neg + ref.num_pos
        used = []
        use_delta = []
        for _ in range(num_delta + 1):
            u = br.u(1)
            used.append(u)
            use_delta.append(1 if u else br.u(1))
        dpoc_s0: List[int] = []
        for j in range(ref.num_pos - 1, -1, -1):
            d_poc = ref.dpoc_s1[j] + delta_rps
            if d_poc < 0 and use_delta[ref.num_neg + j]:
                dpoc_s0.append(d_poc)
        if delta_rps < 0 and use_delta[num_delta]:
            dpoc_s0.append(delta_rps)
        dpoc_s1: List[int] = []
        if delta_rps > 0 and use_delta[num_delta]:
            dpoc_s1.append(delta_rps)
        for j in range(ref.num_neg):
            d_poc = ref.dpoc_s0[j] + delta_rps
            if d_poc > 0 and use_delta[j]:
                dpoc_s1.append(d_poc)
        return RPS(len(dpoc_s0), len(dpoc_s1), dpoc_s0, dpoc_s1)
    num_neg = br.ue()
    num_pos = br.ue()
    if num_neg > 16 or num_pos > 16:
        raise ValueError(f"st_ref_pic_set size {num_neg}+{num_pos} is not plausible")
    dpoc_s0 = []
    for i in range(num_neg):
        delta = br.ue() + 1
        prev = 0 if i == 0 else dpoc_s0[-1]
        dpoc_s0.append(prev - delta)
        br.u(1)  # used_by_curr_pic_s0_flag
    dpoc_s1 = []
    for i in range(num_pos):
        delta = br.ue() + 1
        prev = 0 if i == 0 else dpoc_s1[-1]
        dpoc_s1.append(prev + delta)
        br.u(1)
    return RPS(num_neg, num_pos, dpoc_s0, dpoc_s1)


@dataclass
class SPS:
    seq_parameter_set_id: int = 0
    chroma_format_idc: int = 1
    separate_colour_plane_flag: int = 0
    bit_depth_luma_minus8: int = 0
    bit_depth_chroma_minus8: int = 0
    log2_max_pic_order_cnt_lsb_minus4: int = 0
    sps_max_dec_pic_buffering_minus1: int = 0
    sps_max_num_reorder_pics: int = 0
    log2_min_luma_coding_block_size_minus3: int = 0
    log2_diff_max_min_luma_coding_block_size: int = 0
    max_ctu_log2: int = 0
    sample_adaptive_offset_enabled_flag: int = 0
    num_short_term_ref_pic_sets: int = 0
    rps: List[RPS] = field(default_factory=list)
    long_term_ref_pics_present_flag: int = 0
    num_long_term_ref_pics_sps: int = 0
    sps_temporal_mvp_enabled_flag: int = 0
    pic_width: int = 0
    pic_height: int = 0
    pic_size_in_ctbs: int = 0

    @property
    def chroma_array_type(self) -> int:
        if self.separate_colour_plane_flag:
            return 0
        return self.chroma_format_idc


@dataclass
class PPS:
    pic_parameter_set_id: int = 0
    seq_parameter_set_id: int = 0
    dependent_slice_segments_enabled_flag: int = 0
    output_flag_present_flag: int = 0
    num_extra_slice_header_bits: int = 0
    num_ref_idx_l0_default_active_minus1: int = 0
    num_ref_idx_l1_default_active_minus1: int = 0


@dataclass
class SliceInfo:
    nal_type: int
    slice_type: Optional[int]
    is_p: bool
    num_ref_idx_l0_active: Optional[int]
    sao_luma: int
    sao_chroma: int
    sps_id: int
    dependent: bool = False


def parse_sps(rbsp: bytes) -> SPS:
    br = BitReader(rbsp)
    sps = SPS()
    br.u(4)  # sps_video_parameter_set_id
    max_sub = br.u(3)
    br.u(1)  # sps_temporal_id_nesting_flag
    _profile_tier_level(br, max_sub)
    sps.seq_parameter_set_id = br.ue()
    sps.chroma_format_idc = br.ue()
    if sps.chroma_format_idc == 3:
        sps.separate_colour_plane_flag = br.u(1)
    sps.pic_width = br.ue()
    sps.pic_height = br.ue()
    if br.u(1):  # conformance_window_flag
        br.ue()
        br.ue()
        br.ue()
        br.ue()
    sps.bit_depth_luma_minus8 = br.ue()
    sps.bit_depth_chroma_minus8 = br.ue()
    sps.log2_max_pic_order_cnt_lsb_minus4 = br.ue()
    ordering = br.u(1)
    # Sub-layer 0 is stored explicitly when the flag is set, otherwise it is inferred from the highest.
    start = 0 if ordering else max_sub
    buf = [0] * (max_sub + 1)
    reorder = [0] * (max_sub + 1)
    for i in range(start, max_sub + 1):
        buf[i] = br.ue()
        reorder[i] = br.ue()
        br.ue()  # sps_max_latency_increase_plus1
    for i in range(start):
        buf[i] = buf[start]
        reorder[i] = reorder[start]
    sps.sps_max_dec_pic_buffering_minus1 = buf[0]
    sps.sps_max_num_reorder_pics = reorder[0]
    sps.log2_min_luma_coding_block_size_minus3 = br.ue()
    sps.log2_diff_max_min_luma_coding_block_size = br.ue()
    sps.max_ctu_log2 = (sps.log2_min_luma_coding_block_size_minus3 + 3
                        + sps.log2_diff_max_min_luma_coding_block_size)
    br.ue()  # log2_min_luma_transform_block_size_minus2
    br.ue()  # log2_diff_max_min_luma_transform_block_size
    br.ue()  # max_transform_hierarchy_depth_inter
    br.ue()  # max_transform_hierarchy_depth_intra
    if br.u(1):  # scaling_list_enabled_flag
        if br.u(1):
            _skip_scaling_list(br)
    br.u(1)  # amp_enabled_flag
    sps.sample_adaptive_offset_enabled_flag = br.u(1)
    if br.u(1):  # pcm_enabled_flag
        br.u(4)
        br.u(4)
        br.ue()
        br.ue()
        br.u(1)
    sps.num_short_term_ref_pic_sets = br.ue()
    if sps.num_short_term_ref_pic_sets > 64:
        raise ValueError(f"num_short_term_ref_pic_sets {sps.num_short_term_ref_pic_sets} is not plausible")
    for i in range(sps.num_short_term_ref_pic_sets):
        sps.rps.append(_parse_st_ref_pic_set(br, i, sps.num_short_term_ref_pic_sets, sps.rps))
    sps.long_term_ref_pics_present_flag = br.u(1)
    if sps.long_term_ref_pics_present_flag:
        sps.num_long_term_ref_pics_sps = br.ue()
        poc_bits = sps.log2_max_pic_order_cnt_lsb_minus4 + 4
        for _ in range(sps.num_long_term_ref_pics_sps):
            br.u(poc_bits)
            br.u(1)
    sps.sps_temporal_mvp_enabled_flag = br.u(1)
    ctu = 1 << sps.max_ctu_log2
    if ctu <= 0 or sps.pic_width <= 0 or sps.pic_height <= 0:
        raise ValueError("SPS picture size is empty")
    sps.pic_size_in_ctbs = ((sps.pic_width + ctu - 1) // ctu) * ((sps.pic_height + ctu - 1) // ctu)
    return sps


def parse_pps(rbsp: bytes) -> PPS:
    br = BitReader(rbsp)
    pps = PPS()
    pps.pic_parameter_set_id = br.ue()
    pps.seq_parameter_set_id = br.ue()
    pps.dependent_slice_segments_enabled_flag = br.u(1)
    pps.output_flag_present_flag = br.u(1)
    pps.num_extra_slice_header_bits = br.u(3)
    br.u(1)  # sign_data_hiding_enabled_flag
    br.u(1)  # cabac_init_present_flag
    pps.num_ref_idx_l0_default_active_minus1 = br.ue()
    pps.num_ref_idx_l1_default_active_minus1 = br.ue()
    return pps


def _slice_long_term(br: BitReader, sps: SPS) -> None:
    n_sps = br.ue() if sps.num_long_term_ref_pics_sps > 0 else 0
    n_pics = br.ue()
    if n_sps + n_pics > 16:
        raise ValueError("too many long-term pictures in a slice")
    poc_bits = sps.log2_max_pic_order_cnt_lsb_minus4 + 4
    for i in range(n_sps + n_pics):
        if i < n_sps:
            if sps.num_long_term_ref_pics_sps > 1:
                br.u(_ceil_log2(sps.num_long_term_ref_pics_sps))
        else:
            br.u(poc_bits)
            br.u(1)
        if br.u(1):
            br.ue()


def parse_slice_header(rbsp: bytes, nal_type: int, sps_map: Dict[int, SPS], pps_map: Dict[int, PPS]) -> SliceInfo:
    br = BitReader(rbsp)
    first = br.u(1)
    if 16 <= nal_type <= 23:
        br.u(1)  # no_output_of_prior_pics_flag
    pps_id = br.ue()
    if pps_id not in pps_map:
        raise ValueError(f"unknown PPS id {pps_id}")
    pps = pps_map[pps_id]
    if pps.seq_parameter_set_id not in sps_map:
        raise ValueError(f"unknown SPS id {pps.seq_parameter_set_id}")
    sps = sps_map[pps.seq_parameter_set_id]
    dependent = 0
    if not first:
        if pps.dependent_slice_segments_enabled_flag:
            dependent = br.u(1)
        br.u(_ceil_log2(sps.pic_size_in_ctbs))
    if dependent:
        return SliceInfo(nal_type, None, False, None, 0, 0, sps.seq_parameter_set_id, dependent=True)
    for _ in range(pps.num_extra_slice_header_bits):
        br.u(1)
    slice_type = br.ue()
    if slice_type > 2:
        raise ValueError(f"slice_type {slice_type} out of range")
    if pps.output_flag_present_flag:
        br.u(1)
    if sps.separate_colour_plane_flag:
        br.u(2)
    if nal_type not in (19, 20):
        br.u(sps.log2_max_pic_order_cnt_lsb_minus4 + 4)
        if br.u(1) == 0:  # short_term_ref_pic_set_sps_flag
            _parse_st_ref_pic_set(br, sps.num_short_term_ref_pic_sets, sps.num_short_term_ref_pic_sets, sps.rps)
        elif sps.num_short_term_ref_pic_sets > 1:
            br.u(_ceil_log2(sps.num_short_term_ref_pic_sets))
        if sps.long_term_ref_pics_present_flag:
            _slice_long_term(br, sps)
        if sps.sps_temporal_mvp_enabled_flag:
            br.u(1)
    sao_luma = 0
    sao_chroma = 0
    if sps.sample_adaptive_offset_enabled_flag:
        sao_luma = br.u(1)
        if sps.chroma_array_type != 0:
            sao_chroma = br.u(1)
    num_ref: Optional[int] = None
    if slice_type in (0, 1):  # B or P
        if br.u(1):  # num_ref_idx_active_override_flag
            num_ref = br.ue() + 1
            if slice_type == 0:
                br.ue()
        else:
            num_ref = pps.num_ref_idx_l0_default_active_minus1 + 1
    return SliceInfo(
        nal_type=nal_type,
        slice_type=slice_type,
        is_p=(slice_type == 1),
        num_ref_idx_l0_active=num_ref,
        sao_luma=sao_luma,
        sao_chroma=sao_chroma,
        sps_id=sps.seq_parameter_set_id,
    )


@dataclass
class StreamReport:
    sps_by_id: Dict[int, SPS] = field(default_factory=dict)
    sps_list: List[SPS] = field(default_factory=list)
    slices: List[SliceInfo] = field(default_factory=list)
    key_param_sets: List[List[int]] = field(default_factory=list)
    idr_count: int = 0
    p_slices: int = 0
    max_active_refs: int = 0
    errors: List[str] = field(default_factory=list)


def analyse(data: bytes) -> StreamReport:
    sps_map: Dict[int, SPS] = {}
    pps_map: Dict[int, PPS] = {}
    report = StreamReport()
    pending: List[int] = []
    for ntype, rbsp in iter_annex_b_nals(data):
        try:
            if ntype in (32, 33, 34):
                pending.append(ntype)
                if ntype == 33:
                    sps = parse_sps(rbsp)
                    sps_map[sps.seq_parameter_set_id] = sps
                    report.sps_by_id[sps.seq_parameter_set_id] = sps
                    report.sps_list.append(sps)
                elif ntype == 34:
                    pps = parse_pps(rbsp)
                    pps_map[pps.pic_parameter_set_id] = pps
            elif ntype <= 31:
                if ntype in (19, 20):
                    report.idr_count += 1
                    report.key_param_sets.append(list(pending))
                pending = []
                info = parse_slice_header(rbsp, ntype, sps_map, pps_map)
                report.slices.append(info)
                if info.is_p and info.num_ref_idx_l0_active is not None:
                    report.p_slices += 1
                    if info.num_ref_idx_l0_active > report.max_active_refs:
                        report.max_active_refs = info.num_ref_idx_l0_active
        except Exception as e:
            report.errors.append(f"NAL type {ntype}: {e}")
            if ntype <= 31:
                pending = []
    return report


def problems(report: StreamReport) -> List[str]:
    found = list(report.errors)
    if report.idr_count == 0:
        found.append("no key frame, so the parameter-set count was not checked")
    for sets in report.key_param_sets:
        if sets != [32, 33, 34]:
            found.append(f"key frame parameter sets {sets}, wanted VPS, SPS, PPS")
    for sps in report.sps_list:
        if sps.chroma_format_idc != 1:
            found.append(f"SPS {sps.seq_parameter_set_id} chroma_format_idc {sps.chroma_format_idc}, wanted 1")
        if sps.bit_depth_luma_minus8 != 0 or sps.bit_depth_chroma_minus8 != 0:
            found.append(
                f"SPS {sps.seq_parameter_set_id} bit depth "
                f"{sps.bit_depth_luma_minus8 + 8}/{sps.bit_depth_chroma_minus8 + 8}, wanted 8")
    for sl in report.slices:
        if sl.dependent:
            continue
        sps = report.sps_by_id.get(sl.sps_id)
        if sps is None:
            continue
        if not sps.sample_adaptive_offset_enabled_flag and (sl.sao_luma or sl.sao_chroma):
            found.append("slice SAO flags are set while SPS sample_adaptive_offset_enabled_flag is 0")
        if (sl.is_p and sl.num_ref_idx_l0_active is not None
                and sl.num_ref_idx_l0_active > sps.sps_max_dec_pic_buffering_minus1):
            found.append(
                f"P slice active L0 {sl.num_ref_idx_l0_active} exceeds "
                f"sps_max_dec_pic_buffering_minus1 {sps.sps_max_dec_pic_buffering_minus1}")
    return found


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("file", help="Annex B HEVC bitstream")
    args = ap.parse_args(argv)
    data = open(args.file, "rb").read()
    report = analyse(data)
    # A dump repeats the SPS on every key frame. Print each id once; problems() still sees every copy.
    by_id = {}
    for sps in report.sps_list:
        by_id[sps.seq_parameter_set_id] = sps
    for sps in by_id.values():
        tag = f" (SPS {sps.seq_parameter_set_id})" if len(by_id) != 1 else ""
        print(f"chroma_format_idc{tag}: {sps.chroma_format_idc}")
        print(f"bit_depth_luma{tag}: {sps.bit_depth_luma_minus8 + 8}")
        print(f"bit_depth_chroma{tag}: {sps.bit_depth_chroma_minus8 + 8}")
        print(f"max CTU log2{tag}: {sps.max_ctu_log2}")
        print(f"SPS SAO{tag}: {sps.sample_adaptive_offset_enabled_flag}")
        print(f"sub-layer 0 sps_max_dec_pic_buffering_minus1{tag}: {sps.sps_max_dec_pic_buffering_minus1}")
        print(f"sub-layer 0 sps_max_num_reorder_pics{tag}: {sps.sps_max_num_reorder_pics}")
    print(f"IDR frames: {report.idr_count}")
    print(f"P slices: {report.p_slices}")
    print(f"max active L0 (P): {report.max_active_refs}")
    bad = problems(report)
    for err in bad:
        print(f"FAIL: {err}", file=sys.stderr)
    if bad:
        print(f"FAIL: {len(bad)} check(s)")
        return 1
    print("OK: parameter sets, 8-bit 4:2:0, SAO and L0 counts agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
