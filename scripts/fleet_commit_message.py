#!/usr/bin/env python3
"""Says in plain words what a rebuilt fleet.json changes, for the nightly refresh's commit
message and PR. It compares the files themselves, vehicle by vehicle, rather than the build's
log, so the bookkeeping behind the log ("51 from the city's list") never shows.

Usage:  python3 scripts/fleet_commit_message.py          # working copy against HEAD
        python3 scripts/fleet_commit_message.py <ref>    # ... or against another commit
        python3 scripts/fleet_commit_message.py <old> <new>   # two commits
"""
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_fleet import code_of, is_coded  # noqa: E402

PATH = "Tabor/Resources/fleet.json"
SECTIONS = ("models", "worksModels", "codedWorksModels")
# Worked out from the batches, so a vehicle-level change already covers them.
DERIVED = {"batches", "fleet", "firstYear", "lastYear", "operators"}
LIVERIES = {"suburbanBlue": "suburban blue", "oldYellowRed": "old yellow and red",
            "greyRed": "grey and red", None: "the usual paint"}
# What the model-level keys mean, for "details changed".
KEYS = {"name": "name", "namePl": "Polish name", "specs": "specs", "variants": "some vehicles' specs",
        "liveries": "paint", "coupled": "coupling", "sets": "fixed sets", "pairs": "usual sets",
        "trailers": "trailers", "tows": "towing", "trial": "trial note", "trialPl": "trial note",
        "trialEnded": "trial end", "runs": "where it runs", "runsPl": "where it runs",
        "vintage": "tier", "onTest": "tier", "works": "tier", "formerly": "former ids",
        "make": "make", "code": "model code", "kind": "type"}


def load(ref):
    if ref is None:
        return json.loads((ROOT / PATH).read_text())
    return json.loads(subprocess.run(["git", "show", f"{ref}:{PATH}"], cwd=ROOT, check=True,
                                     capture_output=True, text=True).stdout)


def models(d):
    return [m for s in SECTIONS for m in d.get(s, [])]


def vehicles(d):
    """(kind, number, works?) -> what the book says about it. Works cars can share a number
    with a regular tram, so they're kept apart."""
    out = {}
    for m in models(d):
        works = bool(m.get("works"))
        liveries = m.get("liveries", {})
        for b in m["batches"]:
            for n in b["numbers"]:
                out[(m["kind"], n, works)] = {
                    "model": m["name"], "operator": b["operator"], "year": b["year"],
                    "depot": b["depotName"] or b["depotCode"] or "no depot",
                    "paint": LIVERIES.get(liveries.get(str(n)), liveries.get(str(n))),
                }
    return out


def label(n):
    return code_of(n) if is_coded(n) else str(n)


def numbers(kind, nums):
    """('BUS', [1, 2, 3, 7]) -> 'Buses #1–3, #7'"""
    nums, runs = sorted(nums), []
    for n in nums:
        if runs and n == runs[-1][1] + 1 and not is_coded(n):
            runs[-1][1] = n
        else:
            runs.append([n, n])
    noun = kind.capitalize() + ("es" if kind == "BUS" else "s") if len(nums) > 1 else kind.capitalize()
    return noun + " " + ", ".join(f"#{label(a)}–{label(b)}" if a != b else f"#{label(a)}" for a, b in runs)


def section(title, groups):
    """groups: {(kind, text after the numbers): [numbers]} -> a titled list, or nothing."""
    if not groups:
        return []
    rows = sorted(groups.items(), key=lambda kv: (kv[0][0], min(kv[1])))
    return [title] + [f"- {numbers(kind, nums)}{rest}" for (kind, rest), nums in rows] + [""]


def message(old, new):
    ov, nv = vehicles(old), vehicles(new)
    added, gone, moved = defaultdict(list), defaultdict(list), defaultdict(list)
    for key in nv.keys() - ov.keys():
        v = nv[key]
        added[(key[0], f", {v['model']} ({v['operator']}, {v['year']}, {v['depot']})")].append(key[1])
    for key in ov.keys() - nv.keys():
        v = ov[key]
        gone[(key[0], f", {v['model']} ({v['operator']})")].append(key[1])
    for key in nv.keys() & ov.keys():
        a, b = ov[key], nv[key]
        if a["model"] != b["model"]:
            moved[(key[0], f": now a {b['model']}, was a {a['model']}")].append(key[1])
            continue
        for field, what in (("depot", "depot"), ("operator", "operator"), ("year", "year built"),
                            ("paint", "paint")):
            if a[field] != b[field]:
                moved[(key[0], f", {b['model']}: {what} {a[field]} → {b[field]}")].append(key[1])

    lines = []
    lines += section("New in the book:", added)
    lines += section("Gone from the city's list, so out of the book:", gone)
    lines += section("Changed:", moved)

    om, nm = {m["id"]: m for m in models(old)}, {m["id"]: m for m in models(new)}
    for i in sorted(nm.keys() - om.keys()):
        lines.append(f"New model: {nm[i]['name']} ({nm[i]['kind'].lower()}).")
    for i in sorted(nm.keys() & om.keys()):
        # Paint is per vehicle, so a repaint already shows above.
        keys = {k for k in (nm[i].keys() | om[i].keys()) - DERIVED - {"liveries"}
                if nm[i].get(k) != om[i].get(k)}
        if keys:
            what = sorted({KEYS.get(k, k) for k in keys})
            lines.append(f"{nm[i]['name']}: {', '.join(what)} changed.")
    if lines and lines[-1] != "":
        lines.append("")

    skip = set(SECTIONS) | {"source", "sourcePl", "fetched"}
    other = sorted(k for k in (new.keys() | old.keys()) - skip if new.get(k) != old.get(k))
    if other:
        lines += [f"Also changed: {', '.join(other)}.", ""]

    total = lambda d: sum(m["fleet"] for m in d["models"] if not m.get("vintage"))
    if not lines:
        lines += ["Nothing in the book changes.", ""]
    if total(old) != total(new):
        lines.append(f"The fleet goes from {total(old)} to {total(new)} vehicles, in {len(new['models'])} models.")
    else:
        lines.append(f"The fleet stays at {total(new)} vehicles, in {len(new['models'])} models.")
    return "\n".join(lines)


if __name__ == "__main__":
    args = sys.argv[1:]
    old = load(args[0] if args else "HEAD")
    new = load(args[1] if len(args) > 1 else None)
    print(message(old, new))
