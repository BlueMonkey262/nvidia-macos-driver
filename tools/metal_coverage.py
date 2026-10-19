#!/usr/bin/env python3
"""Metal API coverage treemap. One cell per method of each public Metal protocol, grouped by protocol; the whole API
counts, including features aimed at Apple silicon, so nothing is excluded for being hard on this hardware.

usage: metal_coverage.py DUMP.json --headers SDK/Metal.framework/Headers [--ratings tools/metal-ratings.json] -o OUT.html
DUMP.json comes from tools/metal_coverage.m. A method is "implemented" when some NVMTL* class that conforms to its protocol
answers the selector; that says nothing about whether it works. Colors:
  gray    not implemented            red     implemented, very slow       yellow  needs improvement, good for now
  green   works great               purple  implemented, differs from Apple's result
  hatched implemented, not yet rated (the default for every implemented method; only metal-ratings.json can change it)
Exit codes: 0 done, 2 bad input."""
import argparse
import glob
import json
import pathlib
import re
import sys

STATUSES = ["missing", "slow", "improve", "great", "differs", "unrated"]
RATED = {"slow", "improve", "great", "differs"}

ap = argparse.ArgumentParser()
ap.add_argument("dump")
ap.add_argument("--headers", required=True, help="directory of the Metal.framework headers for the target SDK")
ap.add_argument("--ratings", default=str(pathlib.Path(__file__).with_name("metal-ratings.json")))
ap.add_argument("-o", "--out", required=True)
args = ap.parse_args()

dump = json.load(open(args.dump))
ratings = json.load(open(args.ratings)) if pathlib.Path(args.ratings).exists() else {}

public = set()
for f in glob.glob(f"{args.headers}/*.h"):
    text = open(f, errors="ignore").read()
    public.update(re.findall(r"^@protocol\s+(MTL\w+)\s*(?:<|\n|$)", text, re.M))
protos = {p: dump["protocols"][p] for p in sorted(public & set(dump["protocols"]))}
if not protos:
    sys.exit("no public protocol from the headers appears in the dump")

groups, warnings = [], []
for p, methods in protos.items():
    answered = set()
    for c, v in dump["classes"].items():
        if p in v["conforms"]:
            answered.update(v["responds"])
    cells, seen = [], set()
    for m in methods:
        key = (m["inst"], m["sel"])
        if key in seen:
            continue
        seen.add(key)
        status = "unrated" if f"{m['inst']}|{m['sel']}" in answered else "missing"
        note = ev = ""
        r = ratings.get(p, {})
        r = r.get(m["sel"]) or r.get("*")
        if r:
            if status == "missing":
                warnings.append(f"ignored rating on missing {p} {m['sel']}")
            elif r.get("status") in RATED:
                status, note, ev = r["status"], r.get("note", ""), r.get("evidence", "")
            else:
                warnings.append(f"bad status for {p} {m['sel']}: {r.get('status')}")
        cells.append({"s": m["sel"], "st": status, "req": bool(m["req"]), "n": note, "e": ev})
    if cells:
        groups.append({"p": p, "cells": cells})

totals = {s: sum(1 for g in groups for c in g["cells"] if c["st"] == s) for s in STATUSES}
total = sum(totals.values())
data = json.dumps({"groups": groups, "totals": totals, "total": total, "device": dump.get("device", ""),
                   "sdk": pathlib.Path(args.headers).parts[-5] if len(pathlib.Path(args.headers).parts) > 5 else ""})

TEMPLATE = (pathlib.Path(__file__).with_name("metal_coverage.html.tmpl").read_text())
pathlib.Path(args.out).write_text(TEMPLATE.replace("/*DATA*/", data))
for w in warnings:
    print("warning:", w, file=sys.stderr)
print(f"{total} methods in {len(groups)} protocols: " + ", ".join(f"{s} {totals[s]}" for s in STATUSES))
