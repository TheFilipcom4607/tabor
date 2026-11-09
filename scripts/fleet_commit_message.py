#!/usr/bin/env python3
"""Says in plain words what a rebuilt fleet.json changes, for the nightly refresh's commit
message and PR. It compares the files themselves, vehicle by vehicle, rather than the build's
log, so the bookkeeping behind the log ("51 from the city's list") never shows.

Usage:  python3 scripts/fleet_commit_message.py               # working copy against HEAD
        python3 scripts/fleet_commit_message.py <ref>         # ... or against another commit
        python3 scripts/fleet_commit_message.py <old> <new>   # two commits
        ... --subject                                         # just the subject line

Vehicle numbers go without "#": GitHub links "#12" to issue 12, and a pushed commit that
mentions it shows up on that issue.
"""
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from fetch_fleet import code_of, is_coded  # noqa: E402

FLEET = "Tabor/Resources/fleet.json"
CITY = "data/ztm-pojazdy.json"
SECTIONS = ("models", "worksModels", "codedWorksModels")
# Worked out from the vehicles, or shown per vehicle, so the model-level check skips them.
PER_VEHICLE = {"batches", "fleet", "firstYear", "lastYear", "operators", "specs", "variants",
               "liveries", "name"}
LIVERIES = {"suburbanBlue": "suburban blue", "oldYellowRed": "old yellow and red",
            "greyRed": "grey and red", None: "everyday paint"}
SPECS = {"length": "length", "drive": "drive", "seats": "seats", "places": "places",
         "airCon": "air-con", "floor": "floor"}
KEYS = {"namePl": "Polish name", "coupled": "coupling", "sets": "fixed sets", "pairs": "usual sets",
        "trailers": "trailers", "tows": "what it tows", "trial": "trial note", "trialPl": "trial note",
        "trialEnded": "trial end", "runs": "where it runs", "runsPl": "where it runs",
        "formerly": "former ids", "make": "make", "code": "model code", "coded": "codes"}


def load(ref, path):
    try:
        if ref is None:
            return json.loads((ROOT / path).read_text())
        return json.loads(subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT, check=True,
                                         capture_output=True, text=True).stdout)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def models(d):
    return [m for s in SECTIONS for m in d.get(s, [])]


def tier(m):
    if m.get("vintage"):
        return "VINTAGE"
    if m.get("onTest"):
        return "ON TEST"
    if m.get("works"):
        return "WORKS"
    f = m["fleet"]
    return "LEGENDARY" if f <= 12 else "GOLD" if f <= 48 else "RARE" if f <= 80 else "COMMON"


def regular(m):
    return not (m.get("vintage") or m.get("onTest") or m.get("works"))


def vehicles(d):
    """(kind, number, works?) -> what the book says about it. Works cars can share a number
    with a regular tram, so they're kept apart."""
    out = {}
    for m in models(d):
        works = bool(m.get("works"))
        liveries = m.get("liveries", {})
        variants = {n: v["specs"] for v in m.get("variants", []) for n in v["numbers"]}
        for b in m["batches"]:
            for n in b["numbers"]:
                out[(m["kind"], n, works)] = {
                    "id": m["id"], "name": m["name"],
                    "operator": b.get("operator", ""), "year built": b.get("year"),
                    "depot": " ".join(x for x in (b.get("depotCode"), b.get("depotName")) if x) or "none",
                    "paint": LIVERIES.get(liveries.get(str(n)), liveries.get(str(n))),
                    "specs": variants.get(n, m.get("specs") or {}),
                }
    return out


def label(n):
    return code_of(n) if is_coded(n) else str(n)


def numbers(kind, nums):
    """('BUS', [1, 2, 3, 7]) -> 'buses 1–3, 7'"""
    nums, runs = sorted(nums), []
    for n in nums:
        if runs and n == runs[-1][1] + 1 and not is_coded(n):
            runs[-1][1] = n
        else:
            runs.append([n, n])
    noun = kind.lower() + ("" if len(nums) == 1 else "es" if kind == "BUS" else "s")
    return noun + " " + ", ".join(f"{label(a)}–{label(b)}" if a != b else label(a) for a, b in runs)


def section(title, groups):
    """groups: {(kind, model, what): [numbers]} -> a titled list, or nothing. With nothing to
    say but the model, the model leads ("Otokar Vectio C (ReloBus): buses 9061, 9063–9066"),
    which reads better than a long run of numbers first."""
    if not groups:
        return []
    def row(kind, model, what, nums):
        if not what:
            return f"- {model}: {numbers(kind, nums)}"
        say = numbers(kind, nums)
        return f"- {say[0].upper()}{say[1:]}" + (f" ({model})" if model else "") + f": {what}"
    rows = sorted(groups.items(), key=lambda kv: (kv[0][0], min(kv[1])))
    return [title] + [row(*key, nums) for key, nums in rows] + [""]


def spec(field, value):
    if value is None:
        return "unknown"
    if field == "airCon":
        return "yes" if value else "no"
    if field == "length":
        return f"{value / 1000:g} m"
    if value in ("cng", "lng"):
        return value.upper()
    return str(value)


def spec_changes(a, b):
    return "; ".join(f"{SPECS.get(k, k)} {spec(k, a.get(k))} → {spec(k, b.get(k))}"
                     for k in sorted(a.keys() | b.keys()) if a.get(k) != b.get(k))


# What a subject says when every changed vehicle changed in the same way (one, several). Paint
# and specs say "new", not "repainted": the city's data changing doesn't mean the bus did.
VERBS = {"depot": ("{} moves depot", "{} move depot"), "operator": ("{} changes operator", "{} change operator"),
         "model": ("{} changes model", "{} change model"), "paint": ("new paint for {}",) * 2,
         "specs": ("new specs for {}",) * 2, "year built": ("new build year for {}",) * 2,
         None: ("changes to {}",) * 2}
SUBJECT_MAX = 72


def who(keys):
    """[('BUS', 9816)] -> 'bus 9816'; [('BUS', 1), ('BUS', 2)] -> '2 buses'"""
    if len(keys) == 1:
        kind, n = keys[0]
        return f"{kind.lower()} {label(n)}"
    kinds = {k for k, _ in keys}
    return f"{len(keys)} " + ("buses" if kinds == {"BUS"} else "trams" if kinds == {"TRAM"} else "vehicles")


def subject(parts, city_changed):
    """The gist, most important first, cut to fit a subject line."""
    if not parts:
        return "the city's list changes, the book doesn't" if city_changed else "nothing in the book changes"
    out = parts[0]
    for i, p in enumerate(parts[1:], 1):
        rest = "" if i == len(parts) - 1 else ", and more"
        if len(f"Fleet: {out}, {p}{rest} (YYYY-MM-DD)") > SUBJECT_MAX:
            return out + ", and more"
        out += f", {p}"
    return out


def message(old, new, old_city=None, new_city=None):
    """-> (the subject's gist, the body)"""
    ov, nv = vehicles(old), vehicles(new)
    added, gone, changed = defaultdict(list), defaultdict(list), defaultdict(list)
    # For the subject: (kind, number) and, for a changed vehicle, what kind of change.
    new_keys, gone_keys, changed_how = [], [], {}
    for key in nv.keys() - ov.keys():
        new_keys.append(key[:2])
        v = nv[key]
        about = ", ".join(str(x) for x in (v["operator"], v["year built"], v["depot"]) if x and x != "none")
        added[(key[0], v["name"] + (f" ({about})" if about else ""), "")].append(key[1])
    for key in ov.keys() - nv.keys():
        gone_keys.append(key[:2])
        v = ov[key]
        gone[(key[0], v["name"] + (f" ({v['operator']})" if v["operator"] else ""), "")].append(key[1])
    for key in nv.keys() & ov.keys():
        a, b = ov[key], nv[key]
        if a["id"] != b["id"]:
            # A split can give the new model the old one's name: then only the ids tell them apart.
            was, now = (a["name"], b["name"]) if a["name"] != b["name"] else (a["id"], b["id"])
            changed[(key[0], "", f"model {was} → {now}")].append(key[1])
            changed_how[key[:2]] = {"model"}
            continue
        fields = [f for f in ("depot", "operator", "year built", "paint") if a[f] != b[f]]
        what = [f"{f} {a[f]} → {b[f]}" for f in fields]
        if a["specs"] != b["specs"]:
            what.append(spec_changes(a["specs"], b["specs"]))
            fields.append("specs")
        if what:
            changed_how[key[:2]] = set(fields)
            changed[(key[0], b["name"], "; ".join(what))].append(key[1])

    lines = []
    lines += section("New in the book:", added)
    lines += section("Gone from the city's list, so out of the book:", gone)
    lines += section("Changed:", changed)

    om, nm = {m["id"]: m for m in models(old)}, {m["id"]: m for m in models(new)}
    fresh = [nm[i]["name"] for i in sorted(nm.keys() - om.keys())]
    gist = ([f"new model {fresh[0]}"] if len(fresh) == 1 else [f"{len(fresh)} new models"] if fresh else [])
    gist += [f"{nm[i]['name']} now {tier(nm[i])}" for i in sorted(nm.keys() & om.keys())
             if tier(nm[i]) != tier(om[i])]
    if new_keys:
        gist.append(f"new {who(new_keys)}" if len(new_keys) == 1 else f"{who(new_keys).replace(' ', ' new ', 1)}")
    if gone_keys:
        gist.append(f"{who(gone_keys)} gone")
    if changed_how:
        hows = set().union(*changed_how.values())
        verb = VERBS[hows.pop() if len(hows) == 1 else None][len(changed_how) > 1]
        gist.append(verb.format(who(sorted(changed_how))))
    gist += [f"{om[i]['name']} renamed" for i in sorted(nm.keys() & om.keys()) if om[i]["name"] != nm[i]["name"]]
    if new.get("wraps", []) != old.get("wraps", []):
        gist.append("event wraps change")
    notes = [f"New model: {nm[i]['name']} ({nm[i]['kind'].lower()}, {tier(nm[i])})."
             for i in sorted(nm.keys() - om.keys())]
    details = defaultdict(set)
    notes += [f"Model gone: {om[i]['name']} ({om[i]['kind'].lower()})." for i in sorted(om.keys() - nm.keys())]
    for i in sorted(nm.keys() & om.keys()):
        a, b = om[i], nm[i]
        if a["name"] != b["name"]:
            notes.append(f"Renamed: {a['name']} → {b['name']}.")
        if tier(a) != tier(b):
            sizes = f" ({a['fleet']} → {b['fleet']} vehicles)" if a["fleet"] != b["fleet"] else ""
            notes.append(f"{b['name']} moves from {tier(a)} to {tier(b)}{sizes}.")
        keys = {k for k in (a.keys() | b.keys()) - PER_VEHICLE - {"vintage", "onTest", "works"}
                if a.get(k) != b.get(k)}
        if keys:
            notes.append(f"{b['name']}: {', '.join(sorted({KEYS.get(k, k) for k in keys}))} changed.")
            details[b["name"]] |= {KEYS.get(k, k) for k in keys}
    if details:
        whats = set().union(*details.values())
        what = whats.pop() if len(whats) == 1 else "details"
        gist.append(f"new {what} for " + (next(iter(details)) if len(details) == 1 else f"{len(details)} models"))
    lines += notes + ([""] if notes else [])

    lines += wraps(old.get("wraps", []), new.get("wraps", []))
    lines += depots(old.get("depots", []), new.get("depots", []))
    skip = set(SECTIONS) | {"source", "sourcePl", "fetched", "wraps", "depots"}
    other = sorted(k for k in (new.keys() | old.keys()) - skip if new.get(k) != old.get(k))
    if other:
        lines += [f"Also changed: {', '.join(other)}.", ""]

    city = city_only(old_city, new_city, nv) if old_city and new_city else []
    lines += city

    if not lines:
        lines += ["Nothing in the book changes.", ""]
    elif not gist and not city:
        gist.append("other data changes")
    total = lambda d: sum(m["fleet"] for m in d["models"] if regular(m))
    if total(old) != total(new):
        lines.append(f"The fleet (what the fleet % counts) goes from {total(old)} to {total(new)} vehicles.")
    else:
        lines.append(f"The fleet (what the fleet % counts) stays at {total(new)} vehicles.")
    return subject(gist, bool(city)), "\n".join(lines)


def wraps(old, new):
    o, n = {w["id"]: w for w in old}, {w["id"]: w for w in new}
    say = lambda w: f"{w['name']}, {w['kind'].lower()} {w['number']}, {w['from']} to {w['to']}"
    out = [f"- Added: {say(n[i])}" for i in sorted(n.keys() - o.keys())]
    out += [f"- Removed: {say(o[i])}" for i in sorted(o.keys() - n.keys())]
    out += [f"- Changed: {say(n[i])}" for i in sorted(n.keys() & o.keys()) if n[i] != o[i]]
    return ["Event wraps:"] + out + [""] if out else []


def depots(old, new):
    key = lambda d: (d["kind"], " ".join(x for x in (d["code"], d["name"]) if x))
    o, n = {key(d) for d in old}, {key(d) for d in new}
    out = [f"New depot: {name} ({'buses' if kind == 'BUS' else 'trams'})."
           for kind, name in sorted(n - o)]
    out += [f"No vehicles left at depot {name}." for kind, name in sorted(o - n)]
    return out + [""] if out else []


def city_only(old, new, book):
    """Vehicles the city's list gained or dropped without the book following, so the diff of
    data/ztm-pojazdy.json doesn't go unexplained."""
    num = lambda v: int(v["number"]) if v["number"].isdigit() else None
    o = {(v["kind"], num(v)) for v in old["vehicles"] if num(v) is not None}
    n = {(v["kind"], num(v)) for v in new["vehicles"] if num(v) is not None}
    in_book = {(k, x) for k, x, works in book if not works}
    added, dropped = defaultdict(list), defaultdict(list)
    for k, x in n - o:
        if (k, x) in in_book:
            added[(k, "", "already in the book from the hand-kept lists")].append(x)
        else:
            added[(k, "", "not in the book (no model fits its type yet, or it's left out on purpose)")].append(x)
    # One the book drops shows above, under "Gone".
    for k, x in o - n:
        if (k, x) in in_book:
            dropped[(k, "", "kept in the book by the hand-kept lists")].append(x)
    return (section("New on the city's list, book unchanged:", added)
            + section("Dropped from the city's list, book unchanged:", dropped))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--subject"]
    old_ref = args[0] if args else "HEAD"
    new_ref = args[1] if len(args) > 1 else None
    gist, body = message(load(old_ref, FLEET), load(new_ref, FLEET), load(old_ref, CITY), load(new_ref, CITY))
    print(gist if "--subject" in sys.argv else body)
