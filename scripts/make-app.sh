#!/bin/zsh
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
