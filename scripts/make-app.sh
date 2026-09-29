#!/bin/zsh
# Spind — Copyright (C) 2026 Christoph Lindl-Guk
# SPDX-License-Identifier: Apache-2.0

# Builds SpindApp in release mode and assembles dist/Spind.app
set -e
cd "$(dirname "$0")/.."

swift build -c release --product SpindApp
BIN=$(swift build -c release --product SpindApp --show-bin-path)

APP=dist/Spind.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/SpindApp" "$APP/Contents/MacOS/Spind"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "OK: $APP"
