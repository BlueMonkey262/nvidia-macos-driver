#!/usr/bin/env python3
"""Merge model reviews of the Metal methods into tools/metal-ratings.json.

usage: merge_metal_reviews.py REVIEW_DIR [-o tools/metal-ratings.json]
REVIEW_DIR holds batchN/ directories. Per batch, full-ratings.json (every method rated: stub, partial, differs, slow,
good) wins over ratings.json (the earlier pass that only listed problems: improve, differs). Statuses map to the map's
colors: stub -> gray, partial -> yellow ("improve"), differs -> purple, slow -> red, good -> green ("great"). Every entry
is labelled as a source review that was not tested; a test or measurement should overwrite it with its own evidence."""
import argparse
import json
import pathlib

MAP = {"stub": "stub", "partial": "improve", "improve": "improve", "differs": "differs", "slow": "slow", "good": "great"}

ap = argparse.ArgumentParser()
ap.add_argument("review_dir")
ap.add_argument("-o", "--out", default=str(pathlib.Path(__file__).with_name("metal-ratings.json")))
args = ap.parse_args()

out = {"_comment": "Ratings by protocol and selector. status: stub (drawn gray), improve (yellow), slow (red), great (green), "
                   "differs (purple). Entries marked model-reviewed come from a source review that was not tested."}
used = {}
for batch in sorted(pathlib.Path(args.review_dir).glob("batch*")):
    for name, kind in (("full-ratings.json", "full"), ("ratings.json", "partial")):
        f = batch / name
        if not f.exists():
            continue
        try:
            data = json.loads(f.read_text())
        except ValueError:
            continue
        n = 0
        for proto, sels in data.items():
            if not isinstance(sels, dict):
                continue
            for sel, v in sels.items():
                if not isinstance(v, dict) or v.get("status") not in MAP:
                    continue
                note = v.get("note", "")
                if v.get("confidence") == "low":
                    note += " [low confidence]"
                out.setdefault(proto, {})[sel] = {"status": MAP[v["status"]], "note": note.strip(),
                                                  "evidence": v.get("evidence", "")}
                n += 1
        used[batch.name] = f"{kind} ({n})"
        break
pathlib.Path(args.out).write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
print(", ".join(f"{b}: {k}" for b, k in used.items()))
