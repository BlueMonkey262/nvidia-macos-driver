#!/usr/bin/env python3
"""Execute the optional HEVC machine-code patches in Unicorn; no GPU is used.

Usage: NVENC_HEVC_DYLIB=/path/to/stock/libnvenc_hevc.dylib python3 tools/test_hevc_perf_patch.py
Requires unicorn and capstone. Exit 77 if dependencies or the closed library are absent.
Checks real row loops against the unoptimized t2d library, alternate swizzle fallback,
padded and 10-bit rows, ASLR, source preservation, composition and refusal controls.
"""
import itertools
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
    from unicorn import x86_const as reg
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
    from capstone.x86_const import X86_OP_IMM
except ImportError:
    print('SKIP: install unicorn and capstone to execute the machine-code checks')
    sys.exit(77)

import make_nvenc_hevc_t2d as tool

BASE = 0x100000
STACK = 0x400000
FRAME = STACK + 0x2000
SESSION = 0x500000
SOURCE = 0x600000
STAGING = 0x700000
DEST = 0x800000
FLAGS = ['inline_tile', 'direct_row', 'short_zero']


def put(uc, at, value, width=8):
    uc.mem_write(at, int(value).to_bytes(width, 'little', signed=value < 0))


def rr(uc, name):
    return uc.reg_read(getattr(reg, 'UC_X86_REG_' + name.upper()))


def wr(uc, name, value):
    uc.reg_write(getattr(reg, 'UC_X86_REG_' + name.upper()), value)


def machine(image):
    uc = Uc(UC_ARCH_X86, UC_MODE_64)
    uc.mem_map(BASE, 0x20000)
    uc.mem_write(BASE, bytes(image))
    for at, length in [(STACK, 0x10000), (SESSION, 0x1000), (SOURCE, 0x100000),
                       (STAGING, 0x10000), (DEST, 0x100000)]:
        uc.mem_map(at, length)
    wr(uc, 'rbp', FRAME)
    wr(uc, 'rsp', FRAME - 0x260)

    def imported_memmove(uc, address, size, _):
        if address == BASE + 0xAC12:
            n = rr(uc, 'rdx')
            uc.mem_write(rr(uc, 'rdi'), bytes(uc.mem_read(rr(uc, 'rsi'), n)))
            wr(uc, 'rax', rr(uc, 'rdi'))
            sp = rr(uc, 'rsp')
            ret = int.from_bytes(uc.mem_read(sp, 8), 'little')
            wr(uc, 'rsp', sp + 8)
            wr(uc, 'rip', ret)
    uc.hook_add(UC_HOOK_CODE, imported_memmove, begin=BASE + 0xAC12, end=BASE + 0xAC12)
    return uc


def row_image(image, plane, width, bpp, helper=tool.SW_T2D):
    """Run the library's actual 64 luma rows or 32 chroma rows, including padding."""
    uc = machine(image)
    height = 64
    aligned = (width + 31) & ~31
    pitch = ((aligned * bpp + 255) // 256) * 256
    stride = width * bpp + 80  # distinct host stride; must not become tiled pitch
    source = bytes((i * 73 + (i >> 4) * 19) & 255 for i in range(stride * height))
    uc.mem_write(SOURCE, source)
    uc.mem_write(STAGING, b'\xA5' * 0x10000)
    uc.mem_write(DEST, b'\xCC' * 0x100000)
    for off, value in [(0, width), (4, height), (0xC, bpp), (0x10, aligned), (0x14, height), (0x18, pitch // bpp)]:
        put(uc, SESSION + off, value, 4)
    for off in (0x48, 0x50):
        put(uc, SESSION + off, BASE + helper)
    for off, val in [(0x218, STAGING), (0x1B8, aligned * bpp), (0x1D0, width * bpp),
                     (0x1D8, SESSION), (0x220, bpp), (0x1C8, width * bpp)]:
        put(uc, FRAME - off, val)
    # A nonzero 10-bit input shift must still operate on staging, never on source.
    put(uc, BASE + 0xE04C, 2 if bpp == 2 else 0, 4)
    wr(uc, 'rdi', SESSION)
    wr(uc, 'r13', bpp)
    wr(uc, 'rbx', width * bpp)
    if plane == 'luma':
        put(uc, FRAME - 0x230, -bpp)
        put(uc, FRAME - 0x20C, pitch >> 6, 4)
        put(uc, FRAME - 0x1E8, DEST)
        put(uc, FRAME - 0x200, SOURCE)
        put(uc, FRAME - 0x250, stride)
        wr(uc, 'rsi', SOURCE)
        wr(uc, 'rdx', stride)
        wr(uc, 'r8', 0)
        wr(uc, 'r15', STAGING)
        start, stop = 0x8913, 0x8A48
    else:
        put(uc, FRAME - 0x1C0, bpp * 2)
        put(uc, FRAME - 0x200, -bpp * 2)
        put(uc, FRAME - 0x1C4, pitch >> 6, 4)
        put(uc, FRAME - 0x238, DEST)
        put(uc, FRAME - 0x248, stride)
        put(uc, FRAME - 0x240, SOURCE)
        wr(uc, 'r14', aligned * bpp)
        wr(uc, 'rdx', 0)
        start, stop = 0x8AAE, 0x8C0F
    uc.emu_start(BASE + start, BASE + stop, count=3000000)
    assert rr(uc, 'rip') == BASE + stop, 'row loop failed to finish'
    assert bytes(uc.mem_read(SOURCE, len(source))) == source, 'source buffer was modified'
    return bytes(uc.mem_read(DEST, 0x100000))


def inline_points(image):
    """Compare the executed caves against the original helper at every intra-GOB input."""
    uc = machine(image)
    preserved = ['rbx', 'rbp', 'rsp', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15']
    for plane, hook, end, table in [('luma', 0x8A21, 0x8A26, 'r12'), ('chroma', 0x8BE7, 0x8BEE, 'r13')]:
        for helper in [tool.SW_T2D, 0x5790, 0x57B0]:
            for y, x in itertools.product(range(8), range(0, 64, 8)):
                for i, name in enumerate(preserved):
                    if name not in ('rbp', 'rsp'):
                        wr(uc, name, 0x111000 + i * 17)
                wr(uc, table, SESSION)
                put(uc, SESSION + (0x48 if plane == 'luma' else 0x50), BASE + helper)
                wr(uc, 'rdi', x)
                wr(uc, 'rsi', y)
                before = {n: rr(uc, n) for n in preserved}
                # Run the original swizzle helper independently as the oracle.
                sp = rr(uc, 'rsp')
                put(uc, sp - 8, BASE + 0xCFF0)
                wr(uc, 'rsp', sp - 8)
                uc.emu_start(BASE + helper, BASE + 0xCFF0, count=1000)
                expected = rr(uc, 'eax')
                if plane == 'chroma':
                    expected = (expected + before['r14']) & 0xFFFFFFFF
                wr(uc, 'rdi', x)
                wr(uc, 'rsi', y)
                uc.emu_start(BASE + hook, BASE + end, count=1000)
                assert rr(uc, 'rip') == BASE + end
                assert rr(uc, 'eax') == expected, (plane, helper, x, y)
                assert all(rr(uc, n) == v for n, v in before.items()), 'live register or stack changed'
    print('ok: executed inline arithmetic and alternate-layout fallback; live registers preserved')


def refuses(fn):
    try:
        fn()
    except SystemExit:
        return
    raise AssertionError('mutation was accepted')


def boundaries(image):
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    for caves, hooks, resumes in [(tool.INLINE_CAVES, tool.INLINE_HOOKS, {0x8A26, 0x8BEE}),
                                   (tool.DIRECT_CAVES, tool.DIRECT_HOOKS, {0x8943, 0x88E7, 0x8AF4, 0xAC12})]:
        for at, blob in caves.items():
            instructions = list(md.disasm(bytes(image[at:at + len(blob)]), at))
            assert sum(i.size for i in instructions) == len(blob)
            starts = {i.address for i in instructions}
            for ins in instructions:
                if ins.mnemonic.startswith('j') or ins.mnemonic == 'call':
                    if ins.operands[0].type == X86_OP_IMM:
                        assert ins.operands[0].imm in starts | resumes, (ins.address, ins.op_str)
        for at, old in hooks.items():
            ins = next(md.disasm(bytes(image[at:at + len(old)]), at))
            assert ins.mnemonic == 'jmp' and ins.operands[0].imm in caves
    print('ok: decoded every cave and checked branch destinations')


def assembler_agrees():
    if not all(shutil.which(name) for name in ('as', 'ld', 'objcopy')):
        print('SKIP: GNU assembler comparison (as/ld/objcopy unavailable)')
        return
    source = pathlib.Path(__file__).with_name('nvenc_hevc_perf.S')
    with tempfile.TemporaryDirectory() as td:
        obj, elf, raw = [str(pathlib.Path(td) / name) for name in ('caves.o', 'caves.elf', 'caves.bin')]
        subprocess.run(['as', '--64', str(source), '-o', obj], check=True)
        subprocess.run(['ld', '-Ttext=0', '--entry=0', obj, '-o', elf], check=True)
        subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text', elf, raw], check=True)
        assembled = pathlib.Path(raw).read_bytes()
        for at, blob in {**tool.INLINE_CAVES, **tool.DIRECT_CAVES}.items():
            assert assembled[at:at + len(blob)] == blob, f'assembly differs at {at:#x}'
    print('ok: readable assembly reproduces every embedded cave byte')


def main():
    path = os.environ.get('NVENC_HEVC_DYLIB')
    if not path or not pathlib.Path(path).is_file():
        print('SKIP: set NVENC_HEVC_DYLIB to the stock libnvenc_hevc.dylib')
        return 77
    raw = pathlib.Path(path).read_bytes()
    base, _ = tool.patch_buffer(raw)
    allflags = dict.fromkeys(FLAGS, True)
    full, _ = tool.patch_buffer(raw, **allflags)
    assembler_agrees()
    boundaries(full)
    inline_points(full)
    for values in itertools.product([False, True], repeat=3):
        flags = dict(zip(FLAGS, values))
        img, _ = tool.patch_buffer(raw, **flags)
        assert len(img) == len(raw)
        # Each flag modifies only its declared hooks/caves.
        allowed = set()
        for active, caves, hooks in [(flags['inline_tile'], tool.INLINE_CAVES, tool.INLINE_HOOKS),
                                      (flags['direct_row'], tool.DIRECT_CAVES, tool.DIRECT_HOOKS)]:
            if active:
                for at, blob in {**caves, **hooks}.items():
                    allowed.update(range(at, at + len(blob)))
        if flags['short_zero']:
            allowed.update(range(tool.SHORT_AT, tool.SHORT_AT + 7))
        assert {i for i, (a, b) in enumerate(zip(base, img)) if a != b} <= allowed
    print('ok: all eight flag combinations; default patch unchanged; edit ranges isolated')
    # Compare complete row output, not Python implementations of the same formula.
    for plane, width, bpp, helper in itertools.product(['luma', 'chroma'], [64, 70, 1920, 1366], [1, 2], [tool.SW_T2D, 0x5790]):
        assert row_image(base, plane, width, bpp, helper) == row_image(full, plane, width, bpp, helper), (plane, width, bpp, helper)
    print('ok: 32 row-loop comparisons (64 executions), including padding, 10-bit shifts, alternate layouts and untouched input')
    for apply, caves, hooks in [(tool.apply_inline_tile, tool.INLINE_CAVES, tool.INLINE_HOOKS),
                                (tool.apply_direct_row, tool.DIRECT_CAVES, tool.DIRECT_HOOKS)]:
        refuses(lambda: apply(bytearray(full)))
        for at in [*caves, *hooks]:
            broken = bytearray(base)
            broken[at] ^= 0xCC
            refuses(lambda: apply(broken))
    broken = bytearray(raw)
    broken[0] ^= 1
    refuses(lambda: tool.patch_buffer(broken, **allflags))
    refuses(lambda: tool.apply_short_zero(bytearray(full)))
    assert struct.unpack_from('<ddd', raw, 0xAC60) == (-41.0, 51.0, 0.5)
    print('ok: hash/site/cave/reapply refusal controls; HEVC Quality constants match controller')
    return 0


if __name__ == '__main__':
    sys.exit(main())
