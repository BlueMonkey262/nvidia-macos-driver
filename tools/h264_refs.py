#!/usr/bin/env python3
"""Parse Annex B H.264 enough to report per-P-slice effective num_ref_idx_l0_active.

Moonlight rewrites every SPS to num_ref_frames=1 and decodes with AV_EF_EXPLODE, so any P-slice
with more than one active L0 reference fails. This tool is the offline regression guard for that.

usage: h264_refs.py [--max-refs N] [--allow-no-p] FILE.h264
Prints SPS max_num_ref_frames, P-slice count, and the maximum active L0 refs among P slices.
Exit 0 only if at least one P slice was found, every NAL unit parsed, and every P slice uses at most N active refs
(default 1). B slices are not examined (the encoder under test does not code them).
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

    def f(self, n: int) -> int:
        return self.u(n)

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
    """Strip 0x03 bytes inserted after 0x0000 in the NAL (H.264 7.3.1 / 7.4.1)."""
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
    """Return list of (start_code_offset, payload_offset) for 3- and 4-byte start codes."""
    starts: List[Tuple[int, int]] = []
    n = len(data)
    i = 0
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        if j > 0 and data[j - 1] == 0:
            starts.append((j - 1, j + 3))  # 00 00 00 01
        else:
            starts.append((j, j + 3))  # 00 00 01
        i = j + 3
    return starts


def iter_annex_b_nals(data: bytes, slice_header_cap: int = 512):
    """Yield (nal_unit_type, rbsp_without_header_byte) for each Annex B NAL.

    Slice NALs only need the header bits; cap RBSP work so large IDR bodies stay cheap.
    """
    n = len(data)
    starts = _find_start_codes(data)
    for idx, (_sc, payload) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else n
        if payload >= end:
            continue
        nal = data[payload:end]
        while len(nal) > 1 and nal[-1] == 0:
            nal = nal[:-1]
        if not nal:
            continue
        ntype = nal[0] & 0x1F
        body = nal[1:]
        if ntype in (1, 5) and len(body) > slice_header_cap:
            body = body[:slice_header_cap]
        rbsp = remove_emulation_prevention(body)
        yield ntype, rbsp


@dataclass
class SPS:
    seq_parameter_set_id: int = 0
    profile_idc: int = 0
    chroma_format_idc: int = 1
    separate_colour_plane_flag: int = 0
    log2_max_frame_num_minus4: int = 0
    pic_order_cnt_type: int = 0
    log2_max_pic_order_cnt_lsb_minus4: int = 0
    delta_pic_order_always_zero_flag: int = 0
    max_num_ref_frames: int = 0
    frame_mbs_only_flag: int = 1
    mb_adaptive_frame_field_flag: int = 0


@dataclass
class PPS:
    pic_parameter_set_id: int = 0
    seq_parameter_set_id: int = 0
    entropy_coding_mode_flag: int = 0
    bottom_field_pic_order_in_frame_present_flag: int = 0
    num_slice_groups_minus1: int = 0
    num_ref_idx_l0_default_active_minus1: int = 0
    num_ref_idx_l1_default_active_minus1: int = 0
    weighted_pred_flag: int = 0
    weighted_bipred_idc: int = 0
    redundant_pic_cnt_present_flag: int = 0


@dataclass
class SliceInfo:
    nal_type: int
    slice_type: int
    is_p: bool
    num_ref_idx_l0_active: Optional[int]  # None for I/SI


def _skip_scaling_list(br: BitReader, size: int) -> None:
    last_scale = 8
    next_scale = 8
    for _ in range(size):
        if next_scale != 0:
            delta = br.se()
            next_scale = (last_scale + delta + 256) % 256
        last_scale = last_scale if next_scale == 0 else next_scale


def parse_sps(rbsp: bytes) -> SPS:
    br = BitReader(rbsp)
    sps = SPS()
    sps.profile_idc = br.u(8)
    br.u(8)  # constraint_set flags + reserved
    br.u(8)  # level_idc
    sps.seq_parameter_set_id = br.ue()
    if sps.profile_idc in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        sps.chroma_format_idc = br.ue()
        if sps.chroma_format_idc == 3:
            sps.separate_colour_plane_flag = br.u(1)
        br.ue()  # bit_depth_luma_minus8
        br.ue()  # bit_depth_chroma_minus8
        br.u(1)  # qpprime_y_zero_transform_bypass_flag
        if br.u(1):  # seq_scaling_matrix_present_flag
            count = 12 if sps.chroma_format_idc == 3 else 8
            for i in range(count):
                if br.u(1):
                    _skip_scaling_list(br, 16 if i < 6 else 64)
    sps.log2_max_frame_num_minus4 = br.ue()
    sps.pic_order_cnt_type = br.ue()
    if sps.pic_order_cnt_type == 0:
        sps.log2_max_pic_order_cnt_lsb_minus4 = br.ue()
    elif sps.pic_order_cnt_type == 1:
        sps.delta_pic_order_always_zero_flag = br.u(1)
        br.se()  # offset_for_non_ref_pic
        br.se()  # offset_for_top_to_bottom_field
        n = br.ue()
        for _ in range(n):
            br.se()
    sps.max_num_ref_frames = br.ue()
    br.u(1)  # gaps_in_frame_num_value_allowed_flag
    br.ue()  # pic_width_in_mbs_minus1
    br.ue()  # pic_height_in_map_units_minus1
    sps.frame_mbs_only_flag = br.u(1)
    if not sps.frame_mbs_only_flag:
        sps.mb_adaptive_frame_field_flag = br.u(1)
    br.u(1)  # direct_8x8_inference_flag
    if br.u(1):  # frame_cropping_flag
        br.ue()
        br.ue()
        br.ue()
        br.ue()
    # vui_parameters_present_flag and beyond are not needed for slice-header fields we read
    return sps


def parse_pps(rbsp: bytes) -> PPS:
    br = BitReader(rbsp)
    pps = PPS()
    pps.pic_parameter_set_id = br.ue()
    pps.seq_parameter_set_id = br.ue()
    pps.entropy_coding_mode_flag = br.u(1)
    pps.bottom_field_pic_order_in_frame_present_flag = br.u(1)
    pps.num_slice_groups_minus1 = br.ue()
    if pps.num_slice_groups_minus1 > 0:
        map_type = br.ue()
        if map_type == 0:
            for _ in range(pps.num_slice_groups_minus1 + 1):
                br.ue()
        elif map_type == 2:
            for _ in range(pps.num_slice_groups_minus1):
                br.ue()
                br.ue()
        elif map_type in (3, 4, 5):
            br.u(1)
            br.ue()
        elif map_type == 6:
            pic_size = br.ue()
            bits = 0
            while (1 << bits) < (pps.num_slice_groups_minus1 + 1):
                bits += 1
            for _ in range(pic_size + 1):
                br.u(bits)
    pps.num_ref_idx_l0_default_active_minus1 = br.ue()
    pps.num_ref_idx_l1_default_active_minus1 = br.ue()
    pps.weighted_pred_flag = br.u(1)
    pps.weighted_bipred_idc = br.u(2)
    br.se()  # pic_init_qp_minus26
    br.se()  # pic_init_qs_minus26
    br.se()  # chroma_qp_index_offset
    br.u(1)  # deblocking_filter_control_present_flag
    br.u(1)  # constrained_intra_pred_flag
    pps.redundant_pic_cnt_present_flag = br.u(1)
    return pps


def parse_slice_header(rbsp: bytes, nal_type: int, sps_map: Dict[int, SPS], pps_map: Dict[int, PPS]) -> SliceInfo:
    br = BitReader(rbsp)
    br.ue()  # first_mb_in_slice
    slice_type = br.ue()
    if slice_type > 9:
        raise ValueError(f"slice_type {slice_type} out of range")
    base = slice_type % 5  # 0=P 1=B 2=I 3=SP 4=SI
    pps_id = br.ue()
    if pps_id not in pps_map:
        raise ValueError(f"unknown PPS id {pps_id}")
    pps = pps_map[pps_id]
    if pps.seq_parameter_set_id not in sps_map:
        raise ValueError(f"unknown SPS id {pps.seq_parameter_set_id}")
    sps = sps_map[pps.seq_parameter_set_id]

    if sps.separate_colour_plane_flag:
        br.u(2)  # colour_plane_id

    frame_num_bits = sps.log2_max_frame_num_minus4 + 4
    br.u(frame_num_bits)

    field_pic_flag = 0
    if not sps.frame_mbs_only_flag:
        field_pic_flag = br.u(1)
        if field_pic_flag:
            br.u(1)  # bottom_field_flag

    idr = nal_type == 5
    if idr:
        br.ue()  # idr_pic_id

    if sps.pic_order_cnt_type == 0:
        br.u(sps.log2_max_pic_order_cnt_lsb_minus4 + 4)
        if pps.bottom_field_pic_order_in_frame_present_flag and not field_pic_flag:
            br.se()
    elif sps.pic_order_cnt_type == 1 and not sps.delta_pic_order_always_zero_flag:
        br.se()
        if pps.bottom_field_pic_order_in_frame_present_flag and not field_pic_flag:
            br.se()

    if pps.redundant_pic_cnt_present_flag:
        br.ue()

    if base == 1:  # B
        br.u(1)  # direct_spatial_mv_pred_flag

    num_ref_l0: Optional[int] = None
    if base in (0, 1, 3):  # P, B, SP
        override = br.u(1)
        if override:
            num_ref_l0 = br.ue() + 1
            if base == 1:
                br.ue()  # num_ref_idx_l1_active_minus1
        else:
            num_ref_l0 = pps.num_ref_idx_l0_default_active_minus1 + 1

    return SliceInfo(
        nal_type=nal_type,
        slice_type=slice_type,
        is_p=(base in (0, 3)),  # P or SP
        num_ref_idx_l0_active=num_ref_l0,
    )


@dataclass
class StreamReport:
    max_num_ref_frames: Optional[int] = None
    p_slices: int = 0
    max_active_refs: int = 0
    slices: List[SliceInfo] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)


def analyse(data: bytes) -> StreamReport:
    sps_map: Dict[int, SPS] = {}
    pps_map: Dict[int, PPS] = {}
    report = StreamReport()
    for ntype, rbsp in iter_annex_b_nals(data):
        try:
            if ntype == 7:
                sps = parse_sps(rbsp)
                sps_map[sps.seq_parameter_set_id] = sps
                report.max_num_ref_frames = sps.max_num_ref_frames
            elif ntype == 8:
                pps = parse_pps(rbsp)
                pps_map[pps.pic_parameter_set_id] = pps
            elif ntype in (1, 5):
                info = parse_slice_header(rbsp, ntype, sps_map, pps_map)
                report.slices.append(info)
                if info.is_p and info.num_ref_idx_l0_active is not None:
                    report.p_slices += 1
                    if info.num_ref_idx_l0_active > report.max_active_refs:
                        report.max_active_refs = info.num_ref_idx_l0_active
        except Exception as e:
            report.errors.append(f"NAL type {ntype}: {e}")
    return report


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("file", help="Annex B .h264 bitstream")
    ap.add_argument("--max-refs", type=int, default=1, help="fail if any P slice exceeds this (default 1)")
    ap.add_argument("--allow-no-p", action="store_true", help="do not fail when the stream has no P slices (I-only streams)")
    args = ap.parse_args(argv)

    data = open(args.file, "rb").read()
    report = analyse(data)
    for err in report.errors:
        print(f"parse warning: {err}", file=sys.stderr)

    print(f"SPS max_num_ref_frames: {report.max_num_ref_frames}")
    print(f"P slices: {report.p_slices}")
    print(f"max active refs (P): {report.max_active_refs}")

    bad = [
        s
        for s in report.slices
        if s.is_p and s.num_ref_idx_l0_active is not None and s.num_ref_idx_l0_active > args.max_refs
    ]
    # A pass must mean every slice was read: a header that failed to parse is a slice that was not checked.
    if report.errors:
        print(f"FAIL: {len(report.errors)} NAL unit(s) could not be parsed, so the stream was not fully checked")
        return 1
    if report.p_slices == 0 and not args.allow_no_p:
        print("FAIL: no P slices found, nothing was checked (use --allow-no-p for an I-only stream)")
        return 1
    if bad:
        print(f"FAIL: {len(bad)} P slice(s) exceed --max-refs {args.max_refs}")
        return 1
    print(f"OK: all P slices use at most {args.max_refs} active reference(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
