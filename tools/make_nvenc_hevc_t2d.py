#!/usr/bin/env python3
"""Make libnvenc_hevc_t2d.dylib, the HEVC encoder for Turing, from libnvenc_hevc.dylib.

nve265_encode stages a row and then, for each 8-byte chunk, calls the swizzle function pointer stored on the
session. nve265_open points 8-bit luma at sw_bw8 and 8-bit chroma at sw_bw16 (the Blackwell layout). Earlier NVENC
engines read the classic layout, so this tool rewrites only those two LEAs so both pointers are sw_t2d. The calls
themselves stay indirect (41 ff 54 24 48 at 0x8a21, 41 ff 55 50 at 0x8be7); there is no inline loop to replace and
no code cave is written. The >8-bit path reuses the 0x5226 register as its luma default, so 10-bit luma moves to
sw_t2d as well. 10-bit chroma already was sw_t2d. NVE265_LAYOUT10 is left alone.

sw_t2d (0x57d0) returns the intra-gob offset for edi = x & 0x38, esi = y & 7. The caller adds
((x >> 6) + (pitch >> 6) * (y >> 4)) << 10 and ((y & 8) << 6). After patching, that sum is compared with the same
expression evaluated from the register form of sw_t2d, for y = 0..63 and x stepping by 8 across pitch 2048
(16384 points). A mismatch means the two readings of the function disagree; the tool then refuses to look successful.

There is no H.264-style reference clamp here. If a later PSNR run shows P slices advertising more L0 refs than the
SPS buffering, that is a separate edit at 0x8f9a and is not applied by this script.

Refuses any other input library. Sign the output ad hoc on the Mac (codesign -f -s -); this script does not.

The 16384-point compare is emulation only. Nothing here has been run on a GPU.

usage: make_nvenc_hevc_t2d.py <libnvenc_hevc.dylib> <out libnvenc_hevc_t2d.dylib>
"""
import hashlib
import struct
import sys

KNOWN = "aa6b8b2e76bd"  # SHA-256 prefix of the 2.2.0 / 2.3.6 encoder these offsets were read from
SW_T2D = 0x57D0
LEA_RCX, LEA_RAX = 0x5226, 0x52AA          # 8-bit chroma (was sw_bw16) and 8-bit luma (was sw_bw8)
CALL_LUMA, CALL_CHROMA = 0x8A21, 0x8BE7    # call qword [r12+0x48] / call qword [r13+0x50]
CALL_LUMA_BYTES = bytes.fromhex("41ff542448")
CALL_CHROMA_BYTES = bytes.fromhex("41ff5550")
# The straight-line body at SW_T2D, through the ret. Required so a rebuild that moved the function is refused
# even before the point compare.
SW_T2D_BYTES = bytes.fromhex(
    "554889e589f883e0e089f183e104c1e10589fa83e210c1e60483e63083e70f8d04c78d049009c809f05dc3")
# Sign data hiding. Left on, the Turing engine writes the sign bits of a coefficient group after the magnitude codes,
# the opposite of the order H.265 specifies, so any block with detail fails to decode. Two places must agree: the header
# the library writes (nve265_headers sets sign_data_hiding_enabled_flag to 1 with `lea r8d, [r8*2+1]`, the 01 at
# SDH_HEADER) and a setup-template byte, 02 at SDH_I_TEMPLATE for the key-frame setup and at SDH_P_TEMPLATE for the
# inter-frame setup (offset 0x72 of each 0x7e-byte template prefix; bit 1 enables it). With both cleared the engine
# does not hide signs and the stream is the standard one.
SDH_HEADER, SDH_I_TEMPLATE, SDH_P_TEMPLATE = 0x82E5, 0xB062, 0xADD2
SDH_OLD = {SDH_HEADER: 0x01, SDH_I_TEMPLATE: 0x02, SDH_P_TEMPLATE: 0x02}
OLD_RCX = bytes.fromhex("488d0d83050000")  # lea rcx, [rip+0x583] -> 0x57b0 sw_bw16
OLD_RAX = bytes.fromhex("488d05df040000")  # lea rax, [rip+0x4df] -> 0x5790 sw_bw8


def sw_t2d(edi, esi):
    """Intra-gob offset. Arguments are the masked values the call site passes."""
    eax = (edi & ~0x1F) * 8 + (edi & 0xF) + (edi & 0x10) * 4
    return (eax | ((esi & 4) << 5) | ((esi << 4) & 0x30)) & 0xFFFFFFFF


def sw_t2d_regs(edi, esi):
    """The same function, one register write per instruction at 0x57d0."""
    eax = edi & 0xFFFFFFE0
    ecx = (esi & 4) << 5
    edx = edi & 0x10
    esi = (esi << 4) & 0x30
    edi = edi & 0xF
    eax = (edi + eax * 8) & 0xFFFFFFFF
    eax = (eax + edx * 4) & 0xFFFFFFFF
    return (eax | ecx | esi) & 0xFFFFFFFF


def count_mismatches(pitch=2048):
    """Points of (formula, register form) that disagree. 0 of 16384 is the expected result."""
    bad = 0
    n = 0
    for y in range(64):
        row_term = (pitch >> 6) * (y >> 4)
        y_term = (y & 8) << 6
        for x in range(0, pitch, 8):
            gob = ((x >> 6) + row_term) << 10
            formula = gob + sw_t2d(x & 0x38, y & 7) + y_term
            regs = gob + sw_t2d_regs(x & 0x38, y & 7) + y_term
            n += 1
            if formula != regs:
                bad += 1
    return bad, n


def _lea(opcode, at, target):
    return opcode + struct.pack("<i", target - (at + 7))


def rip_target(buf, at):
    return at + 7 + struct.unpack_from("<i", buf, at + 3)[0]


def patch_buffer(data, check_hash=True):
    data = bytearray(data)
    if check_hash and not hashlib.sha256(data).hexdigest().startswith(KNOWN):
        raise SystemExit(f"input is not the known encoder ({KNOWN}...): read the LEAs again before patching")
    if data[LEA_RCX:LEA_RCX + 7] != OLD_RCX:
        raise SystemExit(f"unexpected bytes at {LEA_RCX:#x}: {data[LEA_RCX:LEA_RCX + 7].hex()}")
    if data[LEA_RAX:LEA_RAX + 7] != OLD_RAX:
        raise SystemExit(f"unexpected bytes at {LEA_RAX:#x}: {data[LEA_RAX:LEA_RAX + 7].hex()}")
    if data[CALL_LUMA:CALL_LUMA + len(CALL_LUMA_BYTES)] != CALL_LUMA_BYTES:
        raise SystemExit(f"luma tiling call at {CALL_LUMA:#x} is not indirect; a rebuilt library that inlined it is refused")
    if data[CALL_CHROMA:CALL_CHROMA + len(CALL_CHROMA_BYTES)] != CALL_CHROMA_BYTES:
        raise SystemExit(f"chroma tiling call at {CALL_CHROMA:#x} is not indirect; a rebuilt library that inlined it is refused")
    if data[SW_T2D:SW_T2D + len(SW_T2D_BYTES)] != SW_T2D_BYTES:
        raise SystemExit(f"sw_t2d bytes at {SW_T2D:#x} are not the known function")
    if rip_target(data, LEA_RCX) != 0x57B0 or rip_target(data, LEA_RAX) != 0x5790:
        raise SystemExit("the 8-bit LEAs do not point at sw_bw16 and sw_bw8")
    # Padding a later card run could use. This patch does not need it, and must not write it.
    if any(data[0xC160:0xC170]):
        raise SystemExit("padding at 0xc160 is not empty")
    for off, old in SDH_OLD.items():
        if data[off] != old:
            raise SystemExit(f"sign-data-hiding byte at {off:#x} is {data[off]:#04x}, expected {old:#04x}")
    data[LEA_RCX:LEA_RCX + 7] = _lea(bytes.fromhex("488d0d"), LEA_RCX, SW_T2D)
    data[LEA_RAX:LEA_RAX + 7] = _lea(bytes.fromhex("488d05"), LEA_RAX, SW_T2D)
    for off in SDH_OLD:
        data[off] = 0x00
    if rip_target(data, LEA_RCX) != SW_T2D or rip_target(data, LEA_RAX) != SW_T2D:
        raise SystemExit("patched LEAs do not point at sw_t2d")
    if data[CALL_LUMA:CALL_LUMA + len(CALL_LUMA_BYTES)] != CALL_LUMA_BYTES:
        raise SystemExit("luma call was modified")
    if data[CALL_CHROMA:CALL_CHROMA + len(CALL_CHROMA_BYTES)] != CALL_CHROMA_BYTES:
        raise SystemExit("chroma call was modified")
    bad, n = count_mismatches()
    if bad or n != 16384:
        raise SystemExit(f"sw_t2d emulation: {bad} mismatches in {n}")
    return data, n


def main(src, dst):
    data, n = patch_buffer(open(src, "rb").read())
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: 8-bit luma and chroma tiling now call sw_t2d; sign data hiding off (header and both setup templates)")
    print(f"sw_t2d emulation: 0 mismatches in {n} (y=0..63, x step 8, pitch 2048)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
