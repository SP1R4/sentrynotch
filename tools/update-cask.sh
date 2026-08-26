#!/bin/bash
# Point the Homebrew cask at a freshly built release DMG.
#
# Rewrites version + sha256 in Casks/sentry-notch.rb from the DMG that
# release.sh produced, so cutting a release stays a two-command job:
#   VERSION=1.2.3 ./release.sh
#   VERSION=1.2.3 ./tools/update-cask.sh
#
# The URL in the cask is derived from the version, so this only ever has to
# touch two lines.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.2.3 ./tools/update-cask.sh}"
DMG="dist/SentryNotch-$VERSION.dmg"
CASK="Casks/sentry-notch.rb"

[ -f "$DMG" ] || { echo "error: $DMG not found — run release.sh first" >&2; exit 1; }
[ -f "$CASK" ] || { echo "error: $CASK not found" >&2; exit 1; }

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

# BSD sed (macOS) in-place edit. Anchored to the known line shapes so it can't
# accidentally rewrite anything else in the file.
sed -i '' -E \
    -e "s/^(  version )\"[^\"]*\"/\\1\"$VERSION\"/" \
    -e "s/^(  sha256 )\"[0-9a-f]*\"/\\1\"$SHA\"/" \
    "$CASK"

echo "Updated $CASK:"
echo "  version $VERSION"
echo "  sha256  $SHA"
echo
echo "Next: commit the cask, and publish it to your tap so users can run"
echo "  brew install --cask SP1R4/tap/sentry-notch"
