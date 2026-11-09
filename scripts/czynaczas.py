#!/usr/bin/env python3
"""Brings czynaczas.pl's partner data to the tabor-live Worker, and shows it to you.

czynaczas.pl (Marcin Bittel) gave TABOR a partner API on 2026-11-09: special vehicles (wraps,
trial buses), remarks on vehicles, tram sets, models and years. His terms: none of it sits in
plain form in the public repo, and nobody gets all of it in one go. The repo and its Actions
logs are public, so this script prints counts only, never his data, unless you run `show`
on your own Mac.

  sync <special.json>   The nightly fleet Action. Asks the Worker for the last upload's ETag,
                        fetches the API with If-None-Match (his request; usually a 304), and on
                        a change PUTs the remarks and the special-vehicles list to the Worker.
                        Either way, writes the special vehicles to <special.json> for
                        possible_wraps.py. Keep that file out of artifacts: those are public.
  show                  On your Mac: the special vehicles, each with the code the wraps issue
                        uses for it, and the remarks.

The API key is CZYNACZAS_API_KEY (a repo secret; locally, the same in Config/Secrets.xcconfig).
The Worker's token is ROUTES_UPLOAD_TOKEN, as for routes.json. His limits: 5 calls a minute,
30 an hour, then a 429 with Retry-After. Once a night is far below that; never retry on a 429.

Usage:  python3 scripts/czynaczas.py sync <special.json>
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
    """A short code for a special vehicle that says nothing about it, for the public wraps issue.
    `show` prints it next to the entry, so you can tell which one the issue means."""
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


def sync(out):
    meta = worker("GET", "/meta")
    status, reply, etag = fetch(meta and meta.get("etag"))
    if status == 304:
        print(f"czynaczas: unchanged since {meta['updated'][:16]} "
              f"({meta['remarks']} remarks, {len(meta['special'])} special vehicles)")
        special = meta["special"]
    else:
        remarks, special = trimmed(reply)
        result = worker("PUT", body={"etag": etag or "", "remarks": remarks, "special": special})
        print(f"czynaczas: uploaded {result['remarks']} remarks, {result['special']} special vehicles")
    Path(out).write_text(json.dumps(special, ensure_ascii=False))


def show():
    _, reply, _ = fetch()
    remarks, special = trimmed(reply)
    print("Special vehicles (code · id · dates · text):")
    for s in special:
        print(f"  {code(s)}  {s['id']:>7}  {s['start_date'][:10]} → {s['expiration_date'][:10]}  "
              f"{s['text']}" + (f" ({s['detailsText']})" if s.get("detailsText") not in (None, s["text"]) else ""))
    print(f"\nRemarks ({len(remarks)}):")
    for k, v in sorted(remarks.items(), key=lambda kv: (kv[0][0], int(kv[0][2:]))):
        print(f"  {'BUS ' if k[0] == '3' else 'TRAM'} #{k[2:]}: {v}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["sync"] and len(sys.argv) == 3:
        sync(sys.argv[2])
    elif sys.argv[1:] == ["show"]:
        show()
    else:
        sys.exit(__doc__)
