#!/usr/bin/env python3
"""Signs that a vehicle is out in an event wrap that WRAPS doesn't have yet.

Event wraps (Christmas, Valentine's, summer…) are announced with a fleet number, but nobody
publishes them as data, so the rows in fetch_fleet.py's WRAPS are added by hand once a source
confirms them. This looks for the hints and lists them for a human:

- Vehicles on an event line in the live feed: anything that isn't a plain number or a routine
  lettered line (suburban L, night N, replacement Z, express E, cemetery C). The Christmas gift
  bus ran as M, Valentine's as W26, the summer bus as WAKACJE.
- New posts in MZA's news search for the words its wrap posts use. "spec" also catches
  timetable posts; that's the price of not missing "specjalnie oklejony". So each post's text
  goes to Jev (TypeSafe's decision model, through OpenRouter's Decisions API; it costs about
  $0.0001 a post), which says how likely it is to be about a dressed-up vehicle, and posts
  below WRAP_ODDS are dropped. Without OPENROUTER_API_KEY, or when Jev can't be reached, every
  post is listed, as before.

The city's December "Świąteczne pojazdy" post has no search to poll, so that one stays a habit.
czynaczas.pl's specialVehicles list is accurate, but it's a third party's private API: the issue
only links it, for a human to open.

Writes a Markdown issue body to the given path when there's anything, nothing when there isn't.
Exits 1 if neither the feed nor MZA could be read, so the caller leaves the issue alone.

--skip leaves out hints a human has already dismissed: one per line, a post's URL or a vehicle
as `BUS #1976 | M`. The Action builds it from the wraps issues a human closed, for any reason;
the bot's own close dismisses nothing.

--check asks Jev about the given posts and prints its odds, for tuning WRAP_ODDS.

Usage:  python3 scripts/possible_wraps.py <body.md> [--skip <file>]
        python3 scripts/possible_wraps.py --check <post URL>...
"""
import argparse
import functools
import html
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEED = "https://taborapi.thefilip.com/v1/vehicles?type={}"
MZA = "https://www.mza.waw.pl/?s={}&post_type=post"
# Jev weeds out the timetable posts, so the net can be wide.
TERMS = ["spec", "oklej", "naklej", "ozdob", "świąteczn", "wakacyjn", "walentyn", "halloween"]
JEV = "https://openrouter.ai/api/alpha/decisions"
# Pinned: the threshold was picked against this version.
JEV_MODEL = "typesafe/jev-1.14"
# Low on purpose (the user, 2026-10-30): a bad issue or two beats a missed wrap, which costs a
# sticker nobody can get again. Only posts Jev is fairly sure about are dropped.
WRAP_ODDS = 0.1
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
        # One block per post, so a date can't pair with the next post's title. The first result's
        # title is an <h3>, the rest <h2>s.
        for block in re.split(r'class="grid-posts-item\b', body)[1:]:
            day = re.search(r'<time datetime="(\d{4}\.\d\d\.\d\d)">', block)
            link = re.search(r'<h[23] class="news-box__title"><a href="([^"]+)">(.*?)</a>', block, re.S)
            if not day or not link:
                continue
            url, title = link.groups()
            posted = datetime.strptime(day.group(1), "%Y.%m.%d").date()
            if today - posted <= POST_WINDOW:
                posts[url] = (posted, html.unescape(re.sub(r"<[^>]+>", "", title)).strip(), url)
    return sorted(posts.values(), reverse=True)


# Asked twice a post: once for Jev, once for the numbers it names.
@functools.lru_cache
def post_text(url):
    """A post's title and text, without the page around it."""
    page = get(url).decode("utf-8", "replace")
    title = re.search(r"<h1>(.*?)</h1>", page, re.S)
    body = page.split('single-grid-container__content', 1)[-1].split('single-grid-container__navigation', 1)[0]
    body = re.sub(r"<(script|style)\b.*?</\1>", " ", body, flags=re.S)
    text = html.unescape(re.sub(r"<[^>]+>", " ", body))
    text = re.sub(r"\s+", " ", text.split(">", 1)[-1]).strip()
    return (html.unescape(title.group(1)).strip() if title else ""), text[:8000]


def mentions(text):
    """Fleet numbers a post names: "o numerze bocznym 5887", "nr 1976", "#5919"."""
    found = re.findall(r"(?:\bnr\.?|\bnumer\w*(?:\s+(?:boczny|taborowy)\w*)?|#)\s*(\d{3,4})\b", text, re.I)
    return sorted(set(found), key=found.index)


def wrap_odds(posts):
    """{url: probability that the post is about a vehicle in a special wrap}, or {} without Jev."""
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        print("no OPENROUTER_API_KEY: listing every post", file=sys.stderr)
        return {}
    odds = {}
    for url in posts:
        try:
            title, text = post_text(url)
            request = {
                "model": JEV_MODEL,
                "state": {"publisher": "MZA, Warsaw's city bus operator", "title": title, "post": text},
                "questions": {"wrap": {
                    "type": "noul",
                    "instructions": "Does this post say that a particular bus or tram is, or will be, "
                                    "dressed up for an occasion: a themed wrap, special stickers or "
                                    "decorations that change how the vehicle looks?",
                    "criteria": {
                        "true": "A vehicle is wrapped, stickered or decorated for an event, a holiday "
                                "(Christmas, Valentine's, Halloween, summer) or a campaign, e.g. "
                                "'specjalnie oklejony autobus', 'świąteczny autobus', 'Świętobus'.",
                        "false": "Timetables, special or extra lines, route changes, rear-window ads, "
                                 "new deliveries, jobs, safety advice, or events where the vehicles "
                                 "look as they always do.",
                    },
                }},
            }
            reply = json.loads(urllib.request.urlopen(urllib.request.Request(
                JEV, data=json.dumps(request).encode(), method="POST",
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"}),
                timeout=30).read())
            odds[url] = reply["answers"]["wrap"]["noul"]
            print(f"{odds[url]:.0%}  {title}  ({reply.get('usage', {}).get('cost', '?')} USD)", file=sys.stderr)
        except Exception as e:
            # A post Jev couldn't judge is listed: better a hint too many than a wrap missed.
            print(f"couldn't ask Jev about {url} ({e})", file=sys.stderr)
    return odds


def main():
    args = argparse.ArgumentParser()
    args.add_argument("body", nargs="?")
    args.add_argument("--skip", type=Path)
    args.add_argument("--check", nargs="+", metavar="URL")
    args = args.parse_args()
    if args.check:
        wrap_odds(args.check)
        return
    if not args.body:
        sys.exit("give a body file, or --check <post URL>...")
    skip = set()
    if args.skip and args.skip.exists():
        skip = {l.strip() for l in args.skip.read_text().splitlines() if l.strip()}

    fleet = json.loads((ROOT / "Tabor/Resources/fleet.json").read_text())
    today = date.today()
    # Wraps already in, and running now: nothing to report about them.
    known = {(w["kind"], str(w["number"])) for w in fleet.get("wraps", [])
             if w["from"] <= today.isoformat() <= w["to"]}

    lines, posts, failed = [], [], []
    try:
        lines = [x for x in event_lines()
                 if (x[0], x[1]) not in known and f"{x[0]} #{x[1]} | {x[2]}" not in skip]
    except Exception as e:
        failed.append(f"the live feed ({e})")
    try:
        posts = [p for p in mza_posts(today) if p[2] not in skip]
    except Exception as e:
        failed.append(f"MZA's news ({e})")
    odds = wrap_odds([u for _, _, u in posts])
    posts = [p for p in posts if odds.get(p[2], 1) >= WRAP_ODDS]
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
        out += ["**MZA's news** (last 3 weeks" + (", that Jev thinks may be about a wrap" if odds else "") + ")", ""]
        for d, t, u in posts:
            notes = [f"Jev {odds[u]:.0%}"] if u in odds else []
            try:
                numbers = mentions(post_text(u)[1]) if u in odds else []
            except Exception:
                numbers = []
            notes += [f"names #{n}" for n in numbers[:5]]
            out.append(f"- {d:%d.%m.%Y} [{t}]({u})" + (" · " + ", ".join(notes) if notes else ""))
        out.append("")
    out.append("Closing this issue dismisses everything in it for good, whatever the reason picked.")
    out.append("")
    out.append("By hand: czynaczas.pl lists the vehicles it knows are special under `specialVehicles` in "
               "<https://czynaczas.pl/api/warsaw/transport> (a third party's API: open it, don't automate it).")
    if failed:
        out.append("")
        out.append("Couldn't read: " + "; ".join(failed) + ".")
    text = "\n".join(out) + "\n"
    print(text)
    Path(args.body).write_text(text)


if __name__ == "__main__":
    main()
