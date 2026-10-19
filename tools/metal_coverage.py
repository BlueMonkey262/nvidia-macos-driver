#!/usr/bin/env python3
"""Metal API coverage treemap. One cell per method of each public Metal protocol, grouped by protocol; the whole API
counts, including features aimed at Apple silicon, so nothing is excluded for being hard on this hardware.

usage: metal_coverage.py DUMP.json (--headers SDK/Metal.framework/Headers | --public-list FILE) [--ratings FILE]
       [-o OUT.html] [--svg OUT.svg] [--slim OUT.json]
DUMP.json comes from tools/metal_coverage.m. A method is "implemented" when some NVMTL* class that conforms to its protocol
answers the selector; that says nothing about whether it works. Colors:
  gray    not implemented, or a stub (a method that does nothing useful)    red     implemented, very slow       yellow  needs improvement, good for now
  green   works great               purple  implemented, differs from Apple's result
  teal    answered by Apple's own Metal code (inherited), not by ours
  blue    implemented, not yet rated (the default for every implemented method; only metal-ratings.json can change it)
Exit codes: 0 done, 2 bad input."""
import argparse
import glob
import json
import pathlib
import re
import sys

STATUSES = ["missing", "inherited", "slow", "improve", "great", "differs", "unrated"]
RATED = {"slow", "improve", "great", "differs"}
STUB = "stub"  # a rating, not a color: the method exists but does nothing useful, so it is drawn as not implemented

ap = argparse.ArgumentParser()
ap.add_argument("dump")
ap.add_argument("--headers", help="directory of the Metal.framework headers for the target SDK")
ap.add_argument("--public-list", help="text file with one public protocol name per line (used instead of --headers)")
ap.add_argument("--slim", metavar="OUT", help="also write a reduced dump (public protocols only) that CI can use without the SDK")
ap.add_argument("--svg", metavar="OUT", help="also write a static SVG of the map, for the README")
ap.add_argument("--ratings", default=str(pathlib.Path(__file__).with_name("metal-ratings.json")))
ap.add_argument("-o", "--out", help="interactive HTML page")
args = ap.parse_args()

dump = json.load(open(args.dump))
ratings = json.load(open(args.ratings)) if pathlib.Path(args.ratings).exists() else {}

public = set()
if args.public_list:
    public.update(l.strip() for l in open(args.public_list) if l.strip() and not l.startswith("#"))
elif args.headers:
    for f in glob.glob(f"{args.headers}/*.h"):
        text = open(f, errors="ignore").read()
        public.update(re.findall(r"^@protocol\s+(MTL\w+)\s*(?:<|\n|$)", text, re.M))
else:
    sys.exit("give --headers or --public-list")
protos = {p: dump["protocols"][p] for p in sorted(public & set(dump["protocols"]))}
if not protos:
    sys.exit("no public protocol from the headers appears in the dump")

groups, warnings = [], []
for p, methods in protos.items():
    answered, ours = set(), set()
    for c, v in dump["classes"].items():
        if p in v["conforms"]:
            answered.update(v["responds"])
            for k, o in v.get("owner", {}).items():
                if "NVMTL" in o.split("@", 1)[-1] or "GPUBundles" in o.split("@", 1)[-1]:
                    ours.add(k)
    cells, seen = [], set()
    for m in methods:
        key = (m["inst"], m["sel"])
        if key in seen:
            continue
        seen.add(key)
        k = f"{m['inst']}|{m['sel']}"
        status = "missing" if k not in answered else "unrated" if (k in ours or not any("owner" in v for v in dump["classes"].values())) else "inherited"
        note = ev = ""
        r = ratings.get(p, {})
        r = r.get(m["sel"]) or r.get("*")
        if r:
            if status in ("missing", "inherited"):
                warnings.append(f"ignored rating on {status} {p} {m['sel']}")
            elif r.get("status") in RATED:
                status, note, ev = r["status"], r.get("note", ""), r.get("evidence", "")
            elif r.get("status") == STUB:
                status, note, ev = "missing", "Stub: " + r.get("note", ""), r.get("evidence", "")
            else:
                warnings.append(f"bad status for {p} {m['sel']}: {r.get('status')}")
        cells.append({"s": m["sel"], "st": status, "req": bool(m["req"]), "n": note, "e": ev})
    if cells:
        groups.append({"p": p, "cells": cells})

totals = {s: sum(1 for g in groups for c in g["cells"] if c["st"] == s) for s in STATUSES}
total = sum(totals.values())
data = json.dumps({"groups": groups, "totals": totals, "total": total, "device": dump.get("device", ""),
                   "sdk": ""})

COLORS = {"missing": "#6b7280", "inherited": "#2fa6a0", "slow": "#dc2626", "improve": "#eab308", "great": "#22a559",
          "differs": "#9333ea", "unrated": "#4f78c4"}
LABELS = {"missing": "Not implemented or stub", "inherited": "Apple's code, not ours", "slow": "Very slow", "improve": "Needs improvement",
          "great": "Works great", "differs": "Differs from Apple", "unrated": "Not yet rated"}


def squarify(items, x, y, w, h):
    """Bruls squarified treemap. items: (value, payload); returns (payload, x, y, w, h)."""
    out, rest = [], list(items)
    total = sum(v for v, _ in rest)
    while rest:
        horiz = w >= h
        side = h if horiz else w
        row, row_sum, best = [], 0, float("inf")
        for i in range(len(rest)):
            cand = rest[:i + 1]
            cand_sum = sum(v for v, _ in cand)
            thick = cand_sum / total * (w if horiz else h)
            worst = max(max(thick / (v / cand_sum * side), (v / cand_sum * side) / thick) for v, _ in cand)
            if worst <= best:
                best, row, row_sum = worst, cand, cand_sum
            else:
                break
        thick = row_sum / total * (w if horiz else h)
        off = 0
        for v, payload in row:
            length = v / row_sum * side
            out.append((payload, x, y + off, thick, length) if horiz else (payload, x + off, y, length, thick))
            off += length
        rest = rest[len(row):]
        total -= row_sum
        if horiz:
            x, w = x + thick, w - thick
        else:
            y, h = y + thick, h - thick
    return out


def svg_map(groups, totals, total):
    W, H, TOP = 1200, 540, 62
    esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    done = total - totals["missing"]
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H + TOP}" width="{W}" height="{H + TOP}" '
         f'font-family="sans-serif"><rect width="{W}" height="{H + TOP}" fill="#0f1218"/>',
         f'<text x="6" y="22" font-size="16" font-weight="700" fill="#e6e9ef">Metal API coverage: {done}/{total} methods implemented '
         f'({100 * done / total:.0f}%), {totals["inherited"]} of them by Apple\'s own code</text>']
    lx = 6
    for k in STATUSES:
        label = f"{LABELS[k]} ({totals[k]})"
        p.append(f'<rect x="{lx}" y="36" width="12" height="12" fill="{COLORS[k]}"/>'
                 f'<text x="{lx + 17}" y="47" font-size="12" fill="#c9ced8">{esc(label)}</text>')
        lx += 17 + 7 * len(label) + 14
    items = sorted(((len(g["cells"]), g) for g in groups), key=lambda t: -t[0])
    for g, x, y, w, h in squarify(items, 0, TOP, W, H):
        cells, n = g["cells"], len(g["cells"])
        iw, ih = w - 2, h - 2
        rows = max(1, min(n, round((n * ih / iw) ** 0.5)))
        i = 0
        title = f'{g["p"]}: ' + ", ".join(f'{LABELS[k]} {sum(1 for c in cells if c["st"] == k)}'
                                          for k in STATUSES if any(c["st"] == k for c in cells))
        p.append(f'<g><title>{esc(title)}</title>')
        for r in range(rows):
            count = n // rows + (r < n % rows)
            for c in range(count):
                p.append(f'<rect x="{x + 1 + c * iw / count:.2f}" y="{y + 1 + r * ih / rows:.2f}" width="{iw / count:.2f}" '
                         f'height="{ih / rows:.2f}" fill="{COLORS[cells[i]["st"]]}" stroke="#0f1218" stroke-width="0.5"/>')
                i += 1
        p.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" fill="none" stroke="#0f1218" stroke-width="2"/>')
        label = g["p"].removeprefix("MTL")[:int((w - 10) / 7)]
        if h > 22 and len(label) >= 3:
            p.append(f'<text x="{x + 5:.2f}" y="{y + 15:.2f}" font-size="12" font-weight="700" fill="#fff" stroke="#0f1218" '
                     f'stroke-width="3" paint-order="stroke">{esc(label)}</text>')
        p.append('</g>')
    p.append('</svg>')
    return "\n".join(p)


if args.svg:
    pathlib.Path(args.svg).write_text(svg_map(groups, totals, total), encoding="utf-8")
if args.slim:
    keep = {p: dump["protocols"][p] for p in protos}
    slim = {"device": dump.get("device", ""), "protocols": keep,
            "classes": {c: {"conforms": [p for p in v["conforms"] if p in keep], "responds": v["responds"],
                            "owner": v.get("owner", {})} for c, v in dump["classes"].items()}}
    pathlib.Path(args.slim).write_text(json.dumps(slim, separators=(",", ":"), sort_keys=True), encoding="utf-8")
if args.out:
    TEMPLATE = pathlib.Path(__file__).with_name("metal_coverage.html.tmpl").read_text()
    pathlib.Path(args.out).write_text(TEMPLATE.replace("/*DATA*/", data))
for w in warnings:
    print("warning:", w, file=sys.stderr)
print(f"{total} methods in {len(groups)} protocols: " + ", ".join(f"{s} {totals[s]}" for s in STATUSES))
