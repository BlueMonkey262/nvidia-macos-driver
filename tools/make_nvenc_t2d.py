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
Refuses any other input library, so a rebuilt encoder cannot be patched blindly. Sign the output ad hoc after.

usage: make_nvenc_t2d.py <libnvenc_h264.dylib> <out libnvenc_h264_t2d.dylib>
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


def main(src, dst):
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
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: luma and chroma tiling loops now write the t2d / block height 2 layout")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
