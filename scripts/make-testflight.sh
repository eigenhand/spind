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

# Builds the iPhone app as an archive and uploads it to App Store
# Connect (TestFlight).
#
#   scripts/make-testflight.sh            # build the archive and upload
#   scripts/make-testflight.sh --archive  # build the archive only
#
# One-time prerequisites (only you can do these):
#   1. Open appstoreconnect.apple.com and accept the agreements.
#   2. There, under "Apps" → "+", create a new app:
#      platform iOS, name Spind, bundle ID dev.eigenhand.spind.ios.
#   3. For a run without an Xcode window: create an API key (App Store
#      Connect → Users and Access → Integrations → App Store Connect
#      API → "+", role App Manager), put the .p8 file into
#      ~/.appstoreconnect/private_keys/ and enter it in Config.xcconfig:
#
#        SPIND_ASC_KEY_ID = ABC123XYZ
#        SPIND_ASC_ISSUER_ID = 12345678-…
#      (xcodebuild cannot use the Apple ID session of the Xcode window —
#      without an API key, archive in Xcode instead: scheme SpindMobile,
#      destination "Any iOS Device", Product → Archive.)
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
        echo "▸ The active Xcode is a beta — TestFlight will not take that."
        echo "  Baue mit $(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo Xcode.app)"
    else
        echo "✕ The active Xcode is a beta and there is no release Xcode beside it."
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
    echo "▸ Signing in with App Store Connect API key $KEY_ID"
fi

# The build number is a timestamp, the way the other apps do it. Hand
# counted numbers collide the moment two uploads happen on one day, and
# App Store Connect then rejects the second — this always grows.
BUILD=$(date +%Y%m%d%H%M)

echo "▸ Building archive (device), build $BUILD …"
xcodegen generate >/dev/null
xcodebuild archive \
    -project Spind.xcodeproj -scheme SpindMobile \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    CURRENT_PROJECT_VERSION="$BUILD" \
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
	<false/>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ARCHIVE-export.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
echo "✓ Build $BUILD hochgeladen — in App Store Connect unter TestFlight"
echo "  erscheint er nach der Verarbeitung (einige Minuten). Interne Tester"
echo "  bekommen ihn dann von selbst."
