#!/usr/bin/env python3
"""Sentry Notch — generic broker adapter for *any* coding agent.

The Claude Code hook (`sentrynotch-hook.py`) speaks Claude Code's specific
PreToolUse JSON. This adapter is the agent-agnostic front door: give it a tool
call as JSON on stdin and it brokers the decision through the same Sentry Notch
socket, then reports the answer two ways so almost any agent can consume it:

  * stdout: {"decision": "allow"|"deny"|"ask", "reason": "..."}
  * exit code: 0 = allow or ask (proceed / fall back to your own prompt),
               2 = deny (block the tool call)

Fail-open by design: if the app isn't running or anything goes wrong, it prints
{"decision":"ask"} and exits 0, so your agent's own flow proceeds untouched.

Input (stdin JSON), all fields optional except tool_name:
  {
    "agent": "aider",                # your agent's name — shown on the card
    "tool_name": "Bash",             # or "Write"/"Edit"/… or your own verb
    "tool_input": {"command": "..."},# tool-specific; Bash uses {"command"},
                                     #   writes use {"file_path","content"}
    "cwd": "/path/to/project",
    "session_id": "abc123"
  }

Socket: $SENTRYNOTCH_SOCK, else the app's default under Application Support.

Example (shell):
  echo '{"agent":"aider","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"'"$PWD"'"}' \
      | sentrynotch-broker.py || echo "denied"
"""
import json
import os
import socket
import sys

DEFAULT_SOCK = os.path.expanduser(
    "~/Library/Application Support/SentryNotch/broker.sock")
SOCK = os.environ.get("SENTRYNOTCH_SOCK") or DEFAULT_SOCK
CONNECT_TIMEOUT = 1.0
DECISION_TIMEOUT = 280.0


def emit(decision, reason=""):
    """Report via stdout JSON and exit code, then exit."""
    print(json.dumps({"decision": decision, "reason": reason}))
    # allow/ask -> 0 (proceed / caller falls back); deny -> 2 (block).
    sys.exit(2 if decision == "deny" else 0)


def main():
    # Read the request. Fail open on anything malformed.
    try:
        data = json.load(sys.stdin) if not sys.stdin.isatty() else {}
    except Exception:
        emit("ask")

    # Allow a couple of overrides from argv for convenience.
    args = sys.argv[1:]
    if "--agent" in args:
        data["agent"] = args[args.index("--agent") + 1]
    if "--tool" in args:
        data["tool_name"] = args[args.index("--tool") + 1]

    if not data.get("tool_name"):
        emit("ask")

    if not os.path.exists(SOCK):
        emit("ask")   # app not running -> fail open

    req = {
        "v": 1,
        "agent": data.get("agent", "agent"),
        "session_id": data.get("session_id", ""),
        "cwd": data.get("cwd", os.getcwd()),
        "tool_name": data["tool_name"],
        "tool_input": data.get("tool_input", {}),
        "transcript_path": data.get("transcript_path", ""),
    }

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(CONNECT_TIMEOUT)
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
        emit("ask")

    line = buf.split(b"\n", 1)[0].decode(errors="replace").strip()
    if not line:
        emit("ask")
    try:
        resp = json.loads(line)
    except Exception:
        emit("ask")

    emit(resp.get("decision", "ask"), resp.get("reason", ""))


if __name__ == "__main__":
    main()
