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

# Baut die iPhone-App als Archiv und lädt sie zu App Store Connect
# (TestFlight) hoch.
#
#   scripts/make-testflight.sh            # Archiv bauen + hochladen
#   scripts/make-testflight.sh --archive  # nur Archiv bauen
#
# Einmalige Voraussetzungen (nur du kannst das):
#   1. appstoreconnect.apple.com öffnen und die Vereinbarungen annehmen.
#   2. Dort unter „Apps" → „+" eine neue App anlegen:
#      Plattform iOS, Name Spind, Bundle-ID dev.eigenhand.spind.ios.
#   3. Für den Lauf ohne Xcode-Fenster: einen API-Schlüssel anlegen
#      (App Store Connect → Benutzer und Zugriff → Integrationen →
#      App-Store-Connect-API → „+", Rolle App-Manager), die .p8-Datei
#      nach ~/.appstoreconnect/private_keys/ legen und in Config.xcconfig
#      eintragen:
#        SPIND_ASC_KEY_ID = ABC123XYZ
#        SPIND_ASC_ISSUER_ID = 12345678-…
#      (xcodebuild kann die Apple-ID-Sitzung des Xcode-Fensters nicht
#      nutzen — ohne API-Schlüssel stattdessen in Xcode archivieren:
#      Scheme SpindMobile, Ziel „Any iOS Device", Product → Archive.)
set -euo pipefail
cd "$(dirname "$0")/.."

# App Store Connect refuses anything built with a beta Xcode ("Unsupported
# SDK or Xcode version"). The archive builds fine and only the upload is
# rejected, which costs a full build to find out — so pick the release
# Xcode here when the active one is a beta.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p)" == *[Bb]eta* ]]; then
    RELEASE_XCODE=/Applications/Xcode.app/Contents/Developer
    if [ -d "$RELEASE_XCODE" ]; then
        export DEVELOPER_DIR="$RELEASE_XCODE"
        echo "▸ Aktives Xcode ist eine Beta — TestFlight nimmt das nicht."
        echo "  Baue mit $(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo Xcode.app)"
    else
        echo "✕ Aktives Xcode ist eine Beta und daneben liegt kein Release-Xcode."
        echo "  App Store Connect lehnt Beta-Builds ab — Xcode aus dem App Store"
        echo "  installieren oder DEVELOPER_DIR auf ein Release-Xcode setzen."
        exit 1
    fi
fi

ARCHIVE=.dmg-build/Spind-iOS.xcarchive
EXPORT=.dmg-build/testflight

AUTH_ARGS=()
KEY_ID=$(grep -m1 '^SPIND_ASC_KEY_ID' Config.xcconfig 2>/dev/null | sed 's/.*= *//' || true)
ISSUER_ID=$(grep -m1 '^SPIND_ASC_ISSUER_ID' Config.xcconfig 2>/dev/null | sed 's/.*= *//' || true)
if [ -n "$KEY_ID" ] && [ -n "$ISSUER_ID" ]; then
    KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
    test -f "$KEY_FILE" || { echo "✕ $KEY_FILE fehlt"; exit 1; }
    AUTH_ARGS=(-authenticationKeyPath "$KEY_FILE"
               -authenticationKeyID "$KEY_ID"
               -authenticationKeyIssuerID "$ISSUER_ID")
    echo "▸ Anmeldung über App-Store-Connect-API-Schlüssel $KEY_ID"
fi

echo "▸ Baue Archiv (Gerät) …"
xcodegen generate >/dev/null
xcodebuild archive \
    -project Spind.xcodeproj -scheme SpindMobile \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    | grep -E "error:|BUILD|ARCHIVE" || true
test -d "$ARCHIVE" || { echo "✕ Archiv fehlgeschlagen"; exit 1; }
echo "✓ Archiv: $ARCHIVE"

if [ "${1:-}" = "--archive" ]; then exit 0; fi

echo "▸ Lade zu App Store Connect hoch …"
cat > "$ARCHIVE-export.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<true/>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ARCHIVE-export.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
echo "✓ Hochgeladen — in App Store Connect unter TestFlight erscheint der"
echo "  Build nach der Verarbeitung (einige Minuten). Dich selbst als"
echo "  internen Tester hinzufügen, TestFlight-App aufs iPhone, fertig."
