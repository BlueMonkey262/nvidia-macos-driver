#!/usr/bin/env python3
"""Make libnvenc_hevc_t2d.dylib, the HEVC encoder for Turing, from libnvenc_hevc.dylib.

The default patch redirects the two swizzle LEAs to sw_t2d and clears sign data
hiding in the PPS writer and both engine setup templates. Turing's sign-hiding
payload does not follow the standard coefficient sign ordering. With it disabled,
the baseline passed the 8-bit quality regression on an RTX 2060 Super VM.

Optional --inline-tile, --direct-row and --short-zero speed experiments default
to off. The inline caves retain the indirect call for other swizzle functions.
Direct rows require aligned 8-bit input; padding and 10-bit shifts retain their
staging copy. Short-zero reduces the status clear to 4096 bytes. These optional
patches need their own hardware quality and performance checks.

Refuses any other input library. Sign the output ad hoc on the Mac
(codesign -f -s -); this script does not. The built-in 16384-point offset
comparison checks address arithmetic only; test_hevc_perf_patch.py additionally
executes the new machine code against the original row loops in Unicorn.

usage: make_nvenc_hevc_t2d.py [--inline-tile] [--direct-row] [--short-zero] INPUT OUTPUT
"""
import argparse
import hashlib
import struct

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

# Optional CPU-path experiments, assembled for these file addresses. The library is
# position independent: all new transfers and the swizzle-pointer guard are relative.
# Inline caves preserve every callee-saved register and fall back to the original
# indirect call for a layout other than sw_t2d (notably NVE265_LAYOUT10).
INLINE_CAVES = {
    0xC160: bytes.fromhex(
        "488d056996ffff4939442448752e89f883e020c1e00389fa83e210c1e20201d083e70f01f8"
        "89f283e204c1e20509d0c1e60483e63009f0e98ac8ffff41ff542448e980c8ffff"),
    0xC200: bytes.fromhex(
        "488d05c995ffff49394550752b89f883e020c1e00389fa83e210c1e20201d083e70f01f8"
        "89f283e204c1e20509d0c1e60483e63009f0eb0441ff55504401f0e9aac9ffff"),
}
DIRECT_CAVES = {
    0xC2A0: bytes.fromhex("4183fd0175103b9d48feffff75084d89e7e98dc6ffffe857e9ffffe983c6ffff"),
    0xC2E0: bytes.fromhex("4c8bbde8fdffff4c8b8520feffffe9f4c5ffff"),
    0xC320: bytes.fromhex("4183fd01750d4439f375084d89fce9c1c7ffffe8dae8ffffe9b7c7ffff"),
}
INLINE_HOOKS = {0x8A21: CALL_LUMA_BYTES, 0x8BE7: CALL_CHROMA_BYTES + bytes.fromhex("4401f0")}
DIRECT_HOOKS = {
    0x893E: bytes.fromhex("e8cf220000"),  # luma memmove
    0x88E0: bytes.fromhex("4c8b8520feffff"),  # reload next row, restore staging first
    0x8AEF: bytes.fromhex("e81e210000"),  # chroma memmove
}
SHORT_AT = 0x8FD1
SHORT_OLD = bytes.fromhex("488b35d8520000")
SHORT_NEW = bytes.fromhex("be001000006690")


def _expect(data, at, old):
    if data[at:at + len(old)] != old:
        raise SystemExit(f"unexpected bytes at {at:#x}; optional patch refused")


def _jump(at, target, length):
    return b"\xe9" + struct.pack("<i", target - at - 5) + b"\x90" * (length - 5)


def _caves(data, caves, hooks):
    # Validate everything before writing any hook, including the entire cave range.
    for at, code in caves.items():
        if len(data[at:at + len(code)]) != len(code) or any(data[at:at + len(code)]):
            raise SystemExit(f"code cave at {at:#x} is not empty")
    for at, old in hooks.items():
        _expect(data, at, old)
    for at, code in caves.items():
        data[at:at + len(code)] = code
    for (at, old), target in zip(hooks.items(), caves):
        data[at:at + len(old)] = _jump(at, target, len(old))


def apply_inline_tile(data):
    _caves(data, INLINE_CAVES, INLINE_HOOKS)


def apply_direct_row(data):
    # Both caves require 8-bit samples and visible bytes == aligned row bytes.
    # Padded rows retain memmove + edge fill. The 10-bit shift operates on staging
    # memory in the original code, so it must never receive the caller's source.
    _caves(data, DIRECT_CAVES, DIRECT_HOOKS)


def apply_short_zero(data):
    _expect(data, SHORT_AT, SHORT_OLD)
    _expect(data, SHORT_AT + 7, bytes.fromhex("e8cf1b0000"))
    data[SHORT_AT:SHORT_AT + 7] = SHORT_NEW


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


def patch_buffer(data, check_hash=True, *, inline_tile=False, direct_row=False, short_zero=False):
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
    if inline_tile:
        apply_inline_tile(data)
    if direct_row:
        apply_direct_row(data)
    if short_zero:
        apply_short_zero(data)
    return data, n


def main(src, dst, **flags):
    data, n = patch_buffer(open(src, "rb").read(), **flags)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: 8-bit luma and chroma tiling now call sw_t2d; sign data hiding off (header and both setup templates)")
    print(f"sw_t2d emulation: 0 mismatches in {n} (y=0..63, x step 8, pitch 2048)")
    if any(flags.values()):
        print("optional speed patches: " + ", ".join(k.replace("_", "-") for k, v in flags.items() if v))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inline-tile", action="store_true", help="inline sw_t2d arithmetic, retaining other-layout fallback")
    ap.add_argument("--direct-row", action="store_true", help="skip staging copies for aligned 8-bit rows")
    ap.add_argument("--short-zero", action="store_true", help="clear only the first 4096 status bytes (experimental)")
    ap.add_argument("src")
    ap.add_argument("dst")
    a = ap.parse_args()
    main(a.src, a.dst, inline_tile=a.inline_tile, direct_row=a.direct_row, short_zero=a.short_zero)
