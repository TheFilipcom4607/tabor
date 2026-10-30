#!/usr/bin/env python3
"""Which of OpenRouter's decision models best tells MZA's wrap posts from the rest.

Asks every decision model the wraps bot's own question (possible_wraps.ask) about each post in
wrap_posts.json: 99 MZA posts labelled by hand, 14 wraps and the rest timetables, jobs, trials,
deliveries and parades, some of them close calls (a trial bus in its own paint, flags on every
bus on 1 August). Only the links and labels are in git (the articles are MZA's); the text is
fetched once into build/wrap-post-texts.json, so a post MZA edits later doesn't change the
result on this Mac.

A missed wrap costs a sticker nobody can get again and a bad hint one click, so the models are
ranked by how much noise they drop while keeping every wrap: at a threshold of half their
lowest odds for a wrap (some margin, as 14 wraps can't show every way of writing one), then by
AUC. Errors put a model last; the bot lists every post its model can't judge. With the top few
a post or two apart, look at "Lowest wrap" too: how far the hardest wrap sits above the bot's
threshold is what keeps a vaguely written wrap from being dropped.

First run, 2026-10-30, 26 models: Jev 1.14 came out on top. The sharper-looking ones (GPT-6
Luna, Mercury, drex-max, Microsoft decision-1, Perplexity) drop a little more noise but miss
the hardest wrap: the Misja Autobusiaki post (a kids' game on line Wakacje, run that summer by
the Autobusiaki-wrapped #5887, though the post never says so) at 0.00-0.04, where Jev gives it
0.29, and they give the Valentine's bus ("o pięknych pastelowych barwach") 0.23-0.32 to
Jev's 0.71. Every model takes the flags on every bus on 1 August for
decorations (0.9+). span-01, span-01-lite and classify-1 failed every call.

Answers are saved in build/decision-models.json, so a rerun only asks what's missing (a new
model, a new post). --budget stops before the day's key limit.

Usage:  python3 scripts/compare_decision_models.py [--models <id>...] [--budget 0.8]
"""
import argparse
import json
import statistics
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import possible_wraps as wraps

ROOT = wraps.ROOT
POSTS = ROOT / "scripts/wrap_posts.json"
CACHE = ROOT / "build/decision-models.json"
TEXTS = ROOT / "build/wrap-post-texts.json"
MODELS = "https://openrouter.ai/api/v1/models?output_modalities=decisions"


def decision_models():
    # "~…-latest" aliases and ":free" copies are models already on the list.
    models = json.loads(urllib.request.urlopen(MODELS, timeout=30).read())["data"]
    return sorted(m["id"] for m in models if not m["id"].startswith("~") and ":" not in m["id"])


def auc(wrap, other):
    """The chance that a wrap gets higher odds than another post (ties count half)."""
    return sum((w > o) + (w == o) / 2 for w in wrap for o in other) / (len(wrap) * len(other))


def score(answers, posts):
    wrap = [answers[p["url"]]["odds"] for p in posts if p["wrap"] and "odds" in answers.get(p["url"], {})]
    other = [answers[p["url"]]["odds"] for p in posts if not p["wrap"] and "odds" in answers.get(p["url"], {})]
    errors = sum("error" in answers.get(p["url"], {"error": "not asked"}) for p in posts)
    if not wrap or not other:
        return {"errors": errors}
    cut = min(wrap) / 2
    times = [a["seconds"] for a in answers.values() if "seconds" in a]
    return {
        "errors": errors,
        "dropped": sum(o < cut for o in other) / len(other),
        "lowest_wrap": min(wrap),
        "auc": auc(wrap, other),
        "missed_bot": sum(w < wraps.WRAP_ODDS for w in wrap),
        "dropped_bot": sum(o < wraps.WRAP_ODDS for o in other) / len(other),
        "cost_post": sum(a.get("cost", 0) for a in answers.values()) / len(answers),
        "seconds": statistics.median(times) if times else 0,
    }


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--models", nargs="+")
    args.add_argument("--budget", type=float, default=0.8, help="USD to spend at most in this run")
    args = args.parse_args()
    key = wraps.openrouter_key()
    if not key:
        sys.exit("no OpenRouter key (OPENROUTER_API_KEY, or the same in Config/Secrets.xcconfig)")
    posts = json.loads(POSTS.read_text())
    texts = json.loads(TEXTS.read_text()) if TEXTS.exists() else {}
    for p in posts:
        if p["url"] not in texts:
            texts[p["url"]] = wraps.post_text(p["url"])
        p["title"], p["text"] = texts[p["url"]]
    TEXTS.parent.mkdir(exist_ok=True)
    TEXTS.write_text(json.dumps(texts, ensure_ascii=False))
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    spent = 0.0

    for model in args.models or decision_models():
        answers = cache.setdefault(model, {})
        # Errors are asked again: they're often a busy provider.
        todo = [p for p in posts if "odds" not in answers.get(p["url"], {})]
        if not todo:
            continue
        if spent >= args.budget:
            print(f"budget spent, skipping {model}", file=sys.stderr)
            continue

        def one(post):
            start = time.monotonic()
            try:
                odds, cost = wraps.ask(post["title"], post["text"], key, model)
                return post["url"], {"odds": odds, "cost": cost, "seconds": time.monotonic() - start}
            except Exception as e:
                body = e.read().decode(errors="replace")[:200] if hasattr(e, "read") else ""
                return post["url"], {"error": f"{e} {body}".strip()}

        with ThreadPoolExecutor(8) as pool:
            for url, answer in pool.map(one, todo):
                answers[url] = answer
                spent += answer.get("cost", 0)
        CACHE.parent.mkdir(exist_ok=True)
        CACHE.write_text(json.dumps(cache, indent=1))
        s = score(answers, posts)
        print(f"{model}: {s.get('errors')} errors, AUC {s.get('auc', 0):.3f}, spent {spent:.4f} USD so far",
              file=sys.stderr)

    rows = sorted(((m, score(a, posts)) for m, a in cache.items()),
                  key=lambda r: (r[1]["errors"] > 0, -r[1].get("dropped", 0), -r[1].get("auc", 0)))
    print(f"\n{len(posts)} posts, {sum(p['wrap'] for p in posts)} wraps. 'Dropped' is the share of other "
          f"posts below half the lowest wrap's odds; 'at {wraps.WRAP_ODDS}' is the bot's threshold.\n")
    print("| Model | Errors | Dropped | Lowest wrap | AUC | Wraps missed at 0.1 | Dropped at 0.1 | USD/post | s |")
    print("|---|---|---|---|---|---|---|---|---|")
    for m, s in rows:
        if "auc" not in s:
            print(f"| {m} | {s['errors']} | | | | | | | |")
            continue
        print(f"| {m} | {s['errors']} | {s['dropped']:.0%} | {s['lowest_wrap']:.2f} | {s['auc']:.3f} | "
              f"{s['missed_bot']} | {s['dropped_bot']:.0%} | {s['cost_post']:.6f} | {s['seconds']:.2f} |")
    print(f"\nspent {spent:.4f} USD in this run", file=sys.stderr)


if __name__ == "__main__":
    main()
