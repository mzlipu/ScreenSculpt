#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build a distributable .dmg from a Release build.
#
# No Developer ID, no notarization — see docs. The app is ad-hoc signed, which
# is a kernel requirement on Apple silicon (an arm64 binary with no signature at
# all will not execute), not a Gatekeeper measure.
#
# Usage: scripts/make-dmg.sh [version]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(awk -F' = ' '/MARKETING_VERSION/{print $2; exit}' Config/Version.xcconfig | tr -d ' ')}"
BUILD_DIR="$ROOT/build"
STAGE="$BUILD_DIR/dmg-stage"
DMG="$BUILD_DIR/ScreenSculpt-$VERSION.dmg"
VOLNAME="ScreenSculpt"

echo "==> Building ScreenSculpt $VERSION (Release, universal)"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
xcodegen generate

xcodebuild build \
  -project ScreenSculpt.xcodeproj \
  -scheme ScreenSculpt \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" \
  > "$BUILD_DIR/xcodebuild.log" 2>&1 || { tail -40 "$BUILD_DIR/xcodebuild.log"; exit 1; }

PRODUCTS="$(xcodebuild -project ScreenSculpt.xcodeproj -scheme ScreenSculpt \
             -configuration Release -showBuildSettings 2>/dev/null \
             | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')"
APP="$PRODUCTS/ScreenSculpt.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

echo "==> Verifying universal binary"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/ScreenSculpt")"
echo "    archs: $ARCHS"
# A single-arch Release ships silently and only Intel users find out.
grep -q x86_64 <<< "$ARCHS" || { echo "FATAL: missing x86_64"; exit 1; }
grep -q arm64  <<< "$ARCHS" || { echo "FATAL: missing arm64";  exit 1; }

echo "==> Ad-hoc signing"
# Strip extended attributes first: a stray one makes codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP"
find "$APP" -name '.DS_Store' -delete
# --deep is acceptable here only because there are no entitlements to
# mis-propagate. With a real identity it would be wrong.
codesign --force --sign - --deep "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# --norsrc --noextattr: a stray xattr inside the image breaks the signature.
ditto --norsrc --noextattr "$APP" "$STAGE/ScreenSculpt.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
ScreenSculpt
============

1. Drag ScreenSculpt.app onto the Applications folder.

2. The FIRST time you open it, macOS will say:

       "ScreenSculpt is damaged and can't be opened."

   It is not damaged. ScreenSculpt is not signed with a paid Apple
   certificate ($99/year), and macOS shows that message for any unsigned
   app downloaded through a browser.

   To open it:
     - Go to System Settings > Privacy & Security
     - Scroll down to Security
     - Next to "ScreenSculpt was blocked", click "Open Anyway"
     - Authenticate, then open ScreenSculpt again

   You only need to do this once per version.

   To avoid the message entirely next time, install with:
     curl -fsSL <download-url> -o /tmp/ss.dmg && \
       hdiutil attach -nobrowse -quiet /tmp/ss.dmg && \
       cp -R "/Volumes/ScreenSculpt/ScreenSculpt.app" /Applications/

   (curl does not mark downloads as quarantined; browsers do.)

3. ScreenSculpt lives in the MENU BAR, not the Dock. Look for the
   viewfinder icon at the top-right of your screen. It has no main window.

4. On your first capture, macOS will ask for Screen Recording permission.
   This is unavoidable: macOS gates all screen pixels behind it.

   NOTE: because the app is unsigned, this permission RESETS every time you
   install a new version. ScreenSculpt will detect that and tell you how to
   re-grant it.

Shortcuts
---------
   Control-Shift-Command-4    Capture an area
   Control-Shift-Command-3    Capture the whole screen
   Control-Shift-Command-5    Capture the active window

Screenshots are saved to ~/Pictures/Screenshots and copied to the clipboard.
TXT

echo "==> Building disk image"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format ULFO \
  -ov "$DMG" \
  > /dev/null

rm -rf "$STAGE"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA" > "$DMG.sha256"

echo
echo "==> Done"
echo "    $DMG"
echo "    $(du -h "$DMG" | cut -f1)"
echo "    sha256: $SHA"
echo
echo "    Since there is no notarization ticket, that checksum is the only"
echo "    integrity signal users have. Publish it alongside the download."
