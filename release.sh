#!/bin/bash
# Build, sign, notarize, staple, and package Sentry Notch for distribution.
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain:
#        security find-identity -v -p codesigning
#   3. A notarytool keychain profile holding your Apple ID + app-specific
#      password + team ID:
#        xcrun notarytool store-credentials sentrynotch-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific>
#      (App-specific password: appleid.apple.com > Sign-In and Security.)
#
# Usage:
#   VERSION=1.0.0 ./release.sh
#
# Everything the customer downloads comes out of dist/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0.0 ./release.sh}"
PROFILE="${NOTARY_PROFILE:-sentrynotch-notary}"
APP="SentryNotch.app"
DIST="dist"
DMG="$DIST/SentryNotch-$VERSION.dmg"

# Cheap correctness checks first — they need no certificate, so they still fire
# on a machine that isn't set up to sign yet.
echo "==> Running tests"
swift build >/dev/null
.build/debug/SentryNotchTests | tail -1
./tools/test-upgrade.sh | tail -1

# Resolve the signing identity unless one was supplied.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)"/\1/') || true
fi
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    if [ "${ALLOW_UNSIGNED:-}" = "1" ]; then
        # Escape hatch for a free beta. Not suitable for a paid release: on
        # current macOS an unsigned download cannot be opened by right-click,
        # only by overriding Gatekeeper in System Settings. Asking a buyer to
        # do that to install a security tool is a contradiction they will
        # rightly hold against you.
        cat >&2 <<'WARN'
================================================================
 BUILDING UNSIGNED — NOT FIT FOR SALE
 Gatekeeper will block this on every Mac but yours. Users must
 override it in System Settings > Privacy & Security.
 Use this for a free beta only. Get a Developer ID before charging.
================================================================
WARN
        VERSION="$VERSION" ./make-app.sh release
        rm -rf "$DIST" && mkdir -p "$DIST/stage"
        ditto "$APP" "$DIST/stage/$(basename "$APP")"
        ln -s /Applications "$DIST/stage/Applications"
        # Not optional: an unsigned build that Gatekeeper blocks, with no
        # explanation in the disk image, reads as a broken download.
        cp web/INSTALL-UNSIGNED.txt "$DIST/stage/READ ME FIRST.txt"
        cp web/SETUP.txt "$DIST/stage/Setup & Permissions.txt"
        hdiutil create -volname "Sentry Notch" -srcfolder "$DIST/stage" \
            -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$DIST/stage"
        echo
        echo "Built (UNSIGNED): $DMG"
        echo "Ship this only as a free beta."
        exit 0
    fi
    echo "error: no 'Developer ID Application' identity found in the keychain." >&2
    echo "       Create one at developer.apple.com > Certificates, then re-run." >&2
    echo "       For an unsigned beta build: ALLOW_UNSIGNED=1 VERSION=$VERSION ./release.sh" >&2
    exit 1
fi
echo "==> Signing identity: $CODESIGN_IDENTITY"

echo "==> Building the bundle"
VERSION="$VERSION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./make-app.sh release

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# The DMG is what ships, so confirm the entitlements and hardened runtime
# actually landed rather than assuming codesign honoured them.
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q apple-events \
    || { echo "error: Apple Events entitlement missing — the Spotify widget will be denied" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" \
    || { echo "error: hardened runtime not enabled — notarization will reject this" >&2; exit 1; }
# Must report "accepted"; a rejection here means notarization would fail too.
spctl --assess --type execute --verbose=4 "$APP" || \
    echo "note: spctl will only accept it after notarization + stapling"

echo "==> Packaging $DMG"
rm -rf "$DIST" && mkdir -p "$DIST/stage"
# ditto, not cp -R: it preserves extended attributes and resource forks, which
# is what keeps the code signature intact. cp can strip them and produce a DMG
# whose app fails Gatekeeper for no visible reason.
ditto "$APP" "$DIST/stage/$(basename "$APP")"
ln -s /Applications "$DIST/stage/Applications"
# Ships in the image, not just on the website: the permission prompts land
# before anyone has read a web page, and the YouTube control trade-off is a
# security decision the user should make with the facts in front of them.
cp web/SETUP.txt "$DIST/stage/Setup & Permissions.txt"
hdiutil create -volname "Sentry Notch" -srcfolder "$DIST/stage" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"

echo "==> Signing the disk image"
codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (this waits on Apple; usually 1-5 minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket"
# Stapling lets a customer's Mac verify offline — without it, first launch
# behind a firewall shows the "cannot be opened" dialog.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Updating the Homebrew cask"
VERSION="$VERSION" ./tools/update-cask.sh || echo "note: cask update skipped"

echo
echo "Ready to ship: $DMG"
echo "Verify on a clean Mac before announcing:"
echo "  spctl --assess --type open --context context:primary-signature -v $DMG"
