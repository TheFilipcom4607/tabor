#!/usr/bin/env python3
"""List buses and trams running on the live feed whose number fleet.json doesn't have at all.

A new delivery runs on the street, and so on the live feed, days or weeks before the city's
vehicle list carries it (the Otokars #9001–9054 did), and the nightly build can only place what
that list has. So this is the earliest sign of a new batch, a vehicle back from somewhere, or a
number the city's list dropped by mistake. Trial buses (9xx) have their own issue, and 5-digit
suburban minibuses and oddities like "d. 35154" are left out. Retired vehicles count as known:
one still running shows in HUNT as LAST RUNS, not here.

Like trial_buses.py, it keeps a number listed until its last sighting is 7 days old: the caller
hands it the issue's current body, so the list doesn't flicker with the service day. Each row
carries czynaczas.pl's name for the number when he has one (--czynaczas, from `czynaczas.py
hints`) and a phototrans search for it.

Writes a Markdown issue body to the given path when there are any, and nothing when there are
none. Exits 1 if neither feed can be read, so the caller leaves the issue alone.

Usage:  python3 scripts/new_numbers.py <body.md> [previous-issue-body.md] [--czynaczas <hints.json>]
"""
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from czynaczas import name  # noqa: E402
from phototrans import Phototrans  # noqa: E402

FEED = "https://taborapi.thefilip.com/v1/vehicles?type={}"
KINDS = {"BUS": 1, "TRAM": 2}
# The feed keeps rows years old; a vehicle counts only if it reported with the rest just now.
FRESH = timedelta(minutes=10)
WINDOW = timedelta(days=7)
when = datetime.fromisoformat

args = sys.argv[1:]
hints = {}
if "--czynaczas" in args:
    i = args.index("--czynaczas")
    path = Path(args[i + 1])
    del args[i:i + 2]
    hints = json.loads(path.read_text()) if path.exists() else {}
cars = hints.get("vehicles", {})

fleet = json.loads((ROOT / "Tabor/Resources/fleet.json").read_text())
photo = Phototrans(fleet)
known = set(photo.operator)


def previous(path):
    """The issue's current body, as {(kind, number): (last seen, line, Time string)}."""
    seen = {}
    try:
        for row in Path(path).read_text().splitlines():
            m = re.match(r"\| (BUS|TRAM) #(\d+) \|", row)
            if not m:
                continue
            cells = [c.strip() for c in row.split("|")][1:-1]
            try:
                seen[(m.group(1), m.group(2))] = (when(cells[3]), cells[2], cells[3])
            except (IndexError, ValueError):
                pass
    except (FileNotFoundError, TypeError):
        pass
    return seen


seen = previous(args[1] if len(args) > 1 else None)
newest, read = None, 0
for kind, t in KINDS.items():
    try:
        req = urllib.request.Request(FEED.format(t), headers={"User-Agent": "tabor-fleet-action"})
        rows = json.load(urllib.request.urlopen(req, timeout=30))["result"]
        # Errors come back as HTTP 200 with a string in "result".
        assert isinstance(rows, list) and rows, rows
    except Exception as e:
        print(f"couldn't read the {kind.lower()} feed: {e}", file=sys.stderr)
        continue
    read += 1
    # Time is Warsaw wall-clock with no zone, so measure against the newest row, not the clock.
    top = max(when(r["Time"]) for r in rows)
    newest = max(newest or top, top)
    for r in rows:
        n = r["VehicleNumber"]
        if not re.fullmatch(r"\d{3,4}", n) or top - when(r["Time"]) > FRESH:
            continue
        if kind == "BUS" and re.fullmatch(r"9\d\d", n):
            continue  # "Autobusy na testach"
        if (kind, int(n)) in known:
            continue
        if (kind, n) not in seen or seen[(kind, n)][0] < when(r["Time"]):
            seen[(kind, n)] = (when(r["Time"]), r["Lines"], r["Time"])

if not read:
    sys.exit(1)

# A number placed since stays known; one gone quiet for a week drops off.
last = {k: v for k, v in seen.items() if (k[0], int(k[1])) not in known and newest - v[0] <= WINDOW}
if not last:
    print("no new numbers on the live feed")
    sys.exit(0)

code = {"BUS": "3", "TRAM": "0"}
lines = []
for (kind, n), (_, line, stamp) in sorted(last.items(), key=lambda x: (x[0][0], int(x[0][1]))):
    car = name(cars.get(f"{code[kind]}/{n}")) or ""
    lines.append(f"| {kind} #{n} | {car.replace('|', '/')} | {line or '?'} | {stamp[:16]} | {photo.link(kind, n)} |")
print("\n".join(lines))
credit = "Model: [czynaczas.pl](https://czynaczas.pl) · " if cars else ""
# The vehicle stays the first column and Ostatnio the fourth: previous() and the workflow read them.
Path(args[0]).write_text(
    "| Pojazd | czynaczas.pl | Linia | Ostatnio | Sprawdź |\n"
    "|---|---|---|---|---|\n" + "\n".join(lines) + "\n"
    "\n"
    f"<sub>{credit}[Nie wiesz, co to?](https://thefilip.com/tabor/boty#nowe-numery)</sub>\n"
)
