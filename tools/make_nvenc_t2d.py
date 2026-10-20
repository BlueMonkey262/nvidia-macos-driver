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
padding at 0x9ee0. A built-in decoder checks every transfer before the bytes are written, and capstone repeats that check when it is installed.

Optional --direct-row (off unless named): skip the per-row memcpy into the staging buffer when the edge pad
length is zero (width a multiple of 16). The t2d loops then read the source row directly. Rows that still need
padding keep the original memcpy + edge fill. Hooks replace the memcpy calls and the row-loop heads; caves sit
in the padding after the t2d loops and (when --low-bar is also used) after the low-bar cave. Apply --low-bar in
the same run when both are wanted: a later --low-bar refuses padding that is no longer empty.

Optional --short-zero (off unless named): the status-buffer bzero every frame uses a 4096-byte length instead of
the full 6.88 MB mapping. The CPU only reads the status header after the wait; a too-short clear would show up as
a channel error or a bad picture, not a silently good stream.

usage: make_nvenc_t2d.py [--keep-multi-ref] [--low-bar] [--direct-row] [--short-zero]
                         <libnvenc_h264.dylib> <out libnvenc_h264_t2d.dylib>
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
# tools/test_low_bar_patch.py locks these bytes and checks that every transfer lands correctly.
LOW_BAR_CAVE = bytes.fromhex(
    "e82de4ffff4585ff753c488d05e71100004839c374304c8d43208b138b3592150000488d3d27150000"
    "31c9e8d0d4ffff85c0751731c048894308488943284889432048894330e9139affff41bfffffffff"
    "e96d9bffff")


# --direct-row. Pad length is [rbp-0x308] == (mb_w*16 - width). Zero pad tiles from the source row;
# otherwise the original memcpy + edge fill runs. Both paths stash the staging pointer at [rbp-0x330]
# (rsp after the frame setup); the row-loop heads restore it before the next iteration.
LUMA_CALL, CHROMA_CALL = 0x6375, 0x648F
LUMA_RESUME, CHROMA_RESUME = 0x6330, 0x6450
LUMA_TILE, CHROMA_TILE = 0x639A, 0x64BE       # t2d entry (or original loop) after a direct skip
LUMA_AFTER_COPY, CHROMA_AFTER_COPY = 0x637A, 0x6494
LUMA_RESUME_CONT, CHROMA_RESUME_CONT = 0x6337, 0x6457
MEMCPY = 0x8372
LUMA_CALL_OLD = bytes.fromhex("e8f81f0000")    # call memcpy
CHROMA_CALL_OLD = bytes.fromhex("e8de1e0000")
RESUME_OLD = bytes.fromhex("41ffc4418b")      # inc r12d; start of mov eax, ...
# The four caves below sit at 0x9e0a / 0x9eab / 0x9f36 / 0x9f49.
# tools/test_h264_perf_patch.py decodes them again and checks every jump lands on an instruction start.
#   luma   0x9e0a: mov [rbp-0x330],r14 ; cmp qword [rbp-0x308],0 ; jne +copy ; mov r14,r15 ;
#                  mov r15,[rbp-0x2b8] ; jmp 0x639a (t2d entry)        +copy: call memcpy(0x8372) ; jmp 0x637a
#   chroma 0x9eab: mov [rbp-0x330],r14 ; cmp qword [rbp-0x308],0 ; jne +copy ; mov r14,r15 ;
#                  jmp 0x64be (t2d entry)                               +copy: call memcpy(0x8372) ; jmp 0x6494
#   luma restore   0x9f36: mov r14,[rbp-0x330] ; inc r12d ; mov eax,[r15+0xc] ; jmp 0x6337
#   chroma restore 0x9f49: mov r14,[rbp-0x330] ; inc r12d ; mov eax,[r9+0xc]  ; jmp 0x6457
LUMA_DIRECT = bytes.fromhex(
    "4c89b5d0fcffff4883bdf8fcffff00750f4d89fe4c8bbd48fdffffe970c5ffffe843e5ffffe946c5ffff")
CHROMA_DIRECT = bytes.fromhex(
    "4c89b5d0fcffff4883bdf8fcffff0075084d89fee9fac5ffffe8a9e4ffffe9c6c5ffff")
LUMA_RESTORE = bytes.fromhex("4c8bb5d0fcffff41ffc4418b470ce9eec3ffff")
CHROMA_RESTORE = bytes.fromhex("4c8bb5d0fcffff41ffc4418b410ce9fbc4ffff")
DIRECT_AT = (0x9E0A, 0x9EAB, 0x9F36, 0x9F49)  # luma, chroma, luma restore, chroma restore
DIRECT_BLOBS = (LUMA_DIRECT, CHROMA_DIRECT, LUMA_RESTORE, CHROMA_RESTORE)

# --short-zero. Same length as the load of the rounded status-buffer size (6,881,280).
SHORT_AT = 0x6A07
SHORT_OLD = bytes.fromhex("488b35a2480000")   # mov rsi, [rip+0xb2b0]
SHORT_NEW = bytes.fromhex("be001000006690")   # mov esi, 0x1000; nop


class Insn:
    """One decoded instruction. `target` is the absolute address of a branch or a RIP-relative memory operand."""

    def __init__(self, addr, raw, mnem, ops, dst, target):
        self.addr = addr
        self.raw = raw
        self.mnem = mnem
        self.ops = ops
        self.dst = dst
        self.target = target


_G32 = ("eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
        "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d")
_G64 = ("rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15")
_JCC8 = ("jo", "jno", "jb", "jae", "je", "jne", "jbe", "ja",
         "js", "jns", "jp", "jnp", "jl", "jge", "jle", "jg")
# Group 1 (opcode 83): the ModRM reg field is the operation, not a register.
_GRP1 = ("add", "or", "adc", "sbb", "and", "sub", "xor", "cmp")


def _gpr(idx, bits):
    return (_G64 if bits == 64 else _G32)[idx]


def _cut(blob, i, n, addr):
    if n < 0 or i < 0 or i + n > len(blob):
        raise SystemExit(f"truncated instruction at {addr:#x}")
    return blob[i:i + n]


def _modrm(blob, i, rex, addr):
    """Return (new index, reg, ext, kind, disp). kind is ('reg', idx), ('rip', None) or ('mem', base)."""
    modrm = _cut(blob, i, 1, addr)[0]
    i += 1
    mod = modrm >> 6
    ext = (modrm >> 3) & 7
    reg = ext | (8 if rex & 0x4 else 0)
    rm = modrm & 7
    if mod == 3:
        return i, reg, ext, ("reg", rm | (8 if rex & 0x1 else 0)), 0
    if rm == 4:
        raise SystemExit(f"cannot decode SIB at {addr:#x}")
    if mod == 0 and rm == 5:
        disp = struct.unpack_from("<i", _cut(blob, i, 4, addr))[0]
        return i + 4, reg, ext, ("rip", None), disp
    base = rm | (8 if rex & 0x1 else 0)
    if mod == 1:
        disp = struct.unpack_from("<b", _cut(blob, i, 1, addr))[0]
        i += 1
    elif mod == 2:
        disp = struct.unpack_from("<i", _cut(blob, i, 4, addr))[0]
        i += 4
    else:
        disp = 0
    return i, reg, ext, ("mem", base), disp


def _mem(kind, disp, bits):
    if kind[0] == "rip":
        sign = "+" if disp >= 0 else "-"
        inner = f"rip {sign} {abs(disp):#x}"
    else:
        base = _gpr(kind[1], 64)
        if disp == 0:
            inner = base
        else:
            sign = "+" if disp >= 0 else "-"
            inner = f"{base} {sign} {abs(disp):#x}"
    if bits is None:
        return f"[{inner}]"
    width = "qword" if bits == 64 else "dword"
    return f"{width} ptr [{inner}]"


def _insn(blob, start, end, base, mnem, ops, dst, target):
    return Insn(base + start, bytes(blob[start:end]), mnem, ops, dst, target), end


def _decode_one(blob, i, base):
    """Decode one instruction of a form used by the low-bar and direct-row caves."""
    addr = base + i
    start = i
    rex = 0
    if i < len(blob) and 0x40 <= blob[i] <= 0x4F:
        rex = blob[i]
        i += 1
    if i >= len(blob):
        raise SystemExit(f"truncated instruction at {addr:#x}")
    op = blob[i]
    i += 1
    bits = 64 if rex & 0x8 else 32

    if op in (0xE8, 0xE9):
        disp = struct.unpack_from("<i", _cut(blob, i, 4, addr))[0]
        i += 4
        mnem = "call" if op == 0xE8 else "jmp"
        target = base + i + disp
        return _insn(blob, start, i, base, mnem, f"{target:#x}", None, target)
    if 0x70 <= op <= 0x7F:
        disp = struct.unpack_from("<b", _cut(blob, i, 1, addr))[0]
        i += 1
        mnem = _JCC8[op - 0x70]
        target = base + i + disp
        return _insn(blob, start, i, base, mnem, f"{target:#x}", None, target)
    if 0xB8 <= op <= 0xBF:
        rd = (op - 0xB8) | (8 if rex & 1 else 0)
        if rex & 0x8:
            imm = struct.unpack_from("<Q", _cut(blob, i, 8, addr))[0]
            i += 8
            bits = 64
        else:
            imm = struct.unpack_from("<I", _cut(blob, i, 4, addr))[0]
            i += 4
        dst = _gpr(rd, bits)
        text = f"{imm:#x}" if imm > 9 else str(imm)
        return _insn(blob, start, i, base, "mov", f"{dst}, {text}", dst, None)

    if op not in (0x89, 0x8B, 0x8D, 0x85, 0x39, 0x31, 0x83, 0xFF):
        raise SystemExit(f"cannot decode {op:#x} at {addr:#x}")
    i, reg, ext, kind, disp = _modrm(blob, i, rex, addr)
    rip = (base + i + disp) if kind[0] == "rip" else None

    if op == 0xFF:
        if ext != 0 or kind[0] != "reg":
            raise SystemExit(f"cannot decode opcode ff at {addr:#x}")
        dst = _gpr(kind[1], bits)
        return _insn(blob, start, i, base, "inc", dst, dst, None)
    if op == 0x83:
        imm = struct.unpack_from("<b", _cut(blob, i, 1, addr))[0]
        i += 1
        if kind[0] == "rip":
            rip = base + i + disp
        mnem = _GRP1[ext]
        if kind[0] == "reg":
            ops = f"{_gpr(kind[1], bits)}, {imm}"
        else:
            ops = f"{_mem(kind, disp, bits)}, {imm}"
        return _insn(blob, start, i, base, mnem, ops, None, rip)
    if op == 0x8D:
        dst = _gpr(reg, bits)
        if kind[0] == "reg":
            raise SystemExit(f"lea with a register source at {addr:#x}")
        return _insn(blob, start, i, base, "lea", f"{dst}, {_mem(kind, disp, None)}", dst, rip)
    if op == 0x8B:
        dst = _gpr(reg, bits)
        if kind[0] == "reg":
            return _insn(blob, start, i, base, "mov", f"{dst}, {_gpr(kind[1], bits)}", dst, None)
        return _insn(blob, start, i, base, "mov", f"{dst}, {_mem(kind, disp, bits)}", dst, rip)

    # 89, 85, 39, 31: r/m, r
    src = _gpr(reg, bits)
    mnem = {0x89: "mov", 0x85: "test", 0x39: "cmp", 0x31: "xor"}[op]
    if kind[0] == "reg":
        dst = _gpr(kind[1], bits)
        # A register destination matters for `mov r15d, imm` only; that is opcode B8.
        reg_dst = dst if op == 0x89 else None
        return _insn(blob, start, i, base, mnem, f"{dst}, {src}", reg_dst, None)
    return _insn(blob, start, i, base, mnem, f"{_mem(kind, disp, bits)}, {src}", None, rip)


def decode(blob, vma):
    """Decode every byte of a cave. Stdlib only; raises SystemExit on a form these caves do not use."""
    rows = []
    i = 0
    while i < len(blob):
        insn, i = _decode_one(blob, i, vma)
        rows.append(insn)
    return rows


def _format(rows):
    return "\n".join(
        f"  {r.addr:#x}: {r.raw.hex():24} {r.mnem} {r.ops}".rstrip() for r in rows)


def _capstone_target(insn, imm_type, mem_type, rip_reg):
    if insn.mnemonic.startswith("j") or insn.mnemonic == "call":
        for operand in insn.operands:
            if operand.type == imm_type:
                return operand.imm
    for operand in insn.operands:
        if operand.type == mem_type and operand.mem.base == rip_reg:
            return insn.address + insn.size + operand.mem.disp
    return None


def _capstone_agrees(blob, vma, rows):
    """When capstone is installed, require the same boundaries and the same branch / RIP targets."""
    try:
        from capstone import Cs, CS_ARCH_X86, CS_MODE_64
        from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP
    except ImportError:
        return
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    theirs = list(md.disasm(bytes(blob), vma))
    if len(theirs) != len(rows) or sum(item.size for item in theirs) != len(blob):
        raise SystemExit(f"capstone did not match the built-in decode of the cave at {vma:#x}")
    for got, exp in zip(theirs, rows):
        if got.address != exp.addr or got.size != len(exp.raw):
            raise SystemExit(
                f"capstone boundary {got.address:#x} disagrees with the built-in decoder at {exp.addr:#x}")
        tgt = _capstone_target(got, X86_OP_IMM, X86_OP_MEM, X86_REG_RIP)
        if tgt != exp.target:
            raise SystemExit(
                f"target at {exp.addr:#x}: built-in {exp.target}, capstone {tgt} ({got.mnemonic} {got.op_str})")


def _transfers(rows):
    found = []
    for insn in rows:
        if insn.mnem.startswith("j") or insn.mnem == "call":
            if insn.target is None:
                raise SystemExit(f"no target on {insn.mnem} at {insn.addr:#x}")
            found.append((insn.addr, insn.mnem, insn.target))
    return found


def verify_low_bar_cave(code):
    """Refuse the cave unless it decodes and every control transfer lands where it must. Returns the listing."""
    if not code or len(code) > FREE_END - FREE_AT:
        raise SystemExit(f"low-bar cave is {len(code)} bytes; padding is {FREE_END - FREE_AT}")
    rows = decode(code, FREE_AT)
    _capstone_agrees(code, FREE_AT, rows)
    transfers = _transfers(rows)
    for insn in rows:
        if insn.mnem == "lea" and insn.dst == "rax" and insn.target != USERD:
            raise SystemExit(f"USERD lea at {insn.addr:#x} -> {insn.target:#x}")
        if insn.mnem == "mov" and insn.dst == "esi" and insn.target != HSUB:
            raise SystemExit(f"hSubdev load at {insn.addr:#x} -> {insn.target:#x}")
        if insn.mnem == "lea" and insn.dst == "rdi" and insn.target != RM:
            raise SystemExit(f"rm lea at {insn.addr:#x} -> {insn.target:#x}")
    got = {(mnem, tgt) for _, mnem, tgt in transfers}
    for mnem, tgt in (("call", BZERO), ("call", UNMAP), ("jmp", LOW_BAR_BACK), ("jmp", LOW_BAR_FAIL)):
        if (mnem, tgt) not in got:
            raise SystemExit(f"cave missing {mnem} {tgt:#x}:\n" + _format(rows))
    # both conditional skips must land on the jmp back, and the unmap-failed branch on `mov r15d`
    back = next(addr for addr, mnem, tgt in transfers if mnem == "jmp" and tgt == LOW_BAR_BACK)
    fails = [insn.addr for insn in rows if insn.mnem == "mov" and insn.dst == "r15d"]
    if len(fails) != 1:
        raise SystemExit("low-bar cave has no single mov r15d fail path")
    fail = fails[0]
    for addr, mnem, tgt in transfers:
        if mnem in ("jne", "je", "jz", "jnz") and tgt not in (back, fail):
            raise SystemExit(f"{mnem} at {addr:#x} -> {tgt:#x}, not back or fail")
    covered = b"".join(insn.raw for insn in rows)
    if covered != code:
        raise SystemExit("decoder did not cover every low-bar cave byte")
    return _format(rows)


def _assert_cave_bounds():
    """Each cave must end at or before the next fixed address. There is no spare byte today."""
    checks = (
        ("LUMA_CAVE", CAVE_L, LUMA_CAVE, DIRECT_AT[0]),
        ("CHROMA_CAVE", CAVE_C, CHROMA_CAVE, DIRECT_AT[1]),
        ("LOW_BAR_CAVE", FREE_AT, LOW_BAR_CAVE, DIRECT_AT[2]),
    )
    for name, start, blob, limit in checks:
        end = start + len(blob)
        if end > limit:
            raise SystemExit(
                f"{name} at {start:#x} is {len(blob)} bytes and ends at {end:#x}, "
                f"past the next fixed address {limit:#x}")


def apply_low_bar(data):
    """Jmp from the bzero call to the cave. `data` is the library image (file offset == address)."""
    _assert_cave_bounds()
    code = LOW_BAR_CAVE
    cave = verify_low_bar_cave(code)
    if len(data) < FREE_END:
        raise SystemExit(f"image is {len(data)} bytes; the cave goes at {FREE_AT:#x}-{FREE_END:#x}")
    if data[LOW_BAR_HOOK:LOW_BAR_HOOK + len(CALL_BZERO)] != CALL_BZERO:
        raise SystemExit(f"unexpected bytes at {LOW_BAR_HOOK:#x}: "
                         f"{data[LOW_BAR_HOOK:LOW_BAR_HOOK + 5].hex()} (wanted {CALL_BZERO.hex()})")
    if any(data[FREE_AT:FREE_END]):
        raise SystemExit(f"padding {FREE_AT:#x}-{FREE_END:#x} is not empty")
    hook = b"\xe9" + struct.pack("<i", FREE_AT - (LOW_BAR_HOOK + 5))
    # Decode before the image is published, so a listing failure cannot follow a successful write.
    hook_text = _format(decode(hook, LOW_BAR_HOOK))
    data[LOW_BAR_HOOK:LOW_BAR_HOOK + 5] = hook
    data[FREE_AT:FREE_AT + len(code)] = code
    return hook_text, cave


def _jmp(at, target):
    return b"\xe9" + struct.pack("<i", target - (at + 5))


def _need(data, at, old, what):
    got = bytes(data[at:at + len(old)])
    if got != old:
        raise SystemExit(f"unexpected bytes at {at:#x} ({what}): {got.hex()} wanted {old.hex()}")


def verify_direct_row_caves():
    """Refuse the caves unless they decode and every transfer lands where it must."""
    listings = []
    expected = {
        DIRECT_AT[0]: (("jne", None), ("jmp", LUMA_TILE), ("call", MEMCPY), ("jmp", LUMA_AFTER_COPY)),
        DIRECT_AT[1]: (("jne", None), ("jmp", CHROMA_TILE), ("call", MEMCPY), ("jmp", CHROMA_AFTER_COPY)),
        DIRECT_AT[2]: (("jmp", LUMA_RESUME_CONT),),
        DIRECT_AT[3]: (("jmp", CHROMA_RESUME_CONT),),
    }
    for at, blob in zip(DIRECT_AT, DIRECT_BLOBS):
        rows = decode(blob, at)
        _capstone_agrees(blob, at, rows)
        text = _format(rows)
        covered = b"".join(insn.raw for insn in rows)
        if covered != blob:
            raise SystemExit(f"decoder did not cover every byte of the cave at {at:#x}")
        starts = {insn.addr for insn in rows}
        transfers = []
        for insn in rows:
            if insn.mnem.startswith("j") or insn.mnem == "call":
                if insn.target is None:
                    raise SystemExit(f"no target on {insn.mnem} at {insn.addr:#x}")
                transfers.append((insn.mnem, insn.target))
                # Conditional skip must land inside this cave (the slow path).
                if insn.mnem.startswith("j") and insn.mnem != "jmp" and insn.target not in starts:
                    raise SystemExit(f"{insn.mnem} at {insn.addr:#x} -> {insn.target:#x}, not inside the cave")
        want = list(expected[at])
        got = list(transfers)
        if len(got) != len(want):
            raise SystemExit(f"cave at {at:#x} transfers {got}, wanted {len(want)}:\n" + text)
        for (gm, gt), (wm, wt) in zip(got, want):
            if gm != wm or (wt is not None and gt != wt):
                raise SystemExit(f"cave at {at:#x}: got {gm} {gt:#x}, wanted {wm} "
                                 f"{'any' if wt is None else f'{wt:#x}'}:\n" + text)
        listings.append(text)
    return "\n".join(listings)


def apply_direct_row(data):
    """Skip the per-row memcpy when the edge pad is zero. `data` is the library image."""
    _assert_cave_bounds()
    verify_direct_row_caves()
    _need(data, LUMA_CALL, LUMA_CALL_OLD, "luma memcpy")
    _need(data, CHROMA_CALL, CHROMA_CALL_OLD, "chroma memcpy")
    _need(data, LUMA_RESUME, RESUME_OLD, "luma row loop")
    _need(data, CHROMA_RESUME, RESUME_OLD, "chroma row loop")
    for at, blob in zip(DIRECT_AT, DIRECT_BLOBS):
        if any(data[at:at + len(blob)]):
            raise SystemExit(f"padding at {at:#x} is not empty (direct-row)")
    for at, blob in zip(DIRECT_AT, DIRECT_BLOBS):
        data[at:at + len(blob)] = blob
    data[LUMA_CALL:LUMA_CALL + 5] = _jmp(LUMA_CALL, DIRECT_AT[0])
    data[CHROMA_CALL:CHROMA_CALL + 5] = _jmp(CHROMA_CALL, DIRECT_AT[1])
    data[LUMA_RESUME:LUMA_RESUME + 5] = _jmp(LUMA_RESUME, DIRECT_AT[2])
    data[CHROMA_RESUME:CHROMA_RESUME + 5] = _jmp(CHROMA_RESUME, DIRECT_AT[3])


def apply_short_zero(data):
    """bzero only the first 4096 bytes of the status buffer. Same length as the size load it replaces."""
    _need(data, SHORT_AT, SHORT_OLD, "status bzero size")
    data[SHORT_AT:SHORT_AT + len(SHORT_NEW)] = SHORT_NEW


def patch(data, single_ref=True, low_bar=False, direct_row=False, short_zero=False):
    """Apply the t2d loops, the single-reference clamps, and any named optional patches.

    --low-bar runs before --direct-row so the low-bar cave can claim empty padding at 0x9ee0;
    the direct-row restore stubs sit immediately after that cave.
    """
    _assert_cave_bounds()
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
    if short_zero:
        apply_short_zero(data)
    if direct_row:
        apply_direct_row(data)
    return listing


def main(src, dst, single_ref=True, low_bar=False, direct_row=False, short_zero=False):
    data = bytearray(open(src, "rb").read())
    listing = patch(data, single_ref=single_ref, low_bar=low_bar,
                    direct_row=direct_row, short_zero=short_zero)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: luma and chroma tiling loops now write the t2d / block height 2 layout"
          + ("; P-frames use one reference frame" if single_ref else "; P-frames keep up to three references")
          + ("; flag-0 BAR1 windows dropped after zero-fill (USERD kept)" if low_bar else "")
          + ("; row memcpy skipped when width needs no edge pad" if direct_row else "")
          + ("; status buffer zeroed for 4096 bytes only" if short_zero else ""))
    if listing:
        hook_text, cave_text = listing
        print(f"\npatched buf_alloc {LOW_BAR_HOOK:#x}:")
        print(hook_text)
        print(f"\ncave {FREE_AT:#x}:")
        print(cave_text)


if __name__ == "__main__":
    flags = {"--keep-multi-ref", "--low-bar", "--direct-row", "--short-zero"}
    args = [a for a in sys.argv[1:] if a not in flags]
    if len(args) != 2 or any(a.startswith("-") and a not in flags for a in sys.argv[1:]):
        raise SystemExit(__doc__)
    main(args[0], args[1],
         single_ref="--keep-multi-ref" not in sys.argv,
         low_bar="--low-bar" in sys.argv,
         direct_row="--direct-row" in sys.argv,
         short_zero="--short-zero" in sys.argv)
