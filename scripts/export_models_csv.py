#!/usr/bin/env python3
"""Export Tabor/Resources/fleet.json to data/fleet-models.csv, one row per unbroken run of
fleet numbers of one model, built in one year, at one depot, with one operator: number
range, model, year, count, rarity tier, ZTM code, bus or tram, depot, operator and whether
the cars run coupled in sets.

The depot and operator are read straight from fleet.json's batches (every batch carries
them): re-reading the source rows here would go wrong for split models, whose ZTM rows
still sit under the family's make/model, and for a hand-added bus whose city depot is
blank.

Usage:  python3 scripts/export_models_csv.py   # Python 3.12+, like fetch_fleet.py
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

import fetch_fleet

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Tabor" / "Resources" / "fleet.json"
OUT = ROOT / "data" / "fleet-models.csv"


def spans(numbers):
    """[1, 2, 3, 5, 7, 8] -> [(1, 3), (5, 5), (7, 8)]"""
    nums = sorted({int(n) for n in numbers})
    out, start = [], None
    for i, n in enumerate(nums):
        if start is None:
            start = n
        if i + 1 == len(nums) or nums[i + 1] != n + 1:
            out.append((start, n))
            start = None
    return out


def tier(m):
    """Same tiers as Tier in Tabor/Core/Fleet.swift."""
    if m.get("works"):
        return "WORKS"
    if m.get("vintage"):
        return "VINTAGE"
    if m.get("onTest"):
        return "ON TEST"
    fleet = m["fleet"]
    return "LEGENDARY" if fleet <= 12 else "GOLD" if fleet <= 48 else "RARE" if fleet <= 80 else "COMMON"


def main():
    data = json.loads(SRC.read_text())
    models = data["models"] + data.get("worksModels", []) + data.get("codedWorksModels", [])
    rows = []
    for m in models:
        in_sets = {n for pair in m.get("sets", []) for n in pair}
        groups = defaultdict(list)
        for b in m["batches"]:
            depot = " ".join(filter(None, (b["depotCode"], b["depotName"])))
            groups[(b.get("year"), depot, b["operator"] or "")].extend(b["numbers"])
        for (year, depot, operator), numbers in groups.items():
            for lo, hi in spans(numbers):
                rows.append({
                    "number range": (fetch_fleet.code_of(lo) if fetch_fleet.is_coded(lo) else str(lo)) if lo == hi else f"{lo}-{hi}",
                    "model and make": m["name"],
                    "year": year or "",
                    "count": hi - lo + 1,
                    "rarity": tier(m),
                    "ztm code": m["code"],
                    "type": m["kind"].lower(),
                    "depot": depot,
                    "operator": operator,
                    # Runs as two coupled cars: the whole model, or a fixed set of two.
                    "coupled": "yes" if m.get("coupled") or all(n in in_sets for n in range(lo, hi + 1)) else "",
                    "_sort": (m["kind"] != "TRAM", lo),
                })
    rows.sort(key=lambda r: r.pop("_sort"))
    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} ranges -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
