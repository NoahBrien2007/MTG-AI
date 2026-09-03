#!/usr/bin/env python3
"""Extract the cards used by the deck lists into a compact JSON database.

The raw MTGJSON cards.csv is ~150 MB and far too slow to parse inside Godot at
start-up. This script scans it once and writes data/cards/cards.json containing
only the cards referenced by data/decks/*.txt (plus any extra names passed on
the command line). Re-run it whenever you add a deck or a card:

    python tools/extract_cards.py            # all decks
    python tools/extract_cards.py "Lightning Bolt" "Counterspell"
"""
import csv
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV_PATH = os.path.join(ROOT, "data", "raw", "cards.csv", "cards.csv")
DECK_GLOB = os.path.join(ROOT, "data", "decks", "*.txt")
OUT_PATH = os.path.join(ROOT, "data", "cards", "cards.json")

FIELDS = ["name", "manaCost", "manaValue", "type", "types", "subtypes", "supertypes",
          "colors", "colorIdentity", "keywords", "power", "toughness", "text",
          "producedMana", "layout", "setCode"]


def deck_card_names():
    names = set()
    for path in glob.glob(DECK_GLOB):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("//") or line.startswith("#"):
                    continue
                parts = line.split(" ", 1)
                if len(parts) == 2 and parts[0].isdigit():
                    names.add(parts[1].strip())
    return names


def main():
    wanted = deck_card_names() | set(sys.argv[1:])
    existing = {}
    if os.path.exists(OUT_PATH):
        with open(OUT_PATH, encoding="utf-8") as f:
            existing = {c["name"]: c for c in json.load(f)["cards"]}
    missing = {n for n in wanted if n not in existing}
    if not missing:
        print("cards.json already contains every deck card (%d)." % len(existing))
        return

    csv.field_size_limit(10**9)
    found = {}
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            name = row["name"]
            if name in missing and name not in found:
                if row.get("language", "English") != "English" or row.get("side", "") not in ("", "a"):
                    continue
                found[name] = {k: row.get(k, "") for k in FIELDS}
                if len(found) == len(missing):
                    break

    for name in sorted(missing - set(found)):
        print("WARNING: not found in cards.csv:", name)

    existing.update(found)
    cards = [existing[n] for n in sorted(existing)]
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump({"cards": cards}, f, indent=1, ensure_ascii=False)
    print("Wrote %d cards to %s (%d new)." % (len(cards), OUT_PATH, len(found)))


if __name__ == "__main__":
    main()
