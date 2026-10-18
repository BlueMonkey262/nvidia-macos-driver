#!/usr/bin/env python3
"""Make libnvenc_h264_t2d.dylib, the H.264 encoder for GPUs before Blackwell, from libnvenc_h264.dylib (package 2.2.0).

nve264_encode copies each frame row into the NVENC input surface with the tiling written inline: a luma loop for
the Blackwell bw8 layout and a chroma loop for bw16. Earlier NVENC engines read the classic layout (t2d, block height
2), so a Blackwell-tiled frame comes out as a torn picture (issue #65: 17-28 dB on an RTX 3070 Laptop). The library has
no source here and no mode switch, so this tool replaces the first 5 bytes of each loop with a jmp to a replacement
loop placed in the zero padding at the end of __TEXT. The replacement computes (x = byte offset in the row, y = row):
    off = ((y&3)<<4) | ((y&4)<<5) | ((y&8)<<6) | ((x&0x10)<<2) | ((x&0x20)<<3) | (x&15)
          + (((x>>6) + (pitch>>6) * (y>>4)) << 10)
which is what the library's own sw_t2d (0x6f70) / tile_off compute for layout {mode 0, block height 2}. It copies 16
bytes per step, so the width of a row must be a multiple of 16 (the unpatched chroma loop already assumed that).

Verified by emulation only (17 sample rows, 1920 wide, pitch 2048: old loops equal the library's own bw8/bw16, new
loops equal its sw_t2d); see docs/H264.md for what has been run on a card.

Second change, on by default (--keep-multi-ref turns it off): single-reference P-frames. The library codes each P-frame
with min(frames since the last IDR, 3) reference frames and builds the engine's reference list from that count in two
places in nve264_encode (0x689a: the setup struct, 0x6c7b: the method stream that points the engine at each reference
picture), plus a flag set from "frames since IDR < 3" (0x69c0). Moonlight rewrites every SPS to one reference frame and
decodes with AV_EF_EXPLODE, so a P-frame with two or three references fails with "Missing reference picture" and the
client requests an IDR in a loop. The count is clamped to 1 in both places and the flag forced to 1, which is exactly
what the library does for the first P-frame after an IDR; the engine writes the slice headers itself from the same setup
(num_ref_idx_active_override with one reference), so the headers follow.
Refuses any other input library, so a rebuilt encoder cannot be patched blindly. Sign the output ad hoc after.

usage: make_nvenc_t2d.py [--keep-multi-ref] <libnvenc_h264.dylib> <out libnvenc_h264_t2d.dylib>
"""
import hashlib
import struct
import sys

KNOWN = "c78e21aae60f"      # SHA-256 prefix of the 2.2.0 encoder these offsets were read from
LUMA, CHROMA = 0x63AA, 0x64D9           # start of the luma / chroma tiling code for one row (mov eax,r12d; shr eax,4)
CAVE_L, CAVE_C = 0x9DA0, 0x9E40         # zero padding at the end of __TEXT
HOOK = bytes.fromhex("4489e0c1e804")    # what both loops start with

# Replacement loops (x86-64). Luma: row source r14, state r15, destination rbx, width r9. Chroma: state r9,
# destination r10, width rbx. Both start from the row number in r12d and end with a jmp back to the row loop.
LUMA_CAVE = bytes.fromhex(
    "4489e0c1e8044489e183e108c1e1064489e283e203c1e20409d14489e283e204c1e20509d131f6418b7f10c1ef06"
    "0faff84189f041c1e8064101f841c1e00a89f783e73089fa83e22001d7c1e70209cf4409c7410f1004360f11043b"
    "4883c6104c39ce7cc2e926c5ffff")
CHROMA_CAVE = bytes.fromhex(
    "4489e0c1e8044489e183e108c1e1064489e283e203c1e20409d14489e283e204c1e20509d131f6418b7910c1ef06"
    "0faff84189f041c1e8064101f841c1e00a89f783e73089fa83e22001d7c1e70209cf4409c7410f100436410f1104"
    "3a4883c6104839de7cc1e9a5c5ffff")


# (address, expected bytes, replacement bytes), all inside nve264_encode
SINGLE_REF = [
    (0x689A, "4183fd03", "4183fd01"),                    # cmp r13d,3 -> 1          (setup struct: min(frames since IDR, 3))
    (0x689E, "ba03000000", "ba01000000"),                # mov edx,3 -> 1
    (0x69BE, "31c04183fd030f9cc0", "b801000000" + "90" * 4),   # xor eax,eax; cmp r13d,3; setl al -> mov eax,1; nops
    (0x6C7B, "4183fd03", "4183fd01"),                    # cmp r13d,3 -> 1          (method stream: reference pictures)
    (0x6C7F, "ba03000000", "ba01000000"),                # mov edx,3 -> 1
]


def main(src, dst, single_ref=True):
    data = bytearray(open(src, "rb").read())
    if not hashlib.sha256(data).hexdigest().startswith(KNOWN):
        raise SystemExit(f"{src} is not the known encoder ({KNOWN}...): read the loops again before patching")
    for hook in (LUMA, CHROMA):
        if data[hook:hook + len(HOOK)] != HOOK:
            raise SystemExit(f"unexpected bytes at {hook:#x}: {data[hook:hook + 6].hex()}")
    for cave, code in ((CAVE_L, LUMA_CAVE), (CAVE_C, CHROMA_CAVE)):
        if any(data[cave:cave + 0xA0]):
            raise SystemExit(f"code cave at {cave:#x} is not empty")
        data[cave:cave + len(code)] = code
    for hook, cave in ((LUMA, CAVE_L), (CHROMA, CAVE_C)):
        data[hook:hook + 5] = b"\xe9" + struct.pack("<i", cave - (hook + 5))
    if single_ref:
        for addr, old, new in SINGLE_REF:
            if data[addr:addr + len(old) // 2] != bytes.fromhex(old):
                raise SystemExit(f"unexpected bytes at {addr:#x}: {data[addr:addr + len(old) // 2].hex()} (wanted {old})")
            data[addr:addr + len(new) // 2] = bytes.fromhex(new)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: luma and chroma tiling loops now write the t2d / block height 2 layout"
          + ("; P-frames use one reference frame" if single_ref else "; P-frames keep up to three references"))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--keep-multi-ref"]
    if len(args) != 2:
        raise SystemExit(__doc__)
    main(args[0], args[1], single_ref="--keep-multi-ref" not in sys.argv)
