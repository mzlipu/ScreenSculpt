#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Cut a release: set the version, build the disk image, publish it to the site.
#
# One command, because the previous arrangement had three — bump, build, copy —
# and the copy was the one that got skipped. Anything that can be forgotten
# separately eventually is.
#
# Usage: scripts/release.sh [version]
#   With no version, rebuilds and republishes the current one, which only
#   succeeds if the bytes are unchanged.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CURRENT="$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Version.xcconfig | tr -d ' ')"
VERSION="${1:-$CURRENT}"

case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Version must look like 1.2.3, got '$VERSION'"; exit 1 ;;
esac

if [ "$VERSION" != "$CURRENT" ]; then
  echo "==> Version $CURRENT -> $VERSION"
  # Anchored: the comment block above it also mentions MARKETING_VERSION.
  /usr/bin/sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/" Config/Version.xcconfig
fi

./scripts/make-dmg.sh "$VERSION"
echo
echo "==> Publishing to the site"
./scripts/publish-to-site.sh "$VERSION"
