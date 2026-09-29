#!/bin/bash
# Spind — Copyright (C) 2026 Christoph Lindl-Guk
# SPDX-License-Identifier: Apache-2.0

# Builds dist/appcast.xml with signed entries for every DMG in dist/.
# The private EdDSA key lives in the keychain (generated once with
# Sparkle's generate_keys). Appcast and DMG belong together in the
# GitHub release; the app finds both through the SUFeedURL in its plist.
#
# On the first run the Sparkle tools are built from the SPM checkout that
# is already resolved (takes a minute, stays in .sparkle-tools/).
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS=.sparkle-tools/Build/Products/Release
if [ ! -x "$TOOLS/generate_appcast" ]; then
    CHECKOUT=.dmg-build/SourcePackages/checkouts/Sparkle
    if [ ! -d "$CHECKOUT" ]; then
        echo "✕ Sparkle-Checkout fehlt — einmal scripts/make-dmg.sh laufen lassen."
        exit 1
    fi
    echo "▸ Baue Sparkle-Werkzeuge …"
    ( cd "$CHECKOUT" && xcodebuild -project Sparkle.xcodeproj \
        -scheme generate_appcast -configuration Release \
        -derivedDataPath "$OLDPWD/.sparkle-tools" \
        CODE_SIGN_IDENTITY="-" MACOSX_DEPLOYMENT_TARGET=12.0 build ) \
        > /dev/null
fi

"$TOOLS/generate_appcast" dist/
echo "✓ dist/appcast.xml aktualisiert — zusammen mit der DMG ins Release hochladen."
