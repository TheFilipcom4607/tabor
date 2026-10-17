#!/usr/bin/env python3
"""Signs that a vehicle is out in an event wrap that WRAPS doesn't have yet.

Event wraps (Christmas, Valentine's, summer…) are announced with a fleet number, but nobody
publishes them as data, so the rows in fetch_fleet.py's WRAPS are added by hand once a source
confirms them. This looks for the hints and lists them for a human:

- Vehicles on an event line in the live feed: anything that isn't a plain number or a routine
  lettered line (suburban L, night N, replacement Z, express E, cemetery C). The Christmas gift
  bus ran as M, Valentine's as W26, the summer bus as WAKACJE.
- New posts in MZA's news search for the words its wrap posts use. "spec" also catches
  timetable posts; that's the price of not missing "specjalnie oklejony".

The city's December "Świąteczne pojazdy" post has no search to poll, so that one stays a habit.
czynaczas.pl's specialVehicles list is accurate, but it's a third party's private API: the issue
only links it, for a human to open.

Writes a Markdown issue body to the given path when there's anything, nothing when there isn't.
Exits 1 if neither the feed nor MZA could be read, so the caller leaves the issue alone.

Usage:  python3 scripts/possible_wraps.py <body.md>
"""
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEED = "https://taborapi.thefilip.com/v1/vehicles?type={}"
MZA = "https://www.mza.waw.pl/?s={}&post_type=post"
TERMS = ["spec", "oklej", "świąteczn", "wakacyjn", "walentyn", "halloween"]
# Lines that run every day: suburban L-1/L11, night N01, replacement Z-4/Z12, express E-1,
# cemetery C01 (around 1 November).
ROUTINE = re.compile(r"\d+|[LNZEC]-?\d+")
# The feed keeps each vehicle's last row after it stops; an event line runs a weekend or so.
FEED_WINDOW = timedelta(days=3)
POST_WINDOW = timedelta(days=21)
HEADERS = {"User-Agent": "Mozilla/5.0 (tabor-fleet-action)"}


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30).read()


def event_lines():
    """(kind, number, line, last seen) for vehicles on a non-routine line lately."""
    out = {}
    for kind, t in (("BUS", 1), ("TRAM", 2)):
        rows = json.loads(get(FEED.format(t)))["result"]
        # Errors come back as HTTP 200 with a string in "result".
        assert isinstance(rows, list) and rows, rows
        # Time is Warsaw wall-clock with no zone, so measure against the newest row.
        when = lambda r: datetime.fromisoformat(r["Time"])
        newest = max(when(r) for r in rows)
        for r in rows:
            line = r["Lines"].strip()
            if not line or ROUTINE.fullmatch(line) or newest - when(r) > FEED_WINDOW:
                continue
            key = (kind, r["VehicleNumber"])
            if key not in out or when(r) > when(out[key]):
                out[key] = r
    return [(k, n, r["Lines"].strip(), r["Time"][:16]) for (k, n), r in sorted(out.items())]


def mza_posts(today):
    """(date, title, url) of MZA posts from the last few weeks that match a wrap word."""
    posts = {}
    for term in TERMS:
        body = get(MZA.format(urllib.parse.quote(term))).decode("utf-8", "replace")
        for day, url, title in re.findall(
                r'<time datetime="(\d{4}\.\d\d\.\d\d)">.*?<h2 class="news-box__title"><a href="([^"]+)">(.*?)</a>',
                body, re.S):
            posted = datetime.strptime(day, "%Y.%m.%d").date()
            if today - posted <= POST_WINDOW:
                posts[url] = (posted, html.unescape(re.sub(r"<[^>]+>", "", title)).strip(), url)
    return sorted(posts.values(), reverse=True)


def main():
    fleet = json.loads((ROOT / "Tabor/Resources/fleet.json").read_text())
    today = date.today()
    # Wraps already in, and running now: nothing to report about them.
    known = {(w["kind"], str(w["number"])) for w in fleet.get("wraps", [])
             if w["from"] <= today.isoformat() <= w["to"]}

    lines, posts, failed = [], [], []
    try:
        lines = [x for x in event_lines() if (x[0], x[1]) not in known]
    except Exception as e:
        failed.append(f"the live feed ({e})")
    try:
        posts = mza_posts(today)
    except Exception as e:
        failed.append(f"MZA's news ({e})")
    for f in failed:
        print(f"couldn't read {f}", file=sys.stderr)
    if len(failed) == 2:
        sys.exit(1)
    if not lines and not posts:
        print("no signs of an event wrap")
        return

    out = ["Hints that a vehicle may be out in an event wrap that `WRAPS` doesn't have. Nothing here",
           "goes into the app by itself: add a row to `WRAPS` in `scripts/fetch_fleet.py` once a source",
           "(Radio Kolor, MZA, the city) names the fleet number and dates. This issue closes itself",
           "once there's nothing left to look at.", ""]
    if lines:
        out += ["**On an event line** (last 3 days)", "", "| Vehicle | Line | Last seen (Warsaw time) |", "|---|---|---|"]
        out += [f"| {k} #{n} | {l} | {t} |" for k, n, l, t in lines]
        out.append("")
    if posts:
        out += ["**MZA's news** (last 3 weeks)", ""]
        out += [f"- {d:%d.%m.%Y} [{t}]({u})" for d, t, u in posts]
        out.append("")
    out.append("By hand: czynaczas.pl lists the vehicles it knows are special under `specialVehicles` in "
               "<https://czynaczas.pl/api/warsaw/transport> (a third party's API: open it, don't automate it).")
    if failed:
        out.append("")
        out.append("Couldn't read: " + "; ".join(failed) + ".")
    text = "\n".join(out) + "\n"
    print(text)
    Path(sys.argv[1]).write_text(text)


if __name__ == "__main__":
    main()
