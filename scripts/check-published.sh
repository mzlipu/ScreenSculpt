#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Is the site serving the disk image this repo currently builds?
#
# Compares bytes, not version numbers. A version number that did not move while
# the contents did is precisely how the site came to serve a nine-day-old build
# while every visible signal agreed it was current.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SITE_DIR="${SITE_DIR:-$ROOT/../Apps_Portfolio_Site}"
JSON="$SITE_DIR/src/data/release.json"

VERSION="$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Version.xcconfig | tr -d ' ')"
DMG="$ROOT/build/ScreenSculpt-$VERSION.dmg"

echo "  this repo:  version $VERSION, build $(git rev-list --count HEAD 2>/dev/null || echo '?')"
if [ -f "$DMG" ]; then
  LOCAL_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
  echo "              built $(date -r "$DMG" '+%-d %b %Y %H:%M'), sha ${LOCAL_SHA:0:16}…"
else
  LOCAL_SHA=""
  echo "              no disk image built yet (run 'make dmg')"
fi

if [ ! -f "$JSON" ]; then
  echo "  the site:   nothing published yet"
  exit 1
fi
SITE_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$JSON")"
SITE_BUILD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"])' "$JSON")"
SITE_FILE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["file"])' "$JSON")"
SITE_SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha256"])' "$JSON")"
SITE_DMG="$SITE_DIR/public/downloads/$SITE_FILE"

echo "  the site:   version $SITE_VERSION, build $SITE_BUILD"
if [ -f "$SITE_DMG" ]; then
  echo "              copied $(date -r "$SITE_DMG" '+%-d %b %Y %H:%M'), sha $(shasum -a 256 "$SITE_DMG" | cut -c1-16)…"
else
  echo "              !! $SITE_FILE is missing from public/downloads"
  exit 1
fi
echo

if [ -z "$LOCAL_SHA" ]; then
  echo "  Cannot compare without a local build. Run 'make dmg'."
  exit 1
elif [ "$LOCAL_SHA" = "$SITE_SHA" ]; then
  echo "  In sync — the site serves exactly what this repo builds."
else
  echo "  OUT OF DATE — the site is serving different bytes from this build."
  echo "  Run 'make release VERSION=x.y.z' to build and publish together."
  exit 1
fi
