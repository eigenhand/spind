#!/usr/bin/env python3
"""Every German sentence in the interface needs an English one.

Xcode enters new strings into the catalogue by itself while building —
untranslated. Nobody notices as long as the device is set to German: the app
runs, the tests run, and the English version has quietly gained one more German
line. This run turns that into a failure.
"""
import json, pathlib, sys

fail = 0
for path in sorted(pathlib.Path(".").rglob("*.xcstrings")):
    if "build" in path.parts:
        continue
    cat = json.loads(path.read_text())
    source = cat.get("sourceLanguage", "de")
    gaps = []
    for key, entry in sorted(cat.get("strings", {}).items()):
        loc = entry.get("localizations", {})
        unit = loc.get("en", {}).get("stringUnit", {})
        if source == "en":
            continue
        # An empty key needs no translation. Xcode enters it whenever a Text("")
        # stands somewhere — a placeholder, not a sentence.
        if not key:
            continue
        if unit.get("state") != "translated" or not unit.get("value", "").strip():
            gaps.append(key)
    print(f"{path}: {len(cat.get('strings', {}))} Strings, {len(gaps)} without English")
    for key in gaps:
        print(f"    missing: {key[:90]}")
    fail += len(gaps)

if fail:
    print(f"\n{fail} strings without an English version.", file=sys.stderr)
    sys.exit(1)
print("\nComplete.")
