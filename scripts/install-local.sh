#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Install an already-built disk image into /Applications.
#
# Takes the bytes as they are and never rebuilds. Rebuilding would produce a
# different binary from the one published for the same version, so the copy
# you then test would not be the copy anyone downloads.
#
# Usage: scripts/install-local.sh [version]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Version.xcconfig | tr -d ' ')}"
DMG="build/ScreenSculpt-$VERSION.dmg"
[ -f "$DMG" ] || { echo "No disk image at $DMG — run 'make dmg' first."; exit 1; }

pkill -x ScreenSculpt 2>/dev/null || true
sleep 1
hdiutil attach -nobrowse -quiet "$DMG" -mountpoint /tmp/ssmount
rm -rf /Applications/ScreenSculpt.app
cp -R /tmp/ssmount/ScreenSculpt.app /Applications/
hdiutil detach -quiet /tmp/ssmount

# Remove every other copy of the bundle. macOS records a permission grant
# against one *copy* of an app, so a second bundle with the same identifier
# gets its own entry — and the Privacy list shows both as plain
# "ScreenSculpt" with no path. Granting Screen Recording to the wrong one is
# indistinguishable from granting it to the right one and being ignored.
# Xcode recreates these on the next build; nothing is lost.
rm -rf build/*/ScreenSculpt.app 2>/dev/null || true
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/ScreenSculpt-*/Build/Products/*/ScreenSculpt.app 2>/dev/null || true

echo "installed $VERSION (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  /Applications/ScreenSculpt.app/Contents/Info.plist)) to /Applications"
open /Applications/ScreenSculpt.app
