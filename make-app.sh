#!/bin/bash
# Build Sentry Notch and wrap the executable in a .app bundle.
#
# Unsigned/ad-hoc by default — fine for local development. For a build you can
# actually ship to a paying customer, use ./release.sh, which signs with your
# Developer ID, enables the hardened runtime, notarizes, and staples.
#
# Safe-default: runs as a menu-bar accessory (no Dock icon); interception is OFF
# until the user arms it, so an installed hook is inert.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-com.sp1r4.sentrynotch}"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/SentryNotch"
APP="SentryNotch.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp "$BIN" "$MACOS/SentryNotch"
# Bundle the canonical hooks so HookInstaller writes the readable repo copies.
cp hooks/sentrynotch-hook.py "$APP/Contents/Resources/sentrynotch-hook.py"
cp hooks/sentrynotch-notify.py "$APP/Contents/Resources/sentrynotch-notify.py"
# App icon. Regenerate from the shield mark with: swift run makeicon Resources
cp Resources/SentryNotch.icns "$APP/Contents/Resources/SentryNotch.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sentry Notch</string>
    <key>CFBundleDisplayName</key><string>Sentry Notch</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>SentryNotch</string>
    <key>CFBundleIconFile</key><string>SentryNotch</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) sp1r4. All rights reserved.</string>
    <!-- Only ever used to read now-playing from, and send transport commands
         to, the local Spotify app. No other app is scripted. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Sentry Notch controls the Spotify app for the now-playing widget.</string>
</dict>
</plist>
PLIST

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
             --entitlements entitlements.plist \
             --sign "$CODESIGN_IDENTITY" "$APP"
    echo "Signed with: $CODESIGN_IDENTITY"
else
    # Ad-hoc: gives the bundle an identity so UNUserNotificationCenter will
    # register categories. Gatekeeper will still block this on another Mac.
    codesign --force --sign - "$APP" 2>/dev/null \
        || echo "note: codesign skipped (notifications may be limited)"
    echo "Ad-hoc signed — NOT distributable. Use ./release.sh to ship."
fi

echo "Built $APP ($VERSION build $BUILD)"
