#!/usr/bin/env python3
"""Rebuild data/retired.json from git history: every saved version of the city's list
(data/ztm-pojazdy.json), oldest first, through fetch_fleet.py's own update_ledger, then the
working copy's list. The ledger is normally kept by the nightly fetch; this is for seeding it
(done 2026-11-19) or catching up after nights the old script ran without it.

Usage:  python3 scripts/retired_from_history.py && python3 scripts/fetch_fleet.py --offline
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch_fleet as f  # noqa: E402

# Left out on purpose: PKS Polonus's Iveco Crossway LEs went before the App Store launch, and
# bringing the whole model back would add an uncatchable LEGENDARY to older apps' sets.
LEFT_OUT = {("BUS", "35531"), ("BUS", "39532"), ("BUS", "39533")}


def city_at(rev):
    c = json.loads(subprocess.run(["git", "show", f"{rev}:data/ztm-pojazdy.json"], cwd=f.ROOT,
                                  capture_output=True, text=True, check=True).stdout)
    return {**c, "vehicles": f.renumbered(c["vehicles"])}


def main():
    log = subprocess.run(["git", "log", "--reverse", "--format=%h %ad", "--date=short", "--",
                          "data/ztm-pojazdy.json"], cwd=f.ROOT, capture_output=True, text=True, check=True)
    f.save_ledger([])
    raw = f.load_raw()
    # Before the city's list, fleet.json was the scrape alone.
    before, old_city = raw, {"vehicles": []}
    for line in log.stdout.split("\n"):
        if not line:
            continue
        rev, day = line.split()
        city = city_at(rev)
        after = f.with_city(raw, city, report=False)
        f.update_ledger(before, after, old_city, day)
        before, old_city = after, city
    if f.CITY.exists():
        f.update_ledger(before, f.with_city(raw, f.load_city(), report=False), old_city,
                        f.date.today().isoformat())
    # The hand-kept RETIRED list isn't vehicles leaving: they never were in the book.
    rows = [r for r in f.load_ledger() if (r["kind"], r["number"]) not in LEFT_OUT
            and int(r["number"]) not in f.RETIRED.get((r["kind"], r["make"], r["model"], f.short_carrier(r["carrier"])), set())]
    f.save_ledger(rows)
    print(f"{len(rows)} vehicles in {f.LEDGER.relative_to(f.ROOT)}")


if __name__ == "__main__":
    main()
