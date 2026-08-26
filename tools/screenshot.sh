#!/bin/bash
# Regenerate the gallery screenshots from seeded demo data.
#
# Launches a throwaway app instance (separate state dir + socket, so it never
# touches your real sessions or the installed app), opens the dashboard on each
# tab, and captures exactly that window with `screencapture -l`.
#
# Requires Screen Recording permission for the terminal running this.
# Usage: ./tools/screenshot.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=".build/release/SentryNotch"
[ -x "$BIN" ] || { echo "building release…"; swift build -c release >/dev/null; }

DEMO="$(mktemp -d)"
trap 'rm -rf "$DEMO"' EXIT
./tools/demo-seed.sh "$DEMO" >/dev/null
echo "demo state: $DEMO"

capture_tab() {
    local tab="$1" out="$2"
    local log="$DEMO/$tab.log"
    SENTRYNOTCH_STATE_DIR="$DEMO" \
    SENTRYNOTCH_SOCK="$DEMO/broker.sock" \
    SENTRYNOTCH_DASHBOARD=1 \
    SENTRYNOTCH_TAB="$tab" \
        "$BIN" >"$log" 2>&1 &
    local pid=$!

    local wn=""
    for _ in $(seq 1 60); do
        wn=$(grep -m1 DASHBOARD_WINDOW "$log" 2>/dev/null | awk '{print $2}' || true)
        [ -n "$wn" ] && break
        sleep 0.25
    done
    if [ -z "$wn" ]; then
        echo "  !! $tab: no window number (permission? launch failed) — see $log" >&2
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        return 1
    fi
    sleep 0.8                       # let the tab's content settle
    screencapture -o -l "$wn" "assets/$out"
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    echo "  ✓ assets/$out  (window $wn)"
}

echo "capturing dashboard tabs…"
capture_tab activity  activity.png
capture_tab rules     rules.png
capture_tab analytics analytics.png
capture_tab policy    policy.png

echo "done. Review assets/*.png before committing."
