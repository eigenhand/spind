#!/bin/bash
# Spind — Copyright (C) 2026 Christoph Lindl-Guk
# SPDX-License-Identifier: Apache-2.0

# Builds a distributable Spind DMG.
#
#   scripts/make-dmg.sh
#
# Three levels, depending on what is set up:
#
#   1. Without a "Developer ID Application" certificate: a developer
#      signature. Fine for testing locally — Gatekeeper complains about
#      anything downloaded.
#   2. With a certificate: signed with the hardened runtime and
#      distributable, but Gatekeeper still warns on first open.
#   3. With a certificate and the notary profile "spind-notary":
#      notarised and stapled — opens anywhere without a warning.
#      Create the profile once with xcrun notarytool store-credentials
#      spind-notary (it asks for an app-specific password).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=.dmg-build
APP="$BUILD_DIR/Build/Products/Release/Spind.app"
NOTARY_PROFILE=spind-notary

echo "▸ Baue Release …"
xcodegen generate >/dev/null
# A release DMG must not come out of a beta toolchain: it would carry
# beta Swift runtime libraries to people running a released macOS.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p)" == *[Bb]eta* ]]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        echo "▸ The active Xcode is a beta — building with the release Xcode."
    else
        echo "✕ Only an Xcode beta is installed. Building a release with it"
        echo "  would mean shipping beta runtime libraries to users."
        exit 1
    fi
fi

# Same timestamp scheme as the iPhone side. Sparkle offers an update only
# when CFBundleVersion has grown, so a fixed number would reach nobody.
BUILD=$(date +%Y%m%d%H%M)
echo "▸ Build-Nummer $BUILD"

xcodebuild -project Spind.xcodeproj -scheme Spind -configuration Release \
    -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates build \
    CURRENT_PROJECT_VERSION="$BUILD" \
    | grep -E "error:|warning: Sign" || true
test -d "$APP" || { echo "✕ Build fehlgeschlagen"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Spind-$VERSION.dmg"
mkdir -p dist

# ── Signing ──────────────────────────────────────────────────────────────
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" \
    | sed -E 's/^[^"]*"([^"]+)".*$/\1/' || true)

if [ -n "$DEV_ID" ]; then
    echo "▸ Signiere mit: $DEV_ID"
    TEAM_ID=$(grep -m1 '^SPIND_TEAM_ID' Config.xcconfig | sed 's/.*= *//')
    APP_GROUP=$(grep -m1 '^SPIND_APP_GROUP' Config.xcconfig | sed 's/.*= *//' \
        | sed "s/\$(SPIND_TEAM_ID)/$TEAM_ID/")

    # Distribution entitlements: without keychain-access-groups (that was
    # only the trick to force provisioning profiles under the free team —
    # with a Developer ID the signature fails on the missing profile).
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
    # Embedded development profiles out — they do not belong in a release.
    rm -f "$APP/Contents/embedded.provisionprofile" \
          "$APP"/Contents/PlugIns/*.appex/Contents/embedded.provisionprofile
    # Sign from the inside out — including the Swift runtime libraries
    # Xcode embeds, or notarisation refuses the package ("binary is not
    # signed with a valid Developer ID certificate"). Sparkle brings its
    # own XPC services and an updater; those have to be signed BEFORE
    # their framework.
    find "$APP" \( -name "*.xpc" -o -name "Autoupdate" -o -name "Updater.app" \) -print0 \
        | while IFS= read -r -d '' nested; do
            codesign --force --options runtime --timestamp \
                --sign "$DEV_ID" "$nested"
        done
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
    echo "✓ Signature verified"

    # ── Notarise (the app first, so it is stapled itself) ────────────────
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "▸ Notarisiere App (kann einige Minuten dauern) …"
        ZIP=$(mktemp -d)/Spind.zip
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
    else
        echo "⚠ No notary profile \"$NOTARY_PROFILE\" — the DMG will be signed"
        echo "  but not notarised (Gatekeeper warns on first opening)."
    fi
else
    echo "⚠ Kein »Developer ID Application«-Zertifikat gefunden."
    echo "  The DMG carries only the developer signature — fine for local"
    echo "  testing, not for distribution. To create a certificate: Xcode →"
    echo "  Settings → Accounts → pick the team → Manage Certificates → +"
fi

# ── Build the DMG ────────────────────────────────────────────────────────
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
        echo "✓ Notarised and stapled — opens anywhere without a warning."
    fi
fi

echo "✓ Fertig: $DMG ($(du -h "$DMG" | cut -f1))"

# ── Appcast for automatic updates ────────────────────────────────────────
if [ -n "$DEV_ID" ]; then
    scripts/make-appcast.sh || echo "⚠ Appcast not generated — run scripts/make-appcast.sh later."
fi
