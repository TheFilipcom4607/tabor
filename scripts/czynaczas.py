#!/usr/bin/env python3
"""Brings czynaczas.pl's partner data to the tabor-live Worker, and shows it to you.

czynaczas.pl (Marcin Bittel) gave TABOR a partner API on 2026-11-09: special vehicles (wraps,
trial buses), remarks on vehicles, tram sets, models and years. His terms: none of it sits in
plain form in the public repo, and nobody gets all of it in one go. He's relaxed about the
rest ("te dane to nie jest nic prywatnego"), so the bot's issues may show a special entry or a
single vehicle's model, credited; the remarks, his own writing, only ever reach the app, one at
a time. The logs print counts only.

  sync <special.json>   The nightly fleet Action. Asks the Worker for the last upload's ETag,
                        fetches the API with If-None-Match (his request; usually a 304), and on
                        a change PUTs the remarks and the special-vehicles list to the Worker.
                        Either way, writes the special vehicles to <special.json> for
                        possible_wraps.py. Keep that file out of artifacts: those are public.
                        Brand, model and year per vehicle go to the Worker too, for `hints`.
                        With data/czynaczas-en.json (your Mac only, see below) it also sends
                        the English, so it fetches the whole reply instead of asking for a 304.
  hints <out.json>      For the trials and waiting-vehicles issues: the special vehicles and
                        each vehicle's brand, model and year, from the Worker (not from him,
                        so the hourly trials run doesn't call his API every hour).
  annotate <hints.json> Reads the waiting-vehicles issue's lines on stdin and adds what his data
                        calls each type. Without the file, passes them through.
  todo                  On your Mac: the remarks with no English yet, or whose Polish changed
                        since it was translated, for whoever adds them to the file.
  show                  On your Mac: the special vehicles and the remarks with their English.

The English is written by hand, not by a model, and kept in data/czynaczas-en.json as
{"3/5869": {"pl": "…", "en": "…"}}. It's his text, so the file stays out of git
(.git/info/exclude). The Worker keeps an English text through uploads without it (the Action's)
for as long as the Polish stays the same; a remark without one shows in Polish.

The API key is CZYNACZAS_API_KEY (a repo secret; locally, the same in Config/Secrets.xcconfig).
The Worker's token is ROUTES_UPLOAD_TOKEN, as for routes.json. His limits: 5 calls a minute,
30 an hour, then a 429 with Retry-After. Once a night is far below that; never retry on a 429.

Usage:  python3 scripts/czynaczas.py sync <special.json>
        python3 scripts/czynaczas.py hints <out.json>
        python3 scripts/czynaczas.py annotate <hints.json> < lines
        python3 scripts/czynaczas.py todo
        python3 scripts/czynaczas.py show
"""
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://czynaczas.pl/api/partner?api_key={}"
WORKER = os.environ.get("CZYNACZAS_WORKER", "https://taborapi.thefilip.com/v1/czynaczas")
HEADERS = {"User-Agent": "tabor-fleet-action"}
# A normal reply has about 3100 vehicles. Far fewer means a broken one: keep the last upload.
MIN_VEHICLES = 1000
TRANSLATIONS = ROOT / "data" / "czynaczas-en.json"


def english():
    """{"3/5869": {"pl", "en"}} from the hand-kept file, or {} where there's none (the Action)."""
    return json.loads(TRANSLATIONS.read_text()) if TRANSLATIONS.exists() else {}


def by_vehicle(key):
    """Buses, then trams, by number ("3/403-1" sorts by 403)."""
    kind, _, number = key[0].partition("/")
    digits = re.match(r"\d+", number)
    return kind != "3", int(digits.group()) if digits else 0, number


def secret(env, xcconfig):
    value = os.environ.get(env)
    secrets = ROOT / "Config" / "Secrets.xcconfig"
    if not value and secrets.exists():
        m = re.search(rf"^{xcconfig}\s*=\s*(\S+)", secrets.read_text(), re.M)
        value = m and m.group(1)
    if not value:
        sys.exit(f"no {env}")
    return value


def code(entry):
    """The wraps issue showed special vehicles only as this code until 2026-11-19. Hints dismissed
    under a code stay dismissed, so possible_wraps.py still checks it."""
    raw = f"{entry.get('id')}|{entry.get('start_date')}|{entry.get('text')}"
    return hashlib.sha256(raw.encode()).hexdigest()[:6]


def fetch(etag=None):
    """(status, body, etag). Errors never carry the URL, which holds the key."""
    headers = dict(HEADERS, **({"If-None-Match": etag} if etag else {}))
    req = urllib.request.Request(API.format(secret("CZYNACZAS_API_KEY", "CZYNACZAS_API_KEY")), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return res.status, json.load(res), res.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return 304, None, etag
        retry = e.headers.get("Retry-After")
        # Who refused, for the log: an error page is no partner data, but the key never shows.
        seen = {h: e.headers.get(h) for h in ("Server", "CF-Mitigated", "Content-Type") if e.headers.get(h)}
        page = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", e.read()[:400].decode("utf-8", "replace"))).strip()[:160]
        raise SystemExit(f"czynaczas answered {e.code}" + (f" (retry after {retry} s)" if retry else "")
                         + f" {seen} {page!r}".replace(secret("CZYNACZAS_API_KEY", "CZYNACZAS_API_KEY"), "***"))
    except urllib.error.URLError as e:
        raise SystemExit(f"couldn't reach czynaczas ({type(e.reason).__name__})")


def worker(method, path="", body=None):
    token = secret("ROUTES_UPLOAD_TOKEN", "TABOR_ROUTES_UPLOAD_TOKEN")
    req = urllib.request.Request(
        WORKER + path, method=method, data=body and json.dumps(body).encode(),
        headers=dict(HEADERS, Authorization=f"Bearer {token}", **({"Content-Type": "application/json"} if body else {})))
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.load(res)
    except urllib.error.HTTPError as e:
        if e.code == 404 and method == "GET":
            return None
        raise SystemExit(f"the Worker answered {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")


def trimmed(reply):
    """What the Worker keeps: the remarks (keyed "3/5869") and the special vehicles."""
    vehicles = reply.get("vehicles")
    special = reply.get("specialVehicles")
    if not isinstance(vehicles, dict) or not isinstance(special, list) or len(vehicles) < MIN_VEHICLES:
        raise SystemExit(f"unexpected reply: {len(vehicles or {})} vehicles; keeping the last upload")
    remarks = {k: v["remarks"].strip() for k, v in vehicles.items()
               if isinstance(v, dict) and isinstance(v.get("remarks"), str) and v["remarks"].strip()}
    keep = ("id", "text", "detailsText", "start_date", "expiration_date")
    special = [{k: s.get(k) for k in keep} for s in special if isinstance(s, dict) and s.get("id")]
    return remarks, special


def models(reply):
    """{"3/960": {"brand", "model", "year"}}: what the issues need, without the long operator names."""
    return {k: {"brand": v.get("brand"), "model": v.get("brandModel"), "year": v.get("productionYear")}
            for k, v in reply["vehicles"].items() if isinstance(v, dict) and (v.get("brand") or v.get("brandModel"))}


def sync(out):
    meta = worker("GET", "/meta")
    hand = english()
    # With English to send, the body is needed even when nothing of his changed, and so it is
    # when the Worker has no vehicles yet (the first sync after they were added).
    fresh = hand or not (meta and meta.get("vehicles"))
    status, reply, etag = fetch(None if fresh else meta and meta.get("etag"))
    if status == 304:
        print(f"czynaczas: unchanged since {meta['updated'][:16]} ({meta['remarks']} remarks, "
              f"{meta.get('english', 0)} in English, {len(meta['special'])} special vehicles)")
        special = meta["special"]
    else:
        remarks, special = trimmed(reply)
        # Vehicles first: the ETag below says they're in.
        cars = models(reply)
        worker("PUT", "/vehicles", cars)
        # Only a translation of the Polish as it is now; a stale one would say something else.
        body = {k: {"pl": pl, "en": hand[k]["en"]} if hand.get(k, {}).get("pl") == pl else pl
                for k, pl in remarks.items()}
        result = worker("PUT", body={"etag": etag or "", "remarks": body, "special": special, "vehicles": len(cars)})
        print(f"czynaczas: uploaded {result['remarks']} remarks ({result['english']} in English), "
              f"{result['special']} special vehicles, {len(cars)} vehicles' models")
        if result["english"] < result["remarks"]:
            print(f"{result['remarks'] - result['english']} remarks have no English yet: "
                  "python3 scripts/czynaczas.py todo, on the Mac")
    Path(out).write_text(json.dumps(special, ensure_ascii=False))


def hints(out):
    meta = worker("GET", "/meta") or {}
    cars = worker("GET", "/vehicles") or {}
    Path(out).write_text(json.dumps({"special": meta.get("special", []), "vehicles": cars}, ensure_ascii=False))
    print(f"czynaczas: {len(meta.get('special', []))} special vehicles, {len(cars)} vehicles' models")


def name(car):
    """His row as an issue shows it: "Otokar Vectio C, 2018"."""
    if not car:
        return None
    text = " ".join(x for x in (car.get("brand"), car.get("model")) if x)
    return text + (f", {car['year']}" if car.get("year") else "")


def annotate(path):
    """The waiting issue's "- typ 5909 (autobusy): 9001, 9006, ..." lines, each with the name his
    data gives most of the type's numbers: a type is one model, so a stray row can't mislead."""
    cars = json.loads(Path(path).read_text())["vehicles"] if Path(path).exists() else {}
    sys.path.insert(0, str(ROOT / "scripts"))
    from phototrans import Phototrans
    photo = Phototrans(json.loads((ROOT / "Tabor/Resources/fleet.json").read_text()))
    for line in sys.stdin.read().splitlines():
        # Only the numbers: what the city's list says about the type follows the first " · ".
        m = re.match(r"- typ \d+ \((autobusy|tramwaje)\): ([^·]*)", line)
        # The first number's phototrans search: one look at it usually tells the whole type.
        first = m and re.search(r"\d+", m.group(2))
        tail = f" · {photo.link('BUS' if m.group(1) == 'autobusy' else 'TRAM', first.group())}" if first else ""
        if m and cars:
            kind = "3" if m.group(1) == "autobusy" else "0"
            rows = [cars[k] for n in re.findall(r"\d+", m.group(2)) if (k := f"{kind}/{n}") in cars]
            names = [name(dict(r, year=None)) for r in rows]
            if any(names):
                best = max(set(filter(None, names)), key=names.count)
                years = sorted({r["year"] for r, n in zip(rows, names) if n == best and r.get("year")})
                span = f", {years[0]}" + (f"–{years[-1]}" if len(years) > 1 else "") if years else ""
                line += f" · [czynaczas.pl](https://czynaczas.pl): {best}{span}"
        print(line + tail)


def todo():
    _, reply, _ = fetch()
    remarks, _ = trimmed(reply)
    hand = english()
    vehicles = reply["vehicles"]
    missing = [k for k in sorted(remarks, key=lambda k: by_vehicle((k,))) if hand.get(k, {}).get("pl") != remarks[k]]
    for k in missing:
        v = vehicles[k]
        old = f"\n    was: {hand[k]['pl']}" if k in hand else ""
        print(f"{k} | {v.get('brand')} {v.get('brandModel')} {v.get('productionYear') or ''} "
              f"{v.get('tramSet') or ''}\n    {remarks[k]}{old}")
    print(f"{len(missing)} of {len(remarks)} remarks need English in {TRANSLATIONS.relative_to(ROOT)}")


def show():
    _, reply, _ = fetch()
    remarks, special = trimmed(reply)
    print("Special vehicles (id · dates · text):")
    for s in special:
        print(f"  {s['id']:>7}  {s['start_date'][:10]} → {s['expiration_date'][:10]}  "
              f"{s['text']}" + (f" ({s['detailsText']})" if s.get("detailsText") not in (None, s["text"]) else ""))
    hand = english()
    print(f"\nRemarks ({len(remarks)}):")
    for k, v in sorted(remarks.items(), key=by_vehicle):
        en = hand.get(k, {})
        print(f"  {'BUS ' if k[0] == '3' else 'TRAM'} #{k[2:]}: {v}\n"
              f"        {en['en'] if en.get('pl') == v else '(no English yet)'}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["sync"] and len(sys.argv) == 3:
        sync(sys.argv[2])
    elif sys.argv[1:2] == ["hints"] and len(sys.argv) == 3:
        hints(sys.argv[2])
    elif sys.argv[1:2] == ["annotate"] and len(sys.argv) == 3:
        annotate(sys.argv[2])
    elif sys.argv[1:] == ["show"]:
        show()
    elif sys.argv[1:] == ["todo"]:
        todo()
    else:
        sys.exit(__doc__)
