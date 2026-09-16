#!/usr/bin/env python3
"""Jeder deutsche Satz in der Oberflaeche braucht einen englischen.

Xcode traegt neue Strings beim Bauen von selbst in den Katalog ein — ohne
Uebersetzung. Das faellt niemandem auf, solange das Geraet auf Deutsch steht:
Die App laeuft, die Tests laufen, und die englische Fassung hat still eine
deutsche Zeile mehr. Dieser Lauf macht daraus einen Fehlschlag.
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
        # Ein leerer Schluessel braucht keine Uebersetzung. Xcode traegt ihn ein,
        # wenn irgendwo ein Text("") steht — ein Platzhalter, kein Satz.
        if not key:
            continue
        if unit.get("state") != "translated" or not unit.get("value", "").strip():
            gaps.append(key)
    print(f"{path}: {len(cat.get('strings', {}))} Strings, {len(gaps)} ohne Englisch")
    for key in gaps:
        print(f"    fehlt: {key[:90]}")
    fail += len(gaps)

if fail:
    print(f"\n{fail} Strings ohne englische Fassung.", file=sys.stderr)
    sys.exit(1)
print("\nVollstaendig.")
