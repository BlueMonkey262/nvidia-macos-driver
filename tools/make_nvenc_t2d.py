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

Optional --low-bar (off unless named): after buf_alloc's zero-fill, unmap the CPU/BAR1 window of every flag-0
buffer except the 512 KB USERD slot and clear that descriptor's CPU-pointer fields so teardown does not unmap
them again. Flag-1 buffers and USERD stay mapped. The new instructions (LOW_BAR_ASM, embedded as bytes) go into the
padding at 0x9ee0; with objdump on PATH they are checked before they are written.

usage: make_nvenc_t2d.py [--keep-multi-ref] [--low-bar] <libnvenc_h264.dylib> <out libnvenc_h264_t2d.dylib>
"""
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

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


# --low-bar. buf_alloc (0x3770) zero-fills through the CPU mapping, then builds the GPU VA.
# The call at LOW_BAR_HOOK is `call bzero` (stub 0x8312). Replaced with a jmp into FREE_AT.
LOW_BAR_HOOK = 0x3939
LOW_BAR_BACK = 0x393E          # xorps xmm0,xmm0, the instruction after the bzero call
LOW_BAR_FAIL = 0x3AA3          # buf_alloc epilogue: return r15d
BZERO, UNMAP = 0x8312, 0x73E0  # _bzero stub, _nvRmApiUnmapMemory
USERD, HSUB, RM = 0xB0D8, 0xB494, 0xB430
FREE_AT, FREE_END = 0x9EE0, 0xA000
CALL_BZERO = bytes.fromhex("e8d4490000")

# r15d is still the flag (0 = BAR1, nonzero = sysmem). rbx is the descriptor. r14 is the
# rounded size. All three are callee-saved, so bzero and nvRmApiUnmapMemory preserve them.
# On entry rsp is buf_alloc's 16-byte-aligned frame (the hook is a jmp, not a call).
LOW_BAR_ASM = """
.intel_syntax noprefix
.section .text
.globl cave
cave:
    call 0x8312
    test r15d, r15d
    jnz back
    lea rax, [rip + userd]
    cmp rbx, rax
    je back
    lea r8, [rbx + 0x20]
    mov edx, dword ptr [rbx]
    mov esi, dword ptr [rip + hsub]
    lea rdi, [rip + rmbase]
    xor ecx, ecx
    call 0x73e0
    test eax, eax
    jnz fail
    xor eax, eax
    mov qword ptr [rbx + 0x8], rax
    mov qword ptr [rbx + 0x28], rax
    mov qword ptr [rbx + 0x20], rax
    mov qword ptr [rbx + 0x30], rax
back:
    jmp 0x393e
fail:
    mov r15d, 0xffffffff
    jmp 0x3aa3
"""

# The cave as GNU as assembles LOW_BAR_ASM at 0x9ee0 (86 bytes), embedded so that patching needs no toolchain.
# tools/test_low_bar_patch.py locks these bytes and, where objdump exists, checks that every transfer lands correctly.
LOW_BAR_CAVE = bytes.fromhex(
    "e82de4ffff4585ff753c488d05e71100004839c374304c8d43208b138b3592150000488d3d27150000"
    "31c9e8d0d4ffff85c0751731c048894308488943284889432048894330e9139affff41bfffffffff"
    "e96d9bffff")


_INSN = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]*?)\t(\S+)\s*(.*?)\s*$")


def disassemble(blob, vma, start=None, stop=None):
    """objdump -D of raw bytes placed at `vma`. Returns ([(addr, raw, mnemonic, ops)], text)."""
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "blob.bin")
        with open(path, "wb") as f:
            f.write(blob)
        cmd = ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
               f"--adjust-vma={vma:#x}", path]
        if start is not None:
            cmd.append(f"--start-address={start:#x}")
        if stop is not None:
            cmd.append(f"--stop-address={stop:#x}")
        out = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if out.returncode != 0:
            raise SystemExit(f"objdump failed: {out.stderr.strip()}")
    rows = []
    for line in out.stdout.splitlines():
        m = _INSN.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        raw = bytes.fromhex(m.group(2))
        rows.append((addr, raw, m.group(3), m.group(4)))
    return rows, out.stdout


def _abs_target(ops):
    m = re.search(r"(0x[0-9a-f]+)\s*$", ops)
    return int(m.group(1), 16) if m else None


def verify_low_bar_cave(code):
    """With objdump on PATH: refuse the cave unless it decodes and every control transfer lands where it must. Returns
    the listing, or None when objdump is not available (the bytes are still locked by tools/test_low_bar_patch.py)."""
    if not code or len(code) > FREE_END - FREE_AT:
        raise SystemExit(f"low-bar cave is {len(code)} bytes; padding is {FREE_END - FREE_AT}")
    if not shutil.which("objdump"):
        return None
    rows, text = disassemble(code, FREE_AT)
    if any(m == "(bad)" or m == "" for _, _, m, _ in rows):
        raise SystemExit("low-bar cave did not decode:\n" + text)
    transfers = []
    for addr, _, mnem, ops in rows:
        tgt = _abs_target(ops)
        if mnem in ("call", "jmp", "je", "jne", "jz", "jnz") or mnem.startswith("j"):
            if tgt is None:
                raise SystemExit(f"no target on {mnem} at {addr:#x}")
            transfers.append((addr, mnem, tgt))
        if mnem == "lea" and "rax" in ops:
            if tgt != USERD:
                raise SystemExit(f"USERD lea at {addr:#x} -> {tgt:#x}")
        if mnem == "mov" and ops.startswith("esi"):
            if tgt != HSUB:
                raise SystemExit(f"hSubdev load at {addr:#x} -> {tgt:#x}")
        if mnem == "lea" and "rdi" in ops:
            if tgt != RM:
                raise SystemExit(f"rm lea at {addr:#x} -> {tgt:#x}")
    got = {(m, t) for _, m, t in transfers}
    for mnem, tgt in (("call", BZERO), ("call", UNMAP), ("jmp", LOW_BAR_BACK), ("jmp", LOW_BAR_FAIL)):
        if (mnem, tgt) not in got:
            raise SystemExit(f"cave missing {mnem} {tgt:#x}:\n" + text)
    # both conditional skips must land on the jmp back, and the unmap-failed branch on `mov r15d`
    back = next(addr for addr, mnem, tgt in transfers if mnem == "jmp" and tgt == LOW_BAR_BACK)
    fail = next(addr for addr, _, mnem, ops in rows if mnem == "mov" and "r15d" in ops)
    for addr, mnem, tgt in transfers:
        if mnem in ("jne", "je", "jz", "jnz"):
            if tgt not in (back, fail):
                raise SystemExit(f"{mnem} at {addr:#x} -> {tgt:#x}, not back or fail")
    covered = b"".join(raw for _, raw, _, _ in rows)
    if covered != code:
        raise SystemExit("objdump did not cover every cave byte")
    return text


def apply_low_bar(data):
    """Jmp from the bzero call to the cave. `data` is the library image (file offset == address)."""
    code = LOW_BAR_CAVE
    text = verify_low_bar_cave(code)
    if len(data) < FREE_END:
        raise SystemExit(f"image is {len(data)} bytes; the cave goes at {FREE_AT:#x}-{FREE_END:#x}")
    if data[LOW_BAR_HOOK:LOW_BAR_HOOK + len(CALL_BZERO)] != CALL_BZERO:
        raise SystemExit(f"unexpected bytes at {LOW_BAR_HOOK:#x}: "
                         f"{data[LOW_BAR_HOOK:LOW_BAR_HOOK + 5].hex()} (wanted {CALL_BZERO.hex()})")
    if any(data[FREE_AT:FREE_END]):
        raise SystemExit(f"padding {FREE_AT:#x}-{FREE_END:#x} is not empty")
    data[LOW_BAR_HOOK:LOW_BAR_HOOK + 5] = b"\xe9" + struct.pack("<i", FREE_AT - (LOW_BAR_HOOK + 5))
    data[FREE_AT:FREE_AT + len(code)] = code
    return text


def patch(data, single_ref=True, low_bar=False):
    """Apply the t2d loops, the single-reference clamps, and (if asked) the BAR1 unmap."""
    if not hashlib.sha256(data).hexdigest().startswith(KNOWN):
        raise SystemExit(f"not the known encoder ({KNOWN}...): read the loops again before patching")
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
    listing = None
    if low_bar:
        listing = apply_low_bar(data)
    return listing


def main(src, dst, single_ref=True, low_bar=False):
    data = bytearray(open(src, "rb").read())
    listing = patch(data, single_ref=single_ref, low_bar=low_bar)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: luma and chroma tiling loops now write the t2d / block height 2 layout"
          + ("; P-frames use one reference frame" if single_ref else "; P-frames keep up to three references")
          + ("; flag-0 BAR1 windows dropped after zero-fill (USERD kept)" if low_bar else ""))
    if listing:
        hook, _ = disassemble(data[LOW_BAR_HOOK:LOW_BAR_HOOK + 8], LOW_BAR_HOOK)
        print(f"\npatched buf_alloc {LOW_BAR_HOOK:#x}:")
        for addr, raw, mnem, ops in hook:
            print(f"  {addr:#x}: {raw.hex():24} {mnem} {ops}".rstrip())
        print(f"\ncave {FREE_AT:#x}:")
        for line in listing.splitlines():
            if _INSN.match(line):
                print(line.rstrip())


if __name__ == "__main__":
    flags = {"--keep-multi-ref", "--low-bar"}
    args = [a for a in sys.argv[1:] if a not in flags]
    if len(args) != 2 or any(a.startswith("-") and a not in flags for a in sys.argv[1:]):
        raise SystemExit(__doc__)
    main(args[0], args[1],
         single_ref="--keep-multi-ref" not in sys.argv,
         low_bar="--low-bar" in sys.argv)
