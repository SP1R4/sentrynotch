#!/usr/bin/env python3
"""Sentry Notch lifecycle hook (Stop / SessionEnd / Notification). Fire-and-forget:
posts a lifecycle event to the Sentry Notch app so it can ping you when a session
finishes or needs input, and drop the session's mascot the moment it exits.
Never blocks, never fails a session."""
import sys, os, json, socket

SOCK = os.environ.get("SENTRYNOTCH_SOCK") or os.path.expanduser("__SOCKET_PATH__")

EVENTS = {"Stop": "stop", "SessionEnd": "end"}


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if not os.path.exists(SOCK):
        sys.exit(0)
    event = EVENTS.get(data.get("hook_event_name"), "notification")
    req = {
        "kind": "event",
        "event": event,
        "session_id": data.get("session_id", ""),
        "cwd": data.get("cwd", ""),
        "message": data.get("message", "") or "",
    }
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(SOCK)
        s.sendall((json.dumps(req) + "\n").encode())
        s.close()
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
