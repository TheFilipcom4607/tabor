#!/usr/bin/env python3
"""What we know about the numbers in a tester's issue, as a comment for whoever answers it.

A misread issue ("2-misread": what the app read, what's right) or a vehicle issue ("3-vehicle":
the fleet numbers, bus or tram) used to mean looking each number up by hand first: fleet.json,
czynaczas, the live map, phototrans. This does it the moment the issue opens: a table per number
(the app's model for it, czynaczas.pl's name, whether it's on the map now, a phototrans search)
and a line or two of plain facts (a number that's a bus and a tram, how many digits a misread
was off).

It reads only the form's number fields, never the free text, and only digits from those, so
nothing a tester writes ends up in the comment. Issues from other forms get nothing.

Usage:  python3 scripts/issue_lookup.py <issue-body.md> <comment.md> [--czynaczas <hints.json>]
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
KINDS = {"BUS": ("🚌", "3", 1), "TRAM": ("🚋", "0", 2)}
FRESH = timedelta(minutes=10)
# A form field with a whole range typed in shouldn't make a comment nobody reads.
MOST = 8
WORDS = {1: "jedną cyfrą", 2: "dwiema cyframi", 3: "trzema cyframi", 4: "czterema cyframi"}


def field(body, heading):
    """The answer under a form heading ("### Jaki to numer? / ..."), or ""."""
    m = re.search(rf"^### {re.escape(heading)}[^\n]*\n+(.*?)(?=^### |\Z)", body, re.M | re.S)
    answer = m.group(1).strip() if m else ""
    return "" if answer == "_No response_" else answer


def numbers(text):
    return [int(n) for n in dict.fromkeys(re.findall(r"\b\d{1,5}\b", text))][:MOST]


def main():
    args = sys.argv[1:]
    hints = {}
    if "--czynaczas" in args:
        i = args.index("--czynaczas")
        path = Path(args[i + 1])
        del args[i:i + 2]
        hints = json.loads(path.read_text()) if path.exists() else {}
    cars = hints.get("vehicles", {})
    body = Path(args[0]).read_text()

    read = field(body, "Co odczytała apka?")
    right = field(body, "Jaki to numer?")
    listed = field(body, "Numer(y) taborowe")
    if right:  # the misread form
        rows = [(n, "prawidłowy") for n in numbers(right)] + [(n, "odczyt") for n in numbers(read)]
        kinds = list(KINDS)
    elif listed:  # the vehicle form
        rows = [(n, "") for n in numbers(listed)]
        kind = field(body, "Autobus czy tramwaj?")
        kinds = ["TRAM"] if kind.startswith("Tramwaj") else ["BUS"] if kind.startswith("Autobus") else list(KINDS)
    else:
        print("not a misread or vehicle issue")
        return
    if not rows:
        print("no numbers in the form")
        return

    fleet = json.loads((ROOT / "Tabor/Resources/fleet.json").read_text())
    photo = Phototrans(fleet)
    # (kind, number) → "Konstal 105Ni, 1997, Tramwaje Warszawskie, Wola", retired ones marked.
    book = {}
    for key in ("models", "worksModels", "retiredModels"):
        for m in fleet.get(key, []):
            for retired, batches in ((key == "retiredModels", m.get("batches", [])), (True, m.get("retiredBatches", []))):
                for b in batches:
                    where = ", ".join(x for x in (b.get("operator"), b.get("depotName")) if x)
                    text = m["name"] + (f", {b['year']}" if b.get("year") else "") + (f", {where}" if where else "") + (" (wycofany)" if retired else "")
                    for n in b["numbers"]:
                        book[(m["kind"], n)] = text

    running = {}
    for kind, (_, _, t) in KINDS.items():
        try:
            req = urllib.request.Request(FEED.format(t), headers={"User-Agent": "tabor-issue-lookup"})
            feed = json.load(urllib.request.urlopen(req, timeout=30))["result"]
            top = max(datetime.fromisoformat(r["Time"]) for r in feed)
            for r in feed:
                if top - datetime.fromisoformat(r["Time"]) <= FRESH:
                    running[(kind, r["VehicleNumber"])] = r["Lines"]
        except Exception as e:
            print(f"couldn't read the {kind.lower()} feed: {e}", file=sys.stderr)

    def cell(parts):
        return " · ".join(p.replace("|", "/") for p in parts) or "–"

    lines = []
    for n, role in rows:
        # A kind counts if the vehicle form names it, or if we or czynaczas have the number as it.
        shown = [k for k in kinds if len(kinds) == 1 or (k, n) in book or cars.get(f"{KINDS[k][1]}/{n}")] or kinds
        many = len(shown) > 1
        icon = lambda k: f"{KINDS[k][0]} " if many else ""
        app = [f"{icon(k)}{book.get((k, n), 'brak')}" for k in shown]
        cz = [f"{icon(k)}{x}" for k in shown if (x := name(cars.get(f"{KINDS[k][1]}/{n}")))]
        live = [f"{icon(k)}{'linia ' + running[(k, str(n))] if (k, str(n)) in running else 'nie'}" for k in shown]
        links = [photo.link(k, n, f"phototrans {KINDS[k][0]}" if many else "phototrans") for k in shown]
        label = f"{n} ({role})" if role else str(n)
        lines.append(f"| {label} | {cell(app)} | {cell(cz)} | {cell(live)} | {' · '.join(links)} |")

    notes = []
    for n, _ in rows:
        if all((k, n) in book for k in KINDS):
            notes.append(f"{n} to numer i autobusu, i tramwaju, więc apka pyta „Który to?”, chyba że mapa rozstrzygnie.")
    if right and read:
        good, bad = numbers(right), numbers(read)
        if len(good) == 1 and len(bad) == 1 and good != bad:
            g, b = str(good[0]), str(bad[0])
            exists = any((k, bad[0]) in book for k in KINDS)
            if len(g) == len(b):
                off = sum(x != y for x, y in zip(g, b))
                fix = ("mapa mogła go poprawić, gdyby " + g + " jechał wtedy w pobliżu" if off == 1
                       else "mapa poprawia tylko jedną cyfrę")
                notes.append(f"{b} {'to prawdziwy numer' if exists else 'nie ma go w aplikacji'}, "
                             f"a różni się od {g} {WORDS.get(off, f'{off} cyframi')}: {fix}.")
            else:
                notes.append(f"{b} {'to prawdziwy numer' if exists else 'nie ma go w aplikacji'}, a ma inną liczbę cyfr niż {g}.")

    out = ["**Co mamy o tych numerach**", "",
           "| Numer | W aplikacji | czynaczas.pl | Teraz na mapie | Sprawdź |",
           "|---|---|---|---|---|", *lines, ""]
    out += [f"- {x}" for x in notes] + ([""] if notes else [])
    out.append("<sub>Sprawdzone automatycznie, gdy issue powstało. Nazwy modeli: [czynaczas.pl](https://czynaczas.pl).</sub>")
    text = "\n".join(out) + "\n"
    print(text)
    Path(args[1]).write_text(text)


if __name__ == "__main__":
    main()
