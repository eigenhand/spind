#!/bin/bash
# Spind — Copyright (C) 2026 eigenhand
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

# Baut eine verteilbare Spind-DMG.
#
#   scripts/make-dmg.sh
#
# Drei Ausbaustufen, je nachdem was eingerichtet ist:
#
#   1. Ohne „Developer ID Application"-Zertifikat: Entwickler-Signatur.
#      Gut zum lokalen Testen — bei Downloads meckert Gatekeeper.
#   2. Mit Zertifikat: signiert mit Hardened Runtime, verteilbar,
#      aber Gatekeeper zeigt beim ersten Öffnen noch eine Warnung.
#   3. Mit Zertifikat + Notary-Profil „spind-notary": notarisiert und
#      gestapelt — öffnet überall ohne Warnung. Profil einmalig anlegen:
#        xcrun notarytool store-credentials spind-notary \
#          --apple-id <deine-apple-id> --team-id <deine-team-id>
#      (fragt nach einem app-spezifischen Passwort von account.apple.com)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=.dmg-build
APP="$BUILD_DIR/Build/Products/Release/Spind.app"
NOTARY_PROFILE=spind-notary

echo "▸ Baue Release …"
xcodegen generate >/dev/null
xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates build \
    | grep -E "error:|warning: Sign" || true
test -d "$APP" || { echo "✕ Build fehlgeschlagen"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Spind-$VERSION.dmg"
mkdir -p dist

# ── Signieren ────────────────────────────────────────────────────────────
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -E 's/^[^"]*"([^"]+)".*$/\1/' || true)

if [ -n "$DEV_ID" ]; then
    echo "▸ Signiere mit: $DEV_ID"
    TEAM_ID=$(grep -m1 '^SPIND_TEAM_ID' Config.xcconfig | sed 's/.*= *//')
    APP_GROUP=$(grep -m1 '^SPIND_APP_GROUP' Config.xcconfig | sed 's/.*= *//' \
        | sed "s/\$(SPIND_TEAM_ID)/$TEAM_ID/")

    # Verteil-Entitlements: ohne keychain-access-groups (das war nur der
    # Trick, um unter dem Gratis-Team Provisioning-Profile zu erzwingen —
    # mit Developer ID scheitert die Signatur sonst am fehlenden Profil).
    ENT_DIR=$(mktemp -d)
    cat > "$ENT_DIR/app.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array><string>$APP_GROUP</string></array>
</dict>
</plist>
EOF
    cat > "$ENT_DIR/ext.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array><string>$APP_GROUP</string></array>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF
    # Eingebettete Dev-Profile raus — sie gehören nicht in eine Verteilung.
    rm -f "$APP/Contents/embedded.provisionprofile" \
          "$APP"/Contents/PlugIns/*.appex/Contents/embedded.provisionprofile
    # Von innen nach außen signieren — auch die von Xcode eingebetteten
    # Swift-Laufzeitbibliotheken, sonst lehnt die Notarisierung ab
    # ("binary is not signed with a valid Developer ID certificate").
    find "$APP" \( -name "*.dylib" -o -name "*.framework" \) -print0 \
        | while IFS= read -r -d '' nested; do
            codesign --force --options runtime --timestamp \
                --sign "$DEV_ID" "$nested"
        done
    codesign --force --options runtime --timestamp \
        --entitlements "$ENT_DIR/ext.entitlements" --sign "$DEV_ID" \
        "$APP/Contents/PlugIns/SpindFileProvider.appex"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENT_DIR/app.entitlements" --sign "$DEV_ID" \
        "$APP"
    codesign --verify --strict --deep "$APP"
    echo "✓ Signatur geprüft"

    # ── Notarisieren (App zuerst, damit sie selbst gestapelt ist) ────────
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "▸ Notarisiere App (kann einige Minuten dauern) …"
        ZIP=$(mktemp -d)/Spind.zip
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
    else
        echo "⚠ Kein Notary-Profil »$NOTARY_PROFILE« — DMG wird signiert,"
        echo "  aber nicht notarisiert (Gatekeeper warnt beim ersten Öffnen)."
    fi
else
    echo "⚠ Kein »Developer ID Application«-Zertifikat gefunden."
    echo "  Die DMG trägt nur die Entwickler-Signatur — gut zum lokalen"
    echo "  Testen, nicht zum Verteilen. Zertifikat anlegen: Xcode →"
    echo "  Settings → Accounts → Team wählen → Manage Certificates → +"
fi

# ── DMG bauen ────────────────────────────────────────────────────────────
echo "▸ Baue $DMG …"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Spind" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

if [ -n "$DEV_ID" ]; then
    codesign --force --timestamp --sign "$DEV_ID" "$DMG"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "▸ Notarisiere DMG …"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "✓ Notarisiert und gestapelt — öffnet überall ohne Warnung."
    fi
fi

echo "✓ Fertig: $DMG ($(du -h "$DMG" | cut -f1))"
