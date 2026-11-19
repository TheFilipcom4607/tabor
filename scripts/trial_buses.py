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

czynaczas.pl's data (--czynaczas, written by `czynaczas.py hints`) fills in what a reviewer would
otherwise look up: the bus's make, model and year from his vehicle list, and his special-vehicles
entry for it ("Testowy Irizar ie bus 12 electric", with its dates). A trial bus on his special
list that the feed hasn't shown yet is listed too, without a line. His data is a hint, never
complete: a source still has to confirm the model before it goes in TEST_BUSES.

Writes a Markdown issue body to the given path when there are any, and nothing when there are
none. Exits 1 if the feed can't be read, so the caller leaves the issue alone.

Usage:  python3 scripts/trial_buses.py <body.md> [previous-issue-body.md] [--czynaczas <hints.json>]
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
seen = previous(args[1] if len(args) > 1 else None)
for r in rows:
    n = r["VehicleNumber"]
    if re.fullmatch(r"9\d\d", n) and (n not in seen or seen[n][0] < when(r["Time"])):
        seen[n] = (when(r["Time"]), r["Lines"], r["Time"])

# Time is Warsaw wall-clock with no zone, so measure against the newest row, not the clock.
newest = max([when(r["Time"]) for r in rows] + [t for t, _, _ in seen.values()])
last = {n: v for n, v in seen.items() if int(n) not in in_book and newest - v[0] <= WINDOW}

# His special entries for trial buses, by number: the newest, if he has more than one.
special = {}
for s in sorted(hints.get("special", []), key=lambda s: s.get("start_date") or ""):
    kind, _, n = (s.get("id") or "").partition("/")
    if kind == "3" and re.fullmatch(r"9\d\d", n) and (s.get("expiration_date") or "9")[:10] >= f"{newest:%Y-%m-%d}":
        special[n] = s
# On his list but not (yet) on the feed: worth knowing before it turns up.
coming = [n for n in special if n not in last and int(n) not in in_book]

if not last and not coming:
    print("no trial buses waiting for a model")
    sys.exit(0)

def cell(text):
    return " ".join(str(text).replace("|", "/").split())


def entry(n):
    """His special entry: its fuller text, then the dates it gives."""
    s = special.get(n)
    if not s:
        return ""
    text = cell(s.get("detailsText") or s.get("text") or "")
    start, end = (s.get("start_date") or "")[:10], (s.get("expiration_date") or "")[:10]
    dates = " → ".join(f"{d[8:10]}.{d[5:7]}.{d[:4]}" for d in (start, end) if d)
    return " · ".join(x for x in (text, dates) if x)


def model(n):
    """His vehicle list's make, model and year, else his special entry's name, else ?."""
    return cell(name(cars.get(f"3/{n}")) or (special.get(n) or {}).get("text", "").removeprefix("Testowy ") or "?")


# The number stays the first column: the workflow finds new buses by "| #9xx" at a row's start,
# and the Ostatnio column fourth, which previous() reads back (a "–" there is dropped and comes
# back from his list).
rows = {n: f"| #{n} | {model(n)} | {line or '?'} | {stamp[:16]} | {entry(n)} | {photo.link('BUS', n)} |"
        for n, (_, line, stamp) in last.items()}
rows |= {n: f"| #{n} | {model(n)} | – | – | {entry(n)} | {photo.link('BUS', n)} |" for n in coming}
lines = [rows[n] for n in sorted(rows)]
print("\n".join(lines))
credit = "Model i opis: [czynaczas.pl](https://czynaczas.pl) · " if cars or special else ""
# Only the hints: thefilip.com/tabor/boty#testy explains them.
Path(args[0]).write_text(
    "| Numer | Model | Linia | Ostatnio | czynaczas.pl | Sprawdź |\n"
    "|---|---|---|---|---|---|\n" + "\n".join(lines) + "\n"
    "\n"
    f"<sub>{credit}[Nie wiesz, co to?](https://thefilip.com/tabor/boty#testy)</sub>\n"
)
