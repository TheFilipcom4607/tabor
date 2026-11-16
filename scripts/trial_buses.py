#!/usr/bin/env python3
"""List the buses on trial in Warsaw right now, from the live feed.

Warsaw numbers its trial buses 9xx (the Irizars #956 and #959, the hydrogen Urbino #955, the
eCitaro #957), and no regular bus has such a number. Trial buses never reach the city's vehicle
list, so the nightly rebuild can't see them; the live feed can. The feed keeps each vehicle's
last row even after it stops, so a bus that ran yesterday still shows, and a window of a few
days catches a trial however rarely it runs.

Every 9xx seen in that window is listed, two or more at once (from 16 Nov 2026 the Solaris #960
and the Irizar #956 ran side by side), with its model when fleet.json has it and "?" when it
doesn't yet: those wait for TEST_BUSES in fetch_fleet.py, once a source names them. A bus stays
listed while it runs, in the app or not, so the issue is a list of what's on trial.

Writes a Markdown issue body to the given path when there are any, and nothing when there are
none. Exits 1 if the feed can't be read, so the caller leaves the issue alone.

Usage:  python3 scripts/trial_buses.py <body.md>
"""
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEED = "https://taborapi.thefilip.com/v1/vehicles?type=1"
# Trials run for weeks, but not every day.
WINDOW = timedelta(days=7)

try:
    req = urllib.request.Request(FEED, headers={"User-Agent": "tabor-fleet-action"})
    rows = json.load(urllib.request.urlopen(req, timeout=30))["result"]
    # Errors come back as HTTP 200 with a string in "result".
    assert isinstance(rows, list) and rows, rows
except Exception as e:
    print(f"couldn't read the live feed: {e}", file=sys.stderr)
    sys.exit(1)

fleet = json.loads((ROOT / "Tabor/Resources/fleet.json").read_text())
model = {n: m["name"] for m in fleet["models"] if m["kind"] == "BUS"
         for b in m["batches"] for n in b["numbers"]}

# Time is Warsaw wall-clock with no zone, so measure against the newest row, not the clock.
when = lambda r: datetime.fromisoformat(r["Time"])
newest = max(when(r) for r in rows)
last = {}
for r in rows:
    n = r["VehicleNumber"]
    if re.fullmatch(r"9\d\d", n) and newest - when(r) <= WINDOW:
        if n not in last or when(r) > when(last[n]):
            last[n] = r

if not last:
    print("no trial buses in the live feed")
    sys.exit(0)

# The number stays the first column: the workflow finds new buses by "| #9xx" at a row's start.
lines = [f"| #{n} | {model.get(int(n), '?')} | {r['Lines']} | {r['Time'][:16]} |"
         for n, r in sorted(last.items())]
print("\n".join(lines))
# Only the hints: thefilip.com/tabor/boty#testy explains them.
Path(sys.argv[1]).write_text(
    "| Numer | Model | Linia | Ostatnio |\n"
    "|---|---|---|---|\n" + "\n".join(lines) + "\n"
    "\n"
    "<sub>[Nie wiesz, co to?](https://thefilip.com/tabor/boty#testy)</sub>\n"
)
