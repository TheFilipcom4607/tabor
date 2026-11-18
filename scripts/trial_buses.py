#!/usr/bin/env python3
"""List the buses on trial in Warsaw that the app doesn't have yet, from the live feed.

Warsaw numbers its trial buses 9xx (the Irizars #956 and #959, the hydrogen Urbino #955, the
eCitaro #957), and no regular bus has such a number. Trial buses never reach the city's vehicle
list, so the nightly rebuild can't see them; the live feed can. A bus whose model fleet.json
already has is skipped: the issue is the to-do list, and the "?" ones wait for TEST_BUSES in
fetch_fleet.py, once a source names them.

The feed forgets a vehicle a few hours after its last report, though - a trial bus parks
overnight - so listing only what the feed holds right now would flicker with the service day,
dropping and re-adding the same bus (and re-commenting "Nowe:") every morning. The caller hands
the script the issue's current body: a 9xx in it keeps its last sighting and line until that
sighting is 7 days old, the same window a fresh sighting gets.

Writes a Markdown issue body to the given path when there are any, and nothing when there are
none. Exits 1 if the feed can't be read, so the caller leaves the issue alone.

Usage:  python3 scripts/trial_buses.py <body.md> [previous-issue-body.md]
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
in_book = {n for m in fleet["models"] if m["kind"] == "BUS"
           for b in m["batches"] for n in b["numbers"]}

when = lambda t: datetime.fromisoformat(t)


def previous(path):
    """The issue's current body, as {number: (last seen, line, Time string)}."""
    if path is None:
        return {}
    seen = {}
    try:
        for row in Path(path).read_text().splitlines():
            if not row.startswith("| #9"):
                continue
            cells = [c.strip() for c in row.split("|")][1:-1]
            try:
                seen[cells[0].lstrip("#")] = (when(cells[3]), cells[2], cells[3])
            except (IndexError, ValueError):
                pass
    except FileNotFoundError:
        pass
    return seen


# Last known sighting per trial bus: the issue body keeps what the feed has dropped, and a
# fresh feed row wins over the body's older one.
seen = previous(sys.argv[2] if len(sys.argv) > 2 else None)
for r in rows:
    n = r["VehicleNumber"]
    if re.fullmatch(r"9\d\d", n) and (n not in seen or seen[n][0] < when(r["Time"])):
        seen[n] = (when(r["Time"]), r["Lines"], r["Time"])

# Time is Warsaw wall-clock with no zone, so measure against the newest row, not the clock.
newest = max([when(r["Time"]) for r in rows] + [t for t, _, _ in seen.values()])
last = {n: v for n, v in seen.items() if int(n) not in in_book and newest - v[0] <= WINDOW}

if not last:
    print("no trial buses waiting for a model")
    sys.exit(0)

# The number stays the first column: the workflow finds new buses by "| #9xx" at a row's start.
lines = [f"| #{n} | ? | {line or '?'} | {stamp[:16]} |"
         for n, (_, line, stamp) in sorted(last.items())]
print("\n".join(lines))
# Only the hints: thefilip.com/tabor/boty#testy explains them.
Path(sys.argv[1]).write_text(
    "| Numer | Model | Linia | Ostatnio |\n"
    "|---|---|---|---|\n" + "\n".join(lines) + "\n"
    "\n"
    "<sub>[Nie wiesz, co to?](https://thefilip.com/tabor/boty#testy)</sub>\n"
)
