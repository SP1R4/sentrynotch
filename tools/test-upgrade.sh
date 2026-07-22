#!/bin/bash
# Exercises the upgrade path against a THROWAWAY settings.json.
#
# Never point this at ~/.claude/settings.json: the migration moves the hook
# script out from under whatever settings.json references, so testing against
# the live file strands the hook and blocks every tool call in your own
# session. That is not hypothetical — it is how the stale-path bug was found.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SETTINGS="$TMP/settings.json"
APP="./SentryNotch.app/Contents/MacOS/SentryNotch"

[ -x "$APP" ] || { echo "build first: ./make-app.sh"; exit 1; }

pass=0; fail=0
check() { if [ "$1" = "$2" ]; then echo "  ok   $3"; pass=$((pass+1));
          else echo "  FAIL $3 (got '$1' want '$2')"; fail=$((fail+1)); fi }

# A user's own unrelated hooks must survive everything we do.
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "python3 /Users/x/.claude/hooks/my-audit.py"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "python3 /Users/x/.claude/xisland/xisland-hook.py"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "python3 /Users/x/.claude/xisland/xisland-notify.py"}]}
    ]
  }
}
JSON

echo "== install over a legacy (xIsland) install =="
SENTRYNOTCH_SETTINGS="$SETTINGS" "$APP" --install-hook >/dev/null

# The stale legacy entry must be gone, replaced by exactly one current entry.
legacy=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('xisland' in h.get('command','') for e in s['hooks']['PreToolUse'] for h in e['hooks']))")
check "$legacy" "0" "the legacy PreToolUse entry is replaced, not duplicated"

current=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('sentrynotch-hook.py' in h.get('command','') for e in s['hooks']['PreToolUse'] for h in e['hooks']))")
check "$current" "1" "exactly one current PreToolUse entry"

mine=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('my-audit.py' in h.get('command','') for e in s['hooks']['PreToolUse'] for h in e['hooks']))")
check "$mine" "1" "the user's own hook is left alone"

stopleg=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('xisland' in h.get('command','') for e in s['hooks'].get('Stop',[]) for h in e['hooks']))")
check "$stopleg" "0" "the legacy Stop entry is replaced too"

for ev in SessionEnd Notification; do
  n=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(len(s['hooks'].get('$ev',[])))")
  check "$n" "1" "$ev is registered"
done

echo "== reinstall is idempotent =="
SENTRYNOTCH_SETTINGS="$SETTINGS" "$APP" --install-hook >/dev/null
n=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('sentrynotch-hook.py' in h.get('command','') for e in s['hooks']['PreToolUse'] for h in e['hooks']))")
check "$n" "1" "reinstalling does not stack duplicate entries"

echo "== uninstall =="
SENTRYNOTCH_SETTINGS="$SETTINGS" "$APP" --uninstall-hook >/dev/null
ours=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum(('sentrynotch' in h.get('command','')) or ('xisland' in h.get('command',''))
          for v in s.get('hooks',{}).values() for e in v for h in e.get('hooks',[])))")
check "$ours" "0" "uninstall removes every entry of ours"

mine=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(sum('my-audit.py' in h.get('command','') for e in s['hooks'].get('PreToolUse',[]) for h in e['hooks']))")
check "$mine" "1" "uninstall leaves the user's own hook intact"

echo "== the unquoted-command outage =="
# The state directory is ~/Library/Application Support/... — it has a space.
# An unquoted command splits at "Application", python3 gets a path that does
# not exist, every PreToolUse hook errors, and Claude Code refuses every tool
# call. This asserts the command we write actually runs, and that an install
# already broken this way heals itself instead of staying dead forever.
SENTRYNOTCH_SETTINGS="$SETTINGS" "$APP" --install-hook >/dev/null

cmd=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(next(h['command'] for e in s['hooks']['PreToolUse'] for h in e['hooks']
           if 'sentrynotch-hook.py' in h.get('command','')))")
/bin/sh -c "$cmd </dev/null >/dev/null 2>&1"; rc=$?
check "$([ $rc -eq 127 ] || [ $rc -eq 2 ] && echo broken || echo runs)" "runs" \
      "the installed hook command executes from a path containing spaces"

# Simulate a customer stuck on the pre-fix build, then let the app repair it.
python3 - "$SETTINGS" <<'EOF'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
for e in s['hooks']['PreToolUse']:
    for h in e['hooks']:
        if 'sentrynotch-hook.py' in h.get('command',''):
            h['command']=h['command'].replace("'","")   # back to the broken form
json.dump(s,open(p,'w'),indent=2)
EOF
broken=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(next(h['command'] for e in s['hooks']['PreToolUse'] for h in e['hooks']
           if 'sentrynotch-hook.py' in h.get('command','')))")
check "$(printf '%s' "$broken" | tr -cd "'" | wc -c | tr -d ' ')" "0" "precondition: the entry is now unquoted"

SENTRYNOTCH_SETTINGS="$SETTINGS" "$APP" --install-hook >/dev/null
healed=$(python3 -c "
import json;s=json.load(open('$SETTINGS'))
print(next(h['command'] for e in s['hooks']['PreToolUse'] for h in e['hooks']
           if 'sentrynotch-hook.py' in h.get('command','')))")
check "$(printf '%s' "$healed" | tr -cd "'" | wc -c | tr -d ' ')" "2" "a broken unquoted install is repaired to a quoted one"
/bin/sh -c "$healed </dev/null >/dev/null 2>&1"; rc2=$?
check "$([ $rc2 -eq 127 ] || [ $rc2 -eq 2 ] && echo broken || echo runs)" "runs" \
      "the repaired command executes"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED ($pass)"; else echo "$fail FAILED"; exit 1; fi
