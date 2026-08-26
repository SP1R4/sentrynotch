#!/bin/bash
# Seed a throwaway state directory with synthetic data for screenshots/demos.
#
# The gallery must never be shot against real sessions — project names and
# commands are engagement data (see Brand.swift). This writes a self-contained,
# deterministic demo state that `SENTRYNOTCH_STATE_DIR` can point the app at.
#
# Usage: ./tools/demo-seed.sh <target-dir>
set -euo pipefail
DIR="${1:?usage: demo-seed.sh <target-dir>}"
mkdir -p "$DIR"

python3 - "$DIR" <<'PY'
import json, os, sys, random
from datetime import datetime, timedelta, timezone

d = sys.argv[1]
random.seed(1729)  # deterministic gallery

projects = ["acme-webapp", "payments-api"]
# (tool, summary, risk) templates, risk in "", "caution", "danger"
templates = [
    ("Read",  "/Users/alex/work/{p}/README.md", ""),
    ("Read",  "/Users/alex/work/{p}/src/db/pool.ts", ""),
    ("Grep",  "TODO in src/", ""),
    ("Bash",  "git status", ""),
    ("Bash",  "npm test -- auth", ""),
    ("Bash",  "docker compose up -d", ""),
    ("Edit",  "/Users/alex/work/{p}/src/db/pool.ts", ""),
    ("Write", "/Users/alex/work/{p}/tests/auth.test.ts", ""),
    ("Bash",  "psql -c 'select count(*) from users'", "caution"),
    ("Bash",  "rm -rf node_modules/.cache", "caution"),
    ("Bash",  "curl -s https://api.acme-staging.io/health", "caution"),
    ("Bash",  "curl -s http://169.254.169.254/latest/meta-data/", "danger"),
    ("Read",  "/Users/alex/work/{p}/.env", "danger"),
    ("Bash",  "git push --force origin main", "caution"),
]
# Standing-allow rule keys and how they present.
rules = ["Bash|docker", "Bash|ls", "Bash|npm", "Read", "Grep", "Bash|git"]

def rule_key(tool, summary):
    if tool != "Bash":
        return tool
    head = summary.split()[0] if summary else ""
    return f"Bash|{head}"

# ---- decisions.jsonl : ~120 entries across 14 days, one clear peak ----
today = datetime.now(timezone.utc).replace(hour=16, minute=0, second=0, microsecond=0)
lines = []
per_day = [4, 6, 5, 7, 9, 6, 8, 22, 11, 9, 7, 6, 8, 5]  # index 7 is the peak
for back, count in zip(range(13, -1, -1), per_day):
    day = today - timedelta(days=back)
    for i in range(count):
        tool, summ, risk = random.choice(templates)
        p = random.choice(projects)
        summary = summ.format(p=p)
        cwd = f"/Users/alex/work/{p}"
        key = rule_key(tool, summary)
        # danger -> mostly denied; auto-allowed when it matches a standing rule.
        if risk == "danger":
            decision = "deny" if random.random() < 0.7 else "allow"
        elif key in rules and tool in ("Read", "Grep") or key in ("Bash|docker", "Bash|npm", "Bash|git"):
            decision = "allow*"   # auto-allowed via a standing rule
        else:
            decision = "allow" if random.random() < 0.85 else "deny"
        ts = (day + timedelta(minutes=i * 7)).isoformat().replace("+00:00", "Z")
        lines.append(json.dumps({
            "ts": ts, "decision": decision, "tool": tool, "summary": summary,
            "session_id": f"sess-{p}", "cwd": cwd, "risk": risk, "key": key,
        }))
open(os.path.join(d, "decisions.jsonl"), "w").write("\n".join(lines) + "\n")

# ---- rules.json : standing allows (2 never used, listed first by the UI) ----
open(os.path.join(d, "rules.json"), "w").write(json.dumps({
    "alwaysAllow": rules,
    "bypassSessions": [],
    "autoAllowReadOnly": True,
    "failClosedRisky": True,
    "interceptEnabled": True,
    "interceptNewSessions": True,
}))

# ---- tokens.jsonl : peak context tokens per day ----
tok = []
for back in range(13, -1, -1):
    day = (today - timedelta(days=back)).strftime("%Y-%m-%d")
    for p in projects:
        tok.append(json.dumps({"day": day, "session": f"sess-{p}",
                               "peak": random.randint(90_000, 300_000)}))
open(os.path.join(d, "tokens.jsonl"), "w").write("\n".join(tok) + "\n")

# ---- settings.json : coral accent + a populated starter policy ----
def uid():
    return "%08x-%04x-%04x-%04x-%012x" % (random.getrandbits(32), random.getrandbits(16),
        random.getrandbits(16), random.getrandbits(16), random.getrandbits(48))
policy = [
    {"id": uid(), "name": "Block writes to SSH keys", "effect": "deny",
     "enabled": True, "tools": ["Write", "Edit", "MultiEdit"], "pathGlob": "**/.ssh/**"},
    {"id": uid(), "name": "Block cloud-credential writes", "effect": "deny",
     "enabled": True, "tools": ["Write", "Edit", "MultiEdit"], "pathGlob": "**/.aws/**"},
    {"id": uid(), "name": "Confirm out-of-scope network calls", "effect": "prompt",
     "enabled": True, "scope": "outOfScope"},
    {"id": uid(), "name": "Always confirm high risk", "effect": "prompt",
     "enabled": True, "minRisk": 3},
    {"id": uid(), "name": "Auto-allow reads in repo", "effect": "allow",
     "enabled": True, "tools": ["Read", "Grep"]},
]
# Widgets off so the island hero shot is just the toolbar + the permission
# card — no widget row, and (with the session list off) no real session data.
widgets = {w: False for w in ["usage", "sessions", "approveSafe", "activity",
           "timer", "spotify", "headroom", "repo", "vitals", "fleet"]}
open(os.path.join(d, "settings.json"), "w").write(json.dumps({
    "accent": "coral", "policyEnabled": True, "policyRules": policy,
    "widgets": widgets,
}))
print("seeded", d)
PY
