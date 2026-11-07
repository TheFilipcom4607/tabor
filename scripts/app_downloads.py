#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pyjwt", "cryptography"]
# ///
"""Downloads a day, from App Store Connect's daily Sales and Trends reports (the API), which
come out the morning after, ahead of the Analytics page.

    scripts/app_downloads.py        the last 14 days
    scripts/app_downloads.py 60     the last 60

Apple's day is its own (reports for Europe are out by 5:00 CET the day after, sometimes later),
so the newest day or two can still be missing. Fetched reports are kept in build/sales/, since a
day's report never changes. Needs TABOR_ASC_KEY_ID, TABOR_ASC_ISSUER and TABOR_ASC_VENDOR in
Config/Secrets.xcconfig and the key's .p8 in ~/.appstoreconnect/private_keys. curl, not urllib:
Python's own user agent gets refused by some of Apple's edges."""
import collections, datetime, gzip, json, re, subprocess, sys, time
from pathlib import Path

import jwt

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "build" / "sales"


def secrets():
    text = (ROOT / "Config" / "Secrets.xcconfig").read_text()
    return {k: v for k, v in re.findall(r"^(TABOR_ASC_\w+)\s*=\s*(\S+)", text, re.M)}


def token(s):
    key = (Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{s['TABOR_ASC_KEY_ID']}.p8").read_text()
    now = int(time.time())
    return jwt.encode({"iss": s["TABOR_ASC_ISSUER"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": s["TABOR_ASC_KEY_ID"]})


def report(day, s, tok):
    """The day's rows as dicts, [] for a day with nothing, None while Apple hasn't published it."""
    cached = CACHE / f"{day}.tsv"
    if cached.exists():
        text = cached.read_text()
    else:
        url = ("https://api.appstoreconnect.apple.com/v1/salesReports?filter[frequency]=DAILY"
               "&filter[reportType]=SALES&filter[reportSubType]=SUMMARY&filter[version]=1_1"
               f"&filter[vendorNumber]={s['TABOR_ASC_VENDOR']}&filter[reportDate]={day}")
        body = subprocess.run(["curl", "-sg", "-H", f"Authorization: Bearer {tok}", "-H", "Accept: application/a-gzip", url],
                              capture_output=True, check=True).stdout
        if body[:2] != b"\x1f\x8b":
            detail = json.loads(body)["errors"][0]["detail"]
            if "no sales" in detail:
                text = ""
            elif "not available yet" in detail:
                return None
            else:
                sys.exit(f"{day}: {detail}")
        else:
            text = gzip.decompress(body).decode()
        CACHE.mkdir(parents=True, exist_ok=True)
        cached.write_text(text)
    lines = text.splitlines()
    if not lines:
        return []
    head = lines[0].split("\t")
    return [dict(zip(head, line.split("\t"))) for line in lines[1:]]


# Apple's product type identifiers: 1x a first download, 3x a re-download, 7x an update,
# IAx an in-app purchase (the tips).
def kind(row):
    t = row["Product Type Identifier"]
    return "tips" if t.startswith("IA") else {"1": "new", "3": "again", "7": "updates"}.get(t[:1])


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 14
    s = secrets()
    tok = token(s)
    today = datetime.date.today()
    countries = collections.Counter()
    total = 0
    print("day          new  again  updates  tips")
    for i in range(days, 0, -1):
        day = (today - datetime.timedelta(days=i)).isoformat()
        rows = report(day, s, tok)
        if rows is None:
            print(f"{day}   (not out yet)")
            continue
        sums = collections.Counter()
        for r in rows:
            k = kind(r)
            if k:
                sums[k] += int(r["Units"])
            if k == "new":
                countries[r["Country Code"]] += int(r["Units"])
        total += sums["new"]
        print(f"{day} {sums['new']:5} {sums['again']:6} {sums['updates']:8} {sums['tips']:5}")
    print(f"\n{total} new downloads in {days} days" + (": " + ", ".join(f"{c} {n}" for c, n in countries.most_common(5)) if countries else ""))


if __name__ == "__main__":
    main()
