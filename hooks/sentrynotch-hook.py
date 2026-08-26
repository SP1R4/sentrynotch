#!/usr/bin/env python3
"""Sentry Notch PreToolUse hook.

Routes a pending tool call to the Sentry Notch app over a unix socket and blocks
until the app returns a decision. Fail-open by design: if the app isn't
running, the socket is stale, or anything goes wrong, we emit nothing and let
Claude Code's normal permission flow proceed. We never wedge the shell.

Protocol (newline-delimited JSON):
  hook -> app:  {"v":1,"session_id","cwd","tool_name","tool_input","transcript_path"}
  app  -> hook: {"decision":"allow"|"deny"|"ask","reason":"..."}
"""
import sys
import os
import json
import socket
import subprocess

SOCK = os.environ.get("SENTRYNOTCH_SOCK") or os.path.expanduser("__SOCKET_PATH__")
# Must stay comfortably under the hook's configured timeout in settings.json.
DECISION_TIMEOUT = 280.0

TERMINALS = ("ghostty", "warp", "iterm", "apple_terminal", "terminal",
             "wezterm", "kitty", "alacritty", "hyper", "tabby")


def defer():
    # Emit nothing -> Claude Code's normal permission handling proceeds.
    sys.exit(0)


def ancestry():
    """Walk up the process tree to identify the hosting terminal app and the
    owning `claude` process. Best-effort; only called once we know the app is
    up, so its cost never hits sessions where Sentry Notch is inactive."""
    term_name = term_pid = claude_pid = None
    try:
        pid = os.getpid()
        for _ in range(25):
            out = subprocess.check_output(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                stderr=subprocess.DEVNULL).decode().strip()
            if not out:
                break
            parts = out.split(None, 1)
            ppid = int(parts[0])
            comm = parts[1] if len(parts) > 1 else ""
            if claude_pid is None and os.path.basename(comm) == "claude":
                claude_pid = pid
            low = comm.lower()
            for t in TERMINALS:
                if t in low:
                    term_pid = pid
                    term_name = (os.path.basename(comm.split(".app")[0])
                                 if ".app" in comm else os.path.basename(comm))
                    break
            if term_name or ppid <= 1:
                break
            pid = ppid
    except Exception:
        pass
    return term_name, term_pid, claude_pid


def decide(decision, reason=""):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        defer()

    if not os.path.exists(SOCK):
        defer()

    term_name, term_pid, claude_pid = ancestry()
    req = {
        "v": 1,
        "agent": "claude",
        "session_id": data.get("session_id", ""),
        "cwd": data.get("cwd", ""),
        "tool_name": data.get("tool_name", ""),
        "tool_input": data.get("tool_input", {}),
        "transcript_path": data.get("transcript_path", ""),
        "terminal": term_name,
        "terminal_pid": term_pid,
        "claude_pid": claude_pid,
    }

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(SOCK)
        s.sendall((json.dumps(req) + "\n").encode())

        s.settimeout(DECISION_TIMEOUT)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()
    except Exception:
        defer()

    line = buf.split(b"\n", 1)[0].decode(errors="replace").strip()
    if not line:
        defer()
    try:
        resp = json.loads(line)
    except Exception:
        defer()

    decision = resp.get("decision", "ask")
    reason = resp.get("reason", "")
    if decision == "allow":
        decide("allow", reason or "Allowed from Sentry Notch")
    elif decision == "deny":
        decide("deny", reason or "Denied from Sentry Notch")
    else:
        defer()


if __name__ == "__main__":
    main()
