# Sentry Notch broker protocol

Sentry Notch is a permission checkpoint, not a Claude-only tool. The app brokers
decisions over a local Unix-domain socket using a small, stable, **agent-agnostic**
wire protocol. Any agent that can open a socket — or just shell out to a command —
can route its tool-permission decisions through the notch.

## The socket

```
$SENTRYNOTCH_SOCK
# default:
~/Library/Application Support/SentryNotch/broker.sock
```

The socket exists only while the app is running. **If it's absent, fail open** —
proceed with your agent's own permission flow. Sentry Notch never wedges an
agent: absence of the app must never block a tool call.

## Wire format (newline-delimited JSON)

One JSON object per line, request then response, on a single connection held
open until the user answers (or the request is abandoned).

### Request (adapter → app)

```json
{
  "v": 1,
  "agent": "aider",
  "session_id": "abc123",
  "cwd": "/Users/you/project",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf build" },
  "transcript_path": ""
}
```

| field | meaning |
|---|---|
| `v` | protocol version, currently `1` |
| `agent` | your agent's name — shown as a tag on the permission card (defaults to `claude` if omitted) |
| `session_id` | opaque per-session id, groups a session's calls |
| `cwd` | the working directory (drives scope, project policy, pre-flight) |
| `tool_name` | `Bash`, `Write`, `Edit`, `MultiEdit`, `Read`, `WebFetch`, … or your own verb |
| `tool_input` | tool-specific. `Bash` → `{"command": …}`; writes → `{"file_path", "content"}`; edits → `{"file_path","old_string","new_string"}` |
| `transcript_path` | optional; unused by the broker |

The richer analysis (risk, exfil, pre-flight, scope) keys off `tool_name` +
`tool_input`, so the closer your tool names/inputs are to the shapes above, the
more Sentry Notch can tell the user before they decide. Unknown tool names still
work — they just show as a generic call.

### Response (app → adapter)

```json
{ "decision": "allow" | "deny" | "ask", "reason": "..." }
```

- `allow` — the user (or a policy/trust-window) approved it. Proceed.
- `deny` — refused. Do not run the tool call.
- `ask` — Sentry Notch is not handling it (interception off, fail-open, timeout).
  Fall back to your own permission prompt.

## The easy path: the generic adapter

Rather than speak the socket yourself, shell out to `sentrynotch-broker.py`. It
takes the request as JSON on stdin and reports the decision two ways:

- **stdout**: `{"decision": …, "reason": …}`
- **exit code**: `0` = allow or ask (proceed / fall back), `2` = deny (block)

```sh
echo '{"agent":"aider","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"'"$PWD"'"}' \
    | sentrynotch-broker.py || { echo "blocked by Sentry Notch"; exit 1; }
```

Any agent with a pre-execution shell hook (a wrapper script, a `PreToolUse`-style
callback, a shell alias around a dangerous command) can gate on that exit code.

## Fail-open contract

Every adapter — the Claude hook, the generic broker, and anything you build —
must treat a missing socket, a connect error, a timeout, or a malformed response
as `ask` and proceed. The whole design promises that Sentry Notch, when it isn't
there, changes nothing.
