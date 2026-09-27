#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copy a built disk image into the apps site and write its release metadata.
#
# The metadata is derived from the file itself — never typed — because the one
# thing that went wrong before was a hand-copied checksum describing a
# different build. Version, size and SHA-256 are all read off the bytes being
# published, in the same step that copies them.
#
# Usage: scripts/publish-to-site.sh [version] [--force]
#   SITE_DIR=/path/to/site   override where the site lives

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FORCE=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) VERSION="$arg" ;;
  esac
done

# Anchored, for the same reason make-dmg.sh anchors it: the comment block in
# Version.xcconfig also contains the string MARKETING_VERSION.
VERSION="${VERSION:-$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Version.xcconfig | tr -d ' ')}"
[ -n "$VERSION" ] || { echo "could not determine version"; exit 1; }

SITE_DIR="${SITE_DIR:-$ROOT/../Apps_Portfolio_Site}"
[ -d "$SITE_DIR/src/data" ] || {
  echo "No site at $SITE_DIR"
  echo "Set SITE_DIR=/path/to/Apps_Portfolio_Site and try again."
  exit 1
}
SITE_DIR="$(cd "$SITE_DIR" && pwd)"

DMG="$ROOT/build/ScreenSculpt-$VERSION.dmg"
[ -f "$DMG" ] || { echo "No disk image at $DMG — run 'make dmg' first."; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
BYTES="$(stat -f%z "$DMG")"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DATE="$(date '+%-d %B %Y')"
FILE="ScreenSculpt-$VERSION.dmg"
JSON="$SITE_DIR/src/data/release.json"

# Republishing a version with different bytes is the exact failure this whole
# script exists to prevent: anyone who downloaded the old one has a file that
# no longer matches the published checksum, and no way to tell.
if [ -f "$JSON" ]; then
  OLD_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' "$JSON")"
  OLD_SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sha256",""))' "$JSON")"
  if [ "$OLD_VERSION" = "$VERSION" ] && [ "$OLD_SHA" != "$SHA" ] && [ "$FORCE" -eq 0 ]; then
    echo
    echo "  Refusing to publish."
    echo
    echo "  Version $VERSION is already published, with different contents:"
    echo "      published  $OLD_SHA"
    echo "      this build $SHA"
    echo
    echo "  Bump the version instead — 'make release VERSION=x.y.z' — so the two"
    echo "  builds are distinguishable. Use --force only if the published one"
    echo "  never reached anyone."
    echo
    exit 1
  fi
fi

if ! git diff --quiet HEAD 2>/dev/null; then
  echo "  Warning: the working tree has uncommitted changes, so build $BUILD"
  echo "  (the commit count) does not describe what is in this disk image."
  echo
fi

mkdir -p "$SITE_DIR/public/downloads"
# Remove earlier images first: a leftover is how the wrong file gets served.
find "$SITE_DIR/public/downloads" -name '*.dmg' -not -name "$FILE" -print -delete | sed 's/^/  removed /'
cp "$DMG" "$SITE_DIR/public/downloads/$FILE"

python3 - "$JSON" "$VERSION" "$BUILD" "$DATE" "$FILE" "$BYTES" "$SHA" <<'PY'
import json, sys
path, version, build, date, file, byte_count, sha = sys.argv[1:8]
# Decimal megabytes, matching what Finder shows the person downloading it.
size = f"{int(byte_count) / 1e6:.1f} MB"
data = {
    "version": version,
    "build": int(build),
    "date": date,
    "file": file,
    "url": f"/downloads/{file}",
    "size": size,
    "sha256": sha,
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"  wrote {path}")
PY

echo "  copied $FILE into $SITE_DIR/public/downloads"
echo
( cd "$SITE_DIR" && npm run --silent check )
echo
echo "==> Published $VERSION (build $BUILD) to the site"
echo "    Next:  cd $SITE_DIR && npm run dev     # check it locally"
echo "           git add -A && git commit && git push   # deploy"
