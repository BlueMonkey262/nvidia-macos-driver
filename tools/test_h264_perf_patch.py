#!/usr/bin/env python3
"""Check the optional --direct-row and --short-zero patches against the 2.2.0 H.264 encoder.

The library is not in this repo. Set NVENC_H264_LIB to its path. Requires unicorn
and capstone. Exit 77 if the library or those packages are missing. The cave
bytes are decoded by make_nvenc_t2d.py (no objdump), then executed and compared
with the unpatched memcpy path.

usage: NVENC_H264_LIB=/path/to/libnvenc_h264.dylib python3 tools/test_h264_perf_patch.py
"""
import hashlib
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "make_nvenc_t2d", os.path.join(ROOT, "tools", "make_nvenc_t2d.py"))
nv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nv)

# Locked to the caves make_nvenc_t2d.py embeds (their decoded instructions are listed in that file).
LUMA_DIRECT = bytes.fromhex(
    "4c89b5d0fcffff4883bdf8fcffff00750f4d89fe4c8bbd48fdffffe970c5ffffe843e5ffffe946c5ffff")
CHROMA_DIRECT = bytes.fromhex(
    "4c89b5d0fcffff4883bdf8fcffff0075084d89fee9fac5ffffe8a9e4ffffe9c6c5ffff")
LUMA_RESTORE = bytes.fromhex("4c8bb5d0fcffff41ffc4418b470ce9eec3ffff")
CHROMA_RESTORE = bytes.fromhex("4c8bb5d0fcffff41ffc4418b410ce9fbc4ffff")
SHORT_NEW = bytes.fromhex("be001000006690")
BZERO_CALL = bytes.fromhex("e8ff180000")  # call bzero immediately after the short-zero site


# SHA-256 of the whole patched image for the flag combinations a user can ask for, built from the 2.2.0 encoder.
# A change to any patch byte, hook or cave changes one of these; update them in the same commit when that is intended.
IMAGE_SHA256 = {
    "default": "ca868cd1aaad535c5d0c2968ba41b951ac95500300407cd45732a698d20aca05",
    "low_bar": "76e67e3b3ea00aed502a734f0ec0447edfc5934068b16bbc3e16bda66b45597b",
    "low_bar+direct": "4f48f46bc32e51fde7d272e439b5b10045a768885b2ea935b24ff315c8494b6e",
    "low_bar+short": "a7a194011d726c70cacf792174b611114cd1a5bfb71e856b510220427f327ab5",
    "low_bar+direct+short": "ff440c3d7d04066b17754a2cf1f7b9e3b95bfb1d5b335e6f07bd4ba555b6ca82",
}
IMAGE_FLAGS = {
    "default": dict(single_ref=True),
    "low_bar": dict(single_ref=True, low_bar=True),
    "low_bar+direct": dict(single_ref=True, low_bar=True, direct_row=True),
    "low_bar+short": dict(single_ref=True, low_bar=True, short_zero=True),
    "low_bar+direct+short": dict(single_ref=True, low_bar=True, direct_row=True, short_zero=True),
}


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


def changed(a, b):
    return {i for i, (x, y) in enumerate(zip(a, b)) if x != y}


def windows(kind):
    """Byte ranges one flag is allowed to touch, on top of an already-patched base."""
    if kind == "direct":
        w = set()
        for at, blob in zip(nv.DIRECT_AT, (LUMA_DIRECT, CHROMA_DIRECT, LUMA_RESTORE, CHROMA_RESTORE)):
            w |= set(range(at, at + len(blob)))
        w |= set(range(nv.LUMA_CALL, nv.LUMA_CALL + 5))
        w |= set(range(nv.CHROMA_CALL, nv.CHROMA_CALL + 5))
        w |= set(range(nv.LUMA_RESUME, nv.LUMA_RESUME + 5))
        w |= set(range(nv.CHROMA_RESUME, nv.CHROMA_RESUME + 5))
        return w
    if kind == "short":
        return set(range(nv.SHORT_AT, nv.SHORT_AT + len(SHORT_NEW)))
    fail(kind)


# Bytes at the direct-row landing pads. The caves jump here; these are the original instructions.
LANDING = (
    (nv.LUMA_RESUME_CONT, bytes.fromhex("c1e004")),          # shl eax, 4
    (nv.CHROMA_RESUME_CONT, bytes.fromhex("c1e003")),        # shl eax, 3
    (nv.LUMA_TILE, bytes.fromhex("4c8b8d38fdffff")),         # mov r9, [rbp-0x2c8]
    (nv.CHROMA_TILE, bytes.fromhex("83bd30fdffff00")),       # cmp dword [rbp-0x2d0], 0
)


def check_transfers(image, start, stop, allow):
    blob = bytes(image[start:stop])
    rows = nv.decode(blob, start)
    if b"".join(insn.raw for insn in rows) != blob:
        fail(f"decoder did not cover the cave at {start:#x}")
    starts = {insn.addr for insn in rows}
    for insn in rows:
        if not (insn.mnem.startswith("j") or insn.mnem == "call"):
            continue
        if insn.target is None:
            fail(f"no target on {insn.mnem} at {insn.addr:#x}")
        if insn.target not in starts and insn.target not in allow:
            fail(f"{insn.mnem} at {insn.addr:#x} -> {insn.target:#x}, not an instruction start")


def check_locked_bytes(image):
    if nv.LUMA_DIRECT != LUMA_DIRECT or nv.CHROMA_DIRECT != CHROMA_DIRECT:
        fail("DIRECT cave constants in make_nvenc_t2d.py no longer match the locked bytes")
    if nv.LUMA_RESTORE != LUMA_RESTORE or nv.CHROMA_RESTORE != CHROMA_RESTORE:
        fail("RESTORE cave constants in make_nvenc_t2d.py no longer match the locked bytes")
    if nv.SHORT_NEW != SHORT_NEW:
        fail("SHORT_NEW in make_nvenc_t2d.py no longer matches the locked bytes")
    for at, blob in zip(nv.DIRECT_AT, (LUMA_DIRECT, CHROMA_DIRECT, LUMA_RESTORE, CHROMA_RESTORE)):
        if image[at:at + len(blob)] != blob:
            fail(f"cave bytes at {at:#x} do not match the locked cave")
    if image[nv.SHORT_AT:nv.SHORT_AT + len(SHORT_NEW)] != SHORT_NEW:
        fail("short-zero bytes do not match")
    if image[0x6A0E:0x6A13] != BZERO_CALL:
        fail("short-zero overwrote the bzero call")


def _imports():
    try:
        import capstone
        from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE, UcError
        from unicorn.x86_const import (
            UC_X86_REG_RAX, UC_X86_REG_RBX, UC_X86_REG_RDX, UC_X86_REG_RSI,
            UC_X86_REG_RDI, UC_X86_REG_R9, UC_X86_REG_R12, UC_X86_REG_R13,
            UC_X86_REG_R14, UC_X86_REG_R15, UC_X86_REG_RBP, UC_X86_REG_RSP,
            UC_X86_REG_RIP)
    except ImportError:
        return None
    return {
        "capstone": capstone, "Uc": Uc, "UC_ARCH_X86": UC_ARCH_X86,
        "UC_MODE_64": UC_MODE_64, "UC_HOOK_CODE": UC_HOOK_CODE, "UcError": UcError,
        "regs": {
            "rax": UC_X86_REG_RAX, "rbx": UC_X86_REG_RBX, "rdx": UC_X86_REG_RDX,
            "rsi": UC_X86_REG_RSI, "rdi": UC_X86_REG_RDI, "r9": UC_X86_REG_R9,
            "r12": UC_X86_REG_R12, "r13": UC_X86_REG_R13, "r14": UC_X86_REG_R14,
            "r15": UC_X86_REG_R15, "rbp": UC_X86_REG_RBP, "rsp": UC_X86_REG_RSP,
            "rip": UC_X86_REG_RIP,
        },
    }


MEMSET = 0x8378
STACK, FRAME = 0x70000000, 0x70002000
DESC, SRC, STAGING, DEST = 0x610000, 0x620000, 0x630000, 0x640000
DEST_LEN = 0x100000
PITCH, HEIGHT = 2048, 0x2A


def emulate(original, emu):
    """Run the direct-row caves and the unpatched memcpy path on the same row; the tiled bytes must match."""
    Uc, UcError = emu["Uc"], emu["UcError"]
    regs = emu["regs"]
    md = emu["capstone"].Cs(emu["capstone"].CS_ARCH_X86, emu["capstone"].CS_MODE_64)
    copied = bytearray(original)
    nv.patch(copied, single_ref=True)
    direct = bytearray(original)
    nv.patch(direct, single_ref=True, direct_row=True)
    shortened = bytearray(original)
    nv.patch(shortened, single_ref=True, short_zero=True)
    hook = next(md.disasm(bytes(direct[nv.LUMA_CALL:nv.LUMA_CALL + 5]), nv.LUMA_CALL))
    if hook.mnemonic != "jmp":
        fail(f"luma memcpy hook decoded as {hook.mnemonic}")

    source = bytes((i * 17 + 9) & 0xFF for i in range(0x1000))
    if int.from_bytes(source[0x0C:0x10], "little") == HEIGHT:
        fail("synthetic row looks like the descriptor height")
    if int.from_bytes(source[0x10:0x14], "little") == PITCH:
        fail("synthetic row looks like the descriptor pitch")

    def reg(uc, name):
        return uc.reg_read(regs[name])

    def wreg(uc, name, value):
        uc.reg_write(regs[name], value)

    def put(uc, addr, value, width=8):
        uc.mem_write(addr, int(value).to_bytes(width, "little"))

    def machine(image):
        uc = Uc(emu["UC_ARCH_X86"], emu["UC_MODE_64"])
        uc.mem_map(0, 0x10000)
        uc.mem_write(0, bytes(image[:0xA000]))
        for addr, size in ((STACK, 0x10000), (DESC, 0x1000), (SRC, 0x1000),
                           (STAGING, 0x1000), (DEST, DEST_LEN)):
            uc.mem_map(addr, size)
        uc.mem_write(nv.MEMCPY, b"\xc3")
        uc.mem_write(MEMSET, b"\xc3")
        seen = {"memcpy": 0, "memset": 0}

        def copies(_uc, addr, _size, _ud):
            if addr not in (nv.MEMCPY, MEMSET):
                return
            n = reg(_uc, "rdx")
            seen["memcpy" if addr == nv.MEMCPY else "memset"] += 1
            if not n:
                return
            if n > 0x1000:
                fail(f"copy length {n:#x} at {addr:#x}")
            if addr == nv.MEMCPY:
                _uc.mem_write(reg(_uc, "rdi"), bytes(_uc.mem_read(reg(_uc, "rsi"), n)))
            else:
                _uc.mem_write(reg(_uc, "rdi"), bytes([reg(_uc, "rsi") & 0xFF]) * n)

        uc.hook_add(emu["UC_HOOK_CODE"], copies)
        return uc, seen

    def go(uc, start, stop, tag):
        try:
            uc.emu_start(start, stop, count=100000)
        except UcError as exc:
            fail(f"{tag}: fault at {reg(uc, 'rip'):#x}: {exc}")
        if reg(uc, "rip") != stop:
            fail(f"{tag}: stopped at {reg(uc, 'rip'):#x}, wanted {stop:#x}")

    def row(image, kind, y, copy_len, tile_len):
        pad = tile_len - copy_len
        uc, seen = machine(image)
        uc.mem_write(SRC, source)
        uc.mem_write(STAGING, b"\xA5" * 0x1000)
        uc.mem_write(DEST, b"\xCC" * DEST_LEN)
        put(uc, DESC + 0x0C, HEIGHT, 4)
        put(uc, DESC + 0x10, PITCH, 4)
        put(uc, FRAME - 0x308, pad)
        put(uc, FRAME - 0x310, STAGING + copy_len)
        put(uc, FRAME - 0x2C8, tile_len)
        put(uc, FRAME - 0x2D0, 1)
        put(uc, FRAME - 0x2B8, DESC)
        put(uc, FRAME - 0x320, DEST)
        wreg(uc, "r12", y)
        wreg(uc, "r13", copy_len)
        wreg(uc, "r14", STAGING)
        wreg(uc, "r15", SRC)
        wreg(uc, "rbp", FRAME)
        wreg(uc, "rsp", STACK + 0x1000)
        wreg(uc, "rbx", DEST if kind == "luma" else tile_len)
        entry, stop, cont = ((0x636C, 0x6330, 0x6337) if kind == "luma"
                             else (0x6486, 0x6450, 0x6457))
        tag = f"{kind} y={y} copy={copy_len}"
        go(uc, entry, stop, tag)
        go(uc, stop, cont, tag + " restore")
        return {
            "dest": bytes(uc.mem_read(DEST, DEST_LEN)),
            "staging": bytes(uc.mem_read(STAGING, tile_len)),
            "source": bytes(uc.mem_read(SRC, len(source))),
            "r14": reg(uc, "r14"), "r15": reg(uc, "r15"), "r9": reg(uc, "r9"),
            "r12": reg(uc, "r12") & 0xFFFFFFFF,
            "eax": reg(uc, "rax") & 0xFFFFFFFF,
            "saved": int.from_bytes(uc.mem_read(FRAME - 0x330, 8), "little"),
            "memcpy": seen["memcpy"], "memset": seen["memset"],
        }

    cases = [(kind, y, 64, 64) for y in (0, 5, 16) for kind in ("luma", "chroma")]
    cases += [(kind, y, 48, 64) for y in (0, 7) for kind in ("luma", "chroma")]
    for kind, y, copy_len, tile_len in cases:
        old = row(copied, kind, y, copy_len, tile_len)
        new = row(direct, kind, y, copy_len, tile_len)
        tag = f"{kind} y={y} copy={copy_len} tile={tile_len}"
        if old["source"] != source or new["source"] != source:
            fail(f"{tag}: source buffer was modified")
        if old["dest"] != new["dest"]:
            at = next(i for i, (a, b) in enumerate(zip(old["dest"], new["dest"])) if a != b)
            fail(f"{tag}: tiled output differs at dest+{at:#x}")
        if old["r14"] != STAGING or new["r14"] != STAGING:
            fail(f"{tag}: r14 is {old['r14']:#x} / {new['r14']:#x}, wanted the staging pointer")
        if old["r12"] != y + 1 or new["r12"] != y + 1:
            fail(f"{tag}: row counter {old['r12']} / {new['r12']}")
        if old["eax"] != HEIGHT or new["eax"] != HEIGHT:
            fail(f"{tag}: eax is {old['eax']:#x} / {new['eax']:#x}, wanted {HEIGHT:#x}")
        if old["r15"] != new["r15"] or old["r9"] != new["r9"]:
            fail(f"{tag}: r15 {old['r15']:#x}/{new['r15']:#x} r9 {old['r9']:#x}/{new['r9']:#x}")
        if tile_len == copy_len:
            if new["memcpy"] or new["memset"]:
                fail(f"{tag}: fast path still called memcpy {new['memcpy']} memset {new['memset']}")
            if new["staging"] != b"\xA5" * tile_len:
                fail(f"{tag}: fast path wrote the staging buffer")
            if old["memcpy"] != 1:
                fail(f"{tag}: unpatched path did not call memcpy")
            if kind == "luma" and new["r15"] != DESC:
                fail(f"{tag}: luma descriptor reload left r15={new['r15']:#x}")
            if kind == "chroma" and new["r15"] != SRC:
                fail(f"{tag}: chroma r15 changed to {new['r15']:#x}")
        else:
            if old["memcpy"] != 1 or new["memcpy"] != 1:
                fail(f"{tag}: slow path memcpy {old['memcpy']} / {new['memcpy']}")
            if kind == "luma" and (old["memset"] != 1 or new["memset"] != 1):
                fail(f"{tag}: slow path memset {old['memset']} / {new['memset']}")
            if old["staging"] != new["staging"]:
                fail(f"{tag}: staging after the copy and edge fill differs")
        if new["saved"] != STAGING:
            fail(f"{tag}: saved staging pointer is {new['saved']:#x}")

    def status_length(image, planted):
        uc = Uc(emu["UC_ARCH_X86"], emu["UC_MODE_64"])
        uc.mem_map(0, 0x10000)
        uc.mem_write(0, bytes(image[:0xA000]))
        uc.mem_write(0xB2B0, planted.to_bytes(8, "little"))
        wreg(uc, "rsi", 0xDEAD)
        go(uc, nv.SHORT_AT, 0x6A0E, "short-zero")
        return reg(uc, "rsi")

    planted = 0x690000
    if status_length(original, planted) != planted:
        fail("unpatched status length ignored the global at 0xb2b0")
    if status_length(shortened, planted) != 0x1000:
        fail("short-zero did not load 4096")
    print("emulated direct-row caves against the memcpy path; short-zero length is 4096")


def main():
    path = os.environ.get("NVENC_H264_LIB", "")
    if not path or not os.path.isfile(path):
        print("skip: set NVENC_H264_LIB to libnvenc_h264.dylib (2.2.0)")
        return 77
    emu = _imports()
    if emu is None:
        print("SKIP: install unicorn and capstone to execute the machine-code checks")
        return 77
    original = load_tool_bytes(path)

    plain = bytearray(original)
    nv.patch(plain, single_ref=True)
    if plain[nv.LUMA_CALL:nv.LUMA_CALL + 5] != nv.LUMA_CALL_OLD:
        fail("default patch rewrote the luma memcpy call")
    if plain[nv.SHORT_AT:nv.SHORT_AT + len(nv.SHORT_OLD)] != nv.SHORT_OLD:
        fail("default patch rewrote the status bzero size load")

    base = bytearray(original)
    nv.patch(base, single_ref=True, low_bar=True)

    alone = {}
    for kind, kw in (("direct", dict(direct_row=True)), ("short", dict(short_zero=True))):
        img = bytearray(original)
        nv.patch(img, single_ref=True, **kw)
        got = changed(original, img)
        # t2d + single-ref always apply; only the flag's extra window is checked against base
        base_only = bytearray(original)
        nv.patch(base_only, single_ref=True)
        extra = changed(base_only, img)
        if not extra <= windows(kind):
            fail(f"{kind} touched bytes outside its window: {sorted(extra - windows(kind))[:8]}")
        alone[kind] = img

    both = bytearray(original)
    nv.patch(both, single_ref=True, low_bar=True, direct_row=True, short_zero=True)
    extra = changed(base, both)
    allowed = windows("direct") | windows("short")
    if not extra <= allowed:
        fail(f"combined perf touched {sorted(extra - allowed)[:8]}")
    must = {nv.LUMA_CALL, nv.CHROMA_CALL, nv.LUMA_RESUME, nv.SHORT_AT}
    if not must <= extra:
        fail(f"combined perf missed hooks {sorted(must - extra)}")
    if both[nv.CAVE_L:nv.CAVE_L + len(nv.LUMA_CAVE)] != nv.LUMA_CAVE:
        fail("direct-row overwrote the t2d luma cave")
    if both[nv.FREE_AT:nv.FREE_AT + len(nv.LOW_BAR_CAVE)] != nv.LOW_BAR_CAVE:
        fail("perf caves overwrote the low-bar cave")
    check_locked_bytes(both)

    allow = {nv.LUMA_TILE, nv.LUMA_AFTER_COPY, nv.MEMCPY, nv.CHROMA_TILE, nv.CHROMA_AFTER_COPY,
             nv.LUMA_RESUME_CONT, nv.CHROMA_RESUME_CONT}
    check_transfers(both, nv.DIRECT_AT[0], nv.DIRECT_AT[0] + len(LUMA_DIRECT), allow)
    check_transfers(both, nv.DIRECT_AT[1], nv.DIRECT_AT[1] + len(CHROMA_DIRECT), allow)
    check_transfers(both, nv.DIRECT_AT[2],
                    nv.DIRECT_AT[2] + len(LUMA_RESTORE) + len(CHROMA_RESTORE), allow)
    for at, raw in LANDING:
        if both[at:at + len(raw)] != raw:
            fail(f"landing pad at {at:#x} is {both[at:at + len(raw)].hex()}, wanted {raw.hex()}")
    print("decoder: caves decode and jumps land on instruction starts")

    for name, kw in IMAGE_FLAGS.items():
        img = bytearray(original)
        nv.patch(img, **kw)
        got = hashlib.sha256(img).hexdigest()
        if got != IMAGE_SHA256[name]:
            fail(f"patched image for {name} changed: sha256 {got}, locked {IMAGE_SHA256[name]}")
    print(f"image sha256 locks: {', '.join(IMAGE_FLAGS)}")

    mutated = bytearray(original)
    mutated[0x20] ^= 0xFF
    text = expect_exit(lambda: nv.patch(mutated, direct_row=True), "hash gate")
    if "not the known encoder" not in text:
        fail(f"hash gate message was {text!r}")
    expect_exit(lambda: nv.apply_direct_row(bytearray(both)), "second apply direct-row")
    expect_exit(lambda: nv.apply_short_zero(bytearray(both)), "second apply short-zero")
    occupied = bytearray(base)
    occupied[nv.DIRECT_AT[0]] = 0xCC
    expect_exit(lambda: nv.apply_direct_row(occupied), "padding not empty")
    print("negative controls: hash gate, second apply, padding not empty")

    # Flags compose: each alone matches the corresponding slice of the combined image.
    for kind, kw in (("direct", dict(direct_row=True)), ("short", dict(short_zero=True))):
        one = bytearray(original)
        nv.patch(one, single_ref=True, low_bar=True, **kw)
        for i in windows(kind):
            if one[i] != both[i]:
                fail(f"{kind} alone disagrees with combined at {i:#x}")
    print("flags compose with --low-bar and with each other")
    emulate(original, emu)
    print(f"ok {path}: --direct-row caves at {[hex(a) for a in nv.DIRECT_AT]}; "
          f"--short-zero {len(SHORT_NEW)} bytes at {nv.SHORT_AT:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
