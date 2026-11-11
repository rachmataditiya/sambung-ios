#!/usr/bin/env python3
"""Adds Sambung's Indonesian strings to Localizable.xcstrings.

The translations live in scripts/sambung-id-<n>.json (catalog key -> Indonesian) and
scripts/sambung-id-labels.json (English config field label -> Indonesian). Run this again after
merging upstream: take upstream's catalog, then re-apply.
"""
import glob
import json
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
catalog_path = os.path.join(root, "Localizable.xcstrings")

with open(catalog_path, encoding="utf-8") as f:
    original = f.read()
catalog = json.loads(original)
strings = catalog["strings"]

def dump(value):
    # The layout Xcode writes, so the diff is only the added lines. Xcode spreads an empty
    # object over three lines.
    text = json.dumps(value, ensure_ascii=False, indent=2, separators=(",", " : "))
    return re.sub(r"^( *)(.*) : \{\}(,?)$", r"\1\2 : {\n\n\1}\3", text, flags=re.M)

if "--check-format" in sys.argv:
    sys.exit(0 if dump(catalog) == original.rstrip("\n") else 1)

def set_indonesian(entry, value):
    entry.setdefault("localizations", {})["id"] = {"stringUnit": {"state": "translated", "value": value}}

added, missing, by_english = 0, [], {}
for path in sorted(glob.glob(os.path.join(root, "scripts", "sambung-id-[0-9]*.json"))):
    with open(path, encoding="utf-8") as f:
        for key, value in json.load(f).items():
            by_english[key] = value
            entry = strings.get(key)
            if entry is None:
                # A string Sambung reworded in the source, or one upstream renamed.
                missing.append(key)
                entry = strings[key] = {}
            set_indonesian(entry, value)
            added += 1

# Config field labels have generated keys ("meshtastic.Config….label") and carry their English
# text as the "en" value, so they are matched by that text.
with open(os.path.join(root, "scripts", "sambung-id-labels.json"), encoding="utf-8") as f:
    by_english.update(json.load(f))
for key, entry in strings.items():
    if not key.endswith(".label"):
        continue
    english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    if english in by_english:
        set_indonesian(entry, by_english[english])
        added += 1

with open(catalog_path, "w", encoding="utf-8") as f:
    f.write(dump(catalog) + ("\n" if original.endswith("\n") else ""))

print(f"{added} Indonesian strings applied")
if missing:
    print(f"{len(missing)} keys were not in the catalog and were added (Sambung's own wording, or renamed upstream):")
    for key in missing:
        print("  " + key)
