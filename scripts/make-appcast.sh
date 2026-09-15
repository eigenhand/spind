#!/bin/bash
# Spind — Copyright (C) 2026 Christoph Lindl-Guk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program. If not, see <https://www.gnu.org/licenses/>.

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
