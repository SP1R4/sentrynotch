<div align="center">

<img src="assets/hero.svg" alt="Sentry Notch — a permission checkpoint for coding agents, living in your Mac's notch" width="820" />

<br/>

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-3da35d)
![Fails open](https://img.shields.io/badge/design-fails%20open-e08a2b)
![No phone home](https://img.shields.io/badge/telemetry-none-4a7fd0)
![Tamper-evident log](https://img.shields.io/badge/audit-tamper--evident-D97757)

<br/>

<img src="assets/prompt.png" width="760" alt="The notch island showing a risky command — a download piped into sudo — with the risk spelled out and four decision buttons." />

<sub><i>A curl-into-sudo lands mid-session. The notch opens, the risk is spelled out, and it's one keystroke from denied — without leaving the terminal.</i></sub>

</div>

---

> [!WARNING]
> **A review aid, not a security control.** Risk and scope checks are heuristics and *will* miss things.
> The app deliberately **fails open**: if it isn't running, your agent's own permission flow proceeds
> untouched. Never rely on it as the only control over an autonomous agent.

## What it is

Sentry Notch watches the coding-agent sessions **you** start in real terminals and brokers their
tool-permission decisions from the notch. It is not a chat client and it never runs an agent of its
own — it sits between the agent and the "yes/no" and gives you a fast, informed way to answer.

Everything happens **on your machine**. No account, no server, no telemetry — the decision log lives
in a local file you own, and it's now **cryptographically tamper-evident**.

## Why

Autonomous coding agents ask for permission constantly, and "just hit Allow" is how a `curl | sh` or a
write to `~/.ssh` slips through. Sentry Notch turns that reflex into a glance: the **risk is surfaced
first**, the **engagement scope is enforced**, and the **whole trail is auditable** afterward — the
questions that actually matter when you're writing up what an agent did.

## Features

|  |  |
|---|---|
| **⌨️ Answer from the notch** | Deny / Allow Once / Always / Bypass. `⌘⇧Space` from anywhere, `⌘1`–`⌘4` for the top prompt, or reply straight from the notification. |
| **⚠️ See the risk first** | `rm -rf`, `curl \| sh`, `sudo`, writes outside the working dir, edits to `.ssh` / `.env`, force-pushes — flagged before you decide. Edits show the real diff. |
| **🛰️ Egress & exfil lens** | Catches data *leaving the box* — file uploads, `cat` a secret into `curl`/`nc`, base64-then-send, `scp`/`rsync` to a remote, new dependencies in a manifest. |
| **🔭 Command pre-flight** | Before you approve Bash, see what `rm -rf` would *actually* delete (real file count + sample paths) and what a force-push / reset / clean will destroy. |
| **📜 Policy engine** | Declarative **allow / deny / ask** rules — by tool, path glob, command regex, risk, scope, or host — checked before any auto-allow. A deny is honoured even out of scope. |
| **🎯 Scope guard** | Define your engagement targets; out-of-scope hosts in a command get called out. |
| **⏱️ Trust windows** | "Trust reads here for 5 minutes" — a time-boxed auto-approve with a live countdown that revokes itself. No permanent grant left behind. |
| **🛑 Panic stop** | One click denies every call instantly, plus a recoverable `git stash` undo of an agent's edits. |
| **🔗 Tamper-evident audit log** | Every decision HMAC-chained to the last; a built-in verifier flags any altered, removed, or reordered record. Exportable as an engagement report. |
| **🧩 Any agent** | Claude Code out of the box; a documented socket protocol + generic adapter lets Aider, and anything with a pre-tool hook, broker through the same notch. |
| **🛟 Fails open, always** | The safety path never blocks your agent. If Sentry Notch isn't running, nothing changes. |

## Gallery

<div align="center">
<table>
<tr>
<td width="50%"><img src="assets/island.png" alt="The notch island with a pending prompt" /><br/><sub><b>The island</b> — prompts, risk, and live sessions.</sub></td>
<td width="50%"><img src="assets/policy.png" alt="The policy engine editor" /><br/><sub><b>Policy</b> — allow / deny / ask rules, checked before auto-allow.</sub></td>
</tr>
<tr>
<td width="50%"><img src="assets/activity.png" alt="Per-session activity feed" /><br/><sub><b>Activity</b> — the decision log, browsable.</sub></td>
<td width="50%"><img src="assets/analytics.png" alt="Usage analytics" /><br/><sub><b>Analytics</b> — decisions and usage over time, with integrity verification.</sub></td>
</tr>
<tr>
<td width="50%"><img src="assets/rules.png" alt="Always-allow rules" /><br/><sub><b>Rules</b> — the always-allow decisions you've made.</sub></td>
<td width="50%"></td>
</tr>
</table>
</div>

## How it works

<div align="center">
<img src="assets/flow.svg" alt="A coding agent's tool call flows through the hook to Sentry Notch; you decide; the answer returns; every decision is appended to a tamper-evident audit log." width="820" />
</div>

- A tiny **hook** forwards each permission request over a local Unix socket.
- Sentry Notch analyses the tool call — **risk heuristics**, **exfil detection**, **scope matching**, and a
  read-only **pre-flight** all run on-device — and surfaces it in the notch.
- Your answer is sent back to the waiting agent; the decision is appended to the local, **HMAC-chained** audit log.
- If the app isn't running, the socket isn't there, and the agent falls back to its own prompt flow —
  the **fail-open** guarantee.

No part of this contacts a network service **unless you turn on off-box alerts** and give it a
webhook URL of your own (Plugins ▸ Off-box alerts) — an opt-in ping to a destination you choose,
never a call home. See [PRIVACY.md](PRIVACY.md) for specifics.

## Other agents

Sentry Notch isn't Claude-only. The broker speaks a small, stable, agent-agnostic protocol over a
local socket, so any agent with a pre-execution hook can route its tool-permission decisions through
the notch. The easy path is the generic adapter — give it a tool call as JSON on stdin, gate on its
exit code:

```sh
echo '{"agent":"aider","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"'"$PWD"'"}' \
    | sentrynotch-broker.py || echo "blocked by Sentry Notch"
```

The agent's name shows as a tag on the permission card. See
[hooks/BROKER_PROTOCOL.md](hooks/BROKER_PROTOCOL.md) for the wire format and the fail-open contract.

## Install

**Homebrew** (once a signed release is published to the tap):

```bash
brew install --cask SP1R4/tap/sentry-notch
```

Or **download** the latest `.dmg` from the [Releases page](../../releases/latest) and drag
**Sentry Notch** into Applications. On first run it walks you through enabling the Claude Code hook.

The build is **unsigned** — there's no paid Apple Developer certificate behind a free, open-source
app — so Gatekeeper will warn you the first time. Open it once with **right-click ▸ Open**, or clear
the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/SentryNotch.app
```

Rather not trust an unsigned binary? [Build from source](#build-from-source) — it's a two-minute
`swift build`.

### Build from source

Requires macOS 14+ and a Swift 5.9 toolchain (Xcode or Command Line Tools).

```bash
git clone https://github.com/SP1R4/sentrynotch.git
cd sentrynotch
swift build                 # compile
swift run SentryNotchTests  # run the test suite (no XCTest needed)
./make-app.sh               # bundle SentryNotch.app
```

Then open `SentryNotch.app`.

## Contributing

Issues and PRs are welcome. The core, platform-agnostic logic (risk analysis, exfil detection, the
policy engine, the audit chain, analytics) lives in `Sources/SentryNotchCore` and is covered by the
runner in `Tests/` — please keep it green:

```bash
swift run SentryNotchTests
```

The gallery is reproducible from seeded demo data (never real sessions): `./tools/screenshot.sh`.

## License

[MIT](LICENSE) — free to use, fork, and build on.

<sub><b>Trademark:</b> "Sentry Notch" is the project's name; it is not affiliated with Sentry
(sentry.io). If you distribute a fork, please ship it under a different name to avoid confusion.
Every user-visible name and URL is centralised in `Sources/SentryNotchCore/Brand.swift`.</sub>
</content>
