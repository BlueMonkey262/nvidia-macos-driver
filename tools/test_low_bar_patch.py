#!/usr/bin/env python3
"""Check the optional --low-bar patch against the 2.2.0 H.264 encoder.

The library is not in this repo. Set NVENC_H264_LIB to its path. Exit 77 when that
file is missing. Stdlib only, plus objdump when it is on PATH. If unicorn and
capstone import, also emulate the changed buf_alloc path.

usage: NVENC_H264_LIB=/path/to/libnvenc_h264.dylib python3 tools/test_low_bar_patch.py
"""
import importlib.util
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "make_nvenc_t2d", os.path.join(ROOT, "tools", "make_nvenc_t2d.py"))
nv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nv)

# Locked to the cave make_nvenc_t2d.py embeds (86 bytes at 0x9ee0, the GNU as output of LOW_BAR_ASM).
CAVE = bytes.fromhex(
    "e82de4ffff4585ff753c488d05e71100004839c374304c8d43208b138b3592150000488d3d27150000"
    "31c9e8d0d4ffff85c0751731c048894308488943284889432048894330e9139affff41bfffffffff"
    "e96d9bffff")
HOOK = bytes.fromhex("e9a2650000")  # jmp 0x9ee0
XORPS = bytes.fromhex("0f57c0")      # the instruction the cave jumps back to


def fail(msg):
    raise SystemExit(msg)


def load_tool_bytes(path):
    return bytearray(open(path, "rb").read())


def expect_exit(fn, note):
    try:
        fn()
    except SystemExit as exc:
        if exc.code in (0, None):
            fail(f"negative control did not fail ({note})")
        return str(exc)
    fail(f"negative control returned normally ({note})")


def ranges(image):
    """Disassemble from known instruction starts and return addr -> (mnemonic, ops)."""
    if not shutil.which("objdump"):
        return None
    slices = [
        (0x3770, 0x3AC0),                 # buf_alloc, includes the hook and both jump targets
        (nv.FREE_AT, nv.FREE_AT + len(CAVE)),
        (nv.BZERO, nv.BZERO + 6),
        (nv.UNMAP, nv.UNMAP + 6),
    ]
    out = {}
    for start, stop in slices:
        rows, _ = nv.disassemble(image[start:stop], start)
        for addr, _raw, mnem, ops in rows:
            if mnem in ("(bad)", ""):
                fail(f"objdump could not decode {addr:#x}")
            if start <= addr < stop:
                out[addr] = (mnem, ops)
    return out


def transfers(decoded):
    found = []
    for addr, (mnem, ops) in sorted(decoded.items()):
        if mnem.startswith("j") or mnem == "call":
            tgt = nv._abs_target(ops)
            if tgt is None:
                fail(f"no target on {mnem} at {addr:#x}: {ops}")
            found.append((addr, mnem, tgt))
    return found


def check_boundaries(decoded):
    starts = set(decoded)
    for addr, mnem, tgt in transfers(decoded):
        in_hook = addr == nv.LOW_BAR_HOOK
        in_cave = nv.FREE_AT <= addr < nv.FREE_AT + len(CAVE)
        if (in_hook or in_cave) and tgt not in starts:
            fail(f"{mnem} at {addr:#x} lands at {tgt:#x}, not an instruction boundary")


def check_bytes(image):
    if image[nv.LOW_BAR_HOOK:nv.LOW_BAR_HOOK + 5] != HOOK:
        fail(f"hook {image[nv.LOW_BAR_HOOK:nv.LOW_BAR_HOOK + 5].hex()} != {HOOK.hex()}")
    if image[nv.FREE_AT:nv.FREE_AT + len(CAVE)] != CAVE:
        fail("cave bytes do not match the assembled cave")
    if image[nv.LOW_BAR_BACK:nv.LOW_BAR_BACK + 3] != XORPS:
        fail("instruction after the hook was overwritten")
    if any(image[nv.FREE_AT + len(CAVE):nv.FREE_END]):
        fail("cave spilled into the rest of the padding")
    if nv.LOW_BAR_CAVE != CAVE:
        fail("LOW_BAR_CAVE in make_nvenc_t2d.py no longer matches the locked cave bytes")


def negative_boundary(image):
    """A jmp that lands one byte into xorps must be rejected."""
    bad = bytearray(image)
    # cave jmp back is `e9 13 9a ff ff` at FREE_AT+0x46; +1 misses 0x393e.
    at = nv.FREE_AT + CAVE.find(bytes.fromhex("e9139affff"))
    bad[at + 1] = (bad[at + 1] + 1) & 0xFF
    decoded = ranges(bad)
    if decoded is None:
        print("objdump missing; boundary negative control skipped")
        return
    try:
        check_boundaries(decoded)
    except SystemExit:
        return
    fail("negative control: a mid-instruction jump was accepted")


def emulate(image):
    try:
        from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE, UcError
        from unicorn.x86_const import (
            UC_X86_REG_RAX, UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_RSI,
            UC_X86_REG_RDI, UC_X86_REG_R8, UC_X86_REG_R14, UC_X86_REG_R15,
            UC_X86_REG_RBX, UC_X86_REG_RSP, UC_X86_REG_RIP)
        import capstone
    except ImportError:
        print("unicorn/capstone not importable; buf_alloc emulation skipped")
        return
    cs = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    caps = [insn.address for insn in cs.disasm(CAVE, nv.FREE_AT)]
    decoded = ranges(image)
    if decoded is None:
        print("objdump not on PATH; buf_alloc emulation skipped")
        return
    cave_starts = sorted(a for a in decoded if nv.FREE_AT <= a < nv.FREE_AT + len(CAVE))
    if caps != cave_starts:
        fail(f"capstone cave boundaries {caps} != objdump {cave_starts}")

    def run(rbx, r15, unmap_eax):
        uc = Uc(UC_ARCH_X86, UC_MODE_64)
        uc.mem_map(0, 0x10000)
        uc.mem_write(0, bytes(image[:0xA000]))
        uc.mem_map(0xB000, 0x1000)
        uc.mem_write(0xB494, (0x77).to_bytes(4, "little"))
        uc.mem_map(0x600000, 0x1000)
        uc.mem_map(0x70000000, 0x20000)
        uc.mem_write(nv.BZERO, b"\xc3")
        uc.mem_write(nv.LOW_BAR_BACK, b"\x0f\x0b")   # ud2: stop on the way back
        uc.mem_write(nv.LOW_BAR_FAIL, b"\x0f\x0b")
        uc.mem_write(nv.UNMAP, b"\xb8" + (unmap_eax & 0xFFFFFFFF).to_bytes(4, "little") + b"\xc3")
        seen = {"bzero": 0, "unmap": 0}
        def hook(_uc, addr, _size, _ud):
            if addr == nv.BZERO:
                seen["bzero"] += 1
            elif addr == nv.UNMAP:
                seen["unmap"] += 1
                seen["rdi"] = _uc.reg_read(UC_X86_REG_RDI)
                seen["esi"] = _uc.reg_read(UC_X86_REG_RSI) & 0xFFFFFFFF
                seen["edx"] = _uc.reg_read(UC_X86_REG_RDX) & 0xFFFFFFFF
                seen["ecx"] = _uc.reg_read(UC_X86_REG_RCX) & 0xFFFFFFFF
                seen["r8"] = _uc.reg_read(UC_X86_REG_R8)
        uc.hook_add(UC_HOOK_CODE, hook)
        base = rbx
        uc.mem_write(base, (0x42).to_bytes(4, "little"))
        for off, val in ((0x8, 0x1000), (0x20, 0x99), (0x28, 0x1000), (0x30, 0x10000)):
            uc.mem_write(base + off, val.to_bytes(8, "little"))
        uc.reg_write(UC_X86_REG_RSP, 0x70010000)
        uc.reg_write(UC_X86_REG_RBX, rbx)
        uc.reg_write(UC_X86_REG_R15, r15)
        uc.reg_write(UC_X86_REG_R14, 0xABC0)
        try:
            uc.emu_start(nv.LOW_BAR_HOOK, 0, count=64)
        except UcError:
            pass
        seen["rip"] = uc.reg_read(UC_X86_REG_RIP)
        seen["r15"] = uc.reg_read(UC_X86_REG_R15)
        seen["r14"] = uc.reg_read(UC_X86_REG_R14)
        seen["mem"] = bytes(uc.mem_read(base, 0x38))
        return seen

    def q(mem, off):
        return int.from_bytes(mem[off:off + 8], "little")

    keep = run(nv.USERD, 0, 0)
    if keep["bzero"] != 1 or keep["unmap"] or keep["rip"] != nv.LOW_BAR_BACK or q(keep["mem"], 0x28) != 0x1000:
        fail(f"USERD path unmapped or skipped bzero: {keep}")
    sysmem = run(0x600000, 1, 0)
    if sysmem["unmap"] or sysmem["rip"] != nv.LOW_BAR_BACK or q(sysmem["mem"], 0x28) != 0x1000:
        fail(f"flag-1 path dropped its mapping: {sysmem}")
    ok = run(0x600000, 0, 0)
    if ok["unmap"] != 1 or ok["rip"] != nv.LOW_BAR_BACK or ok["r15"] != 0 or ok["r14"] != 0xABC0:
        fail(f"flag-0 success path: {ok}")
    if ok["rdi"] != nv.RM or ok["esi"] != 0x77 or ok["edx"] != 0x42 or ok["ecx"] != 0 or ok["r8"] != 0x600020:
        fail(f"unmap arguments: {ok}")
    if any(q(ok["mem"], off) for off in (0x8, 0x20, 0x28, 0x30)):
        fail("CPU pointer fields still set after a successful unmap")
    bad = run(0x600000, 0, 0x51)
    if bad["rip"] != nv.LOW_BAR_FAIL or bad["r15"] != 0xFFFFFFFF or q(bad["mem"], 0x28) != 0x1000:
        fail(f"unmap failure did not return -1 with the mapping intact: {bad}")
    print("emulated buf_alloc cave: USERD kept, flag 1 kept, flag 0 unmapped, unmap error returns -1")


def main():
    path = os.environ.get("NVENC_H264_LIB", "")
    if not path or not os.path.isfile(path):
        print("skip: set NVENC_H264_LIB to libnvenc_h264.dylib (2.2.0)")
        return 77
    original = load_tool_bytes(path)
    plain = bytearray(original)
    nv.patch(plain, single_ref=True, low_bar=False)
    if plain[nv.LOW_BAR_HOOK:nv.LOW_BAR_HOOK + 5] != nv.CALL_BZERO:
        fail("default patch rewrote the bzero call")
    patched = bytearray(original)
    nv.patch(patched, single_ref=True, low_bar=True)
    check_bytes(patched)
    # t2d sites still patched, and nothing outside the known windows moved
    changed = [i for i, (a, b) in enumerate(zip(plain, patched)) if a != b]
    allowed = set(range(nv.LOW_BAR_HOOK, nv.LOW_BAR_HOOK + 5)) | set(range(nv.FREE_AT, nv.FREE_AT + len(CAVE)))
    if not set(changed) <= allowed:
        fail(f"low-bar touched bytes outside the hook and the cave: {sorted(set(changed) - allowed)[:8]}")
    decoded = ranges(patched)
    if decoded is None:
        print("objdump not on PATH; decode and boundary checks skipped")
    else:
        if nv.LOW_BAR_HOOK not in decoded or decoded[nv.LOW_BAR_HOOK][0] != "jmp":
            fail(f"hook did not decode as jmp: {decoded.get(nv.LOW_BAR_HOOK)}")
        check_boundaries(decoded)
        negative_boundary(patched)
        print("objdump: hook and cave decode; jumps land on instruction boundaries")
    mutated = bytearray(original)
    mutated[0x20] ^= 0xFF
    text = expect_exit(lambda: nv.patch(mutated, low_bar=True), "hash gate")
    if "not the known encoder" not in text:
        fail(f"hash gate message was {text!r}")
    bad_hook = bytearray(original)
    bad_hook[nv.LOW_BAR_HOOK] ^= 0xFF
    expect_exit(lambda: nv.apply_low_bar(bad_hook), "unexpected hook bytes")
    again = bytearray(patched)
    expect_exit(lambda: nv.apply_low_bar(again), "second apply")
    print("negative controls: hash gate, bad hook, second apply, mid-instruction jump")
    emulate(patched)
    print(f"ok {path}: --low-bar hook {HOOK.hex()} cave {len(CAVE)} bytes at {nv.FREE_AT:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
