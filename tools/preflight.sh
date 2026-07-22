#!/bin/bash
# Everything that must be true before a release, in one command.
#
# These checks were scattered across release.sh, web/README.md, and memory.
# Scattered checks are how a launch goes out with a placeholder in it.
#
#   ./tools/preflight.sh            # check for a signed release
#   ./tools/preflight.sh --beta     # unsigned beta: signing is not required
set -uo pipefail
cd "$(dirname "$0")/.."

BETA=0
[ "${1:-}" = "--beta" ] && BETA=1

pass=0; warn=0; fail=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; pass=$((pass+1)); }
no()   { printf "  \033[31m✗\033[0m %s\n     → %s\n" "$1" "$2"; fail=$((fail+1)); }
meh()  { printf "  \033[33m!\033[0m %s\n     → %s\n" "$1" "$2"; warn=$((warn+1)); }
head_() { printf "\n\033[1m%s\033[0m\n" "$1"; }

head_ "Secrets"

# The one that ends the business if it goes wrong. A 32-byte base64 blob next
# to a variable named like a private key has no business being in the tree.
if grep -rIl --exclude-dir=.build --exclude-dir=.git \
     -E 'PRIVATE.*[A-Za-z0-9+/]{43}=' . 2>/dev/null | grep -q .; then
    no "Possible private key committed in the tree" \
       "grep for it and remove; rotate the keypair if it ever left this machine"
else
    ok "No private key material found in the tree"
fi

head_ "Build"

if swift build -c release 2>&1 | grep -q 'error:'; then
    no "Release build fails" "swift build -c release"
else
    W=$(swift build -c release 2>&1 | grep -c 'warning:')
    [ "$W" -eq 0 ] && ok "Release build clean (0 warnings)" \
                   || meh "Release build has $W warning(s)" "swift build -c release"
fi

swift build >/dev/null 2>&1
if .build/debug/SentryNotchTests 2>&1 | grep -q 'ALL PASSED'; then
    N=$(.build/debug/SentryNotchTests 2>&1 | grep -c '^  ok')
    ok "Unit tests pass ($N checks)"
else
    no "Unit tests failing" ".build/debug/SentryNotchTests"
fi

if ./tools/test-upgrade.sh 2>&1 | grep -q 'ALL PASSED'; then
    ok "Hook install/upgrade/uninstall tests pass"
else
    no "Upgrade tests failing" "./tools/test-upgrade.sh"
fi

head_ "Signing"

IDENT=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -c "Developer ID Application" || true)
if [ "$IDENT" -gt 0 ]; then
    ok "Developer ID Application certificate present"
elif [ "$BETA" -eq 1 ]; then
    meh "No Developer ID — building unsigned" \
        "Gatekeeper blocks this on every Mac but yours. Free beta only, never paid."
else
    no "No Developer ID Application certificate" \
       "developer.apple.com → Certificates. Or run with --beta for an unsigned build."
fi

printf "\n\033[1m%d passed · %d warnings · %d blocking\033[0m\n" "$pass" "$warn" "$fail"
if [ "$fail" -gt 0 ]; then
    echo "Not ready to ship."
    exit 1
fi
[ "$warn" -gt 0 ] && echo "Ready, with caveats above."
[ "$warn" -eq 0 ] && echo "Ready to ship."
exit 0
