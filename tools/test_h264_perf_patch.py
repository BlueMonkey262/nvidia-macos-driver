#!/usr/bin/env python3
"""Check the optional --direct-row and --short-zero patches against the 2.2.0 H.264 encoder.

The library is not in this repo. Set NVENC_H264_LIB to its path. Exit 77 when that
file is missing. The cave bytes are decoded by make_nvenc_t2d.py (no objdump).

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


def main():
    path = os.environ.get("NVENC_H264_LIB", "")
    if not path or not os.path.isfile(path):
        print("skip: set NVENC_H264_LIB to libnvenc_h264.dylib (2.2.0)")
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
    print(f"ok {path}: --direct-row caves at {[hex(a) for a in nv.DIRECT_AT]}; "
          f"--short-zero {len(SHORT_NEW)} bytes at {nv.SHORT_AT:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
