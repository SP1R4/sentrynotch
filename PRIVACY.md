# Privacy Policy — Sentry Notch

Last updated: 19 July 2026

## The short version

Sentry Notch runs entirely on your Mac. It does not have an account system, it
does not collect analytics, and it has no server to send your data to.

The app reads your Claude Code transcripts and the tool calls your agents want
to make. That content — source code, shell commands, file paths, client names —
**never leaves your machine**.

## What the app reads, and why

| Data | Why | Where it goes |
|---|---|---|
| `~/.claude/projects/**/*.jsonl` (session transcripts) | To show live session cards and the activity feed | Read into memory only |
| Pending tool calls, via the `PreToolUse` hook | To show you the permission prompt you are answering | Held in memory until you answer |
| Your decisions | Written to a local audit log so you can review what was allowed | `decisions.jsonl`, on your disk |
| Context-token counts | The analytics trend | `tokens.jsonl`, on your disk |
| Now-playing track (if the Now playing widget is on) | To draw the widget | Read from the local Spotify or Apple Music app; not stored |
| A YouTube tab's title (only if you pick YouTube as the source) | To draw the widget | Read from your browser; **only tabs whose URL is YouTube**; not stored |
| A high-risk / out-of-scope alert (only if you turn on off-box alerts) | To ping you when you're away from the machine | POSTed to a webhook **URL you supply** — a truncated summary, tool name, project, and risk; opt-in and off by default |

The audit log is also **tamper-evident**: each decision is HMAC-chained to the
previous one, keyed by a per-install secret stored at `audit.key` (owner-only,
`0600`) in the same directory. The key never leaves your machine; it exists so
you can prove the log wasn't altered after the fact.

Everything the app writes lives in:

```
~/Library/Application Support/SentryNotch/
```

That directory is created with `0700` permissions (owner-only). It is not inside
iCloud Drive and is not synced anywhere by the app.

**It will contain sensitive material.** The audit log records the commands and
file paths your agents proposed. On an engagement, that can include client
hostnames and infrastructure detail. Treat it like any other engagement
artefact: it is covered by your disk encryption, your retention policy, and your
scope agreement — not by us, because we never receive it.

You can delete the whole directory at any time. The app recreates only what it
needs.

## What leaves your machine

Three things, all optional and none containing your work:

1. **Update check.** Once a day the app fetches a static JSON file over HTTPS to
   see whether a newer version exists. It is a plain GET with no query string,
   no licence key, and no identifier. The request reveals only that some Mac
   fetched a public file, plus the IP address inherent in any HTTPS request.
   Disable it by blocking the domain; the app keeps working.

2. **Album artwork — Spotify only**, and only if the Now playing widget is
   switched on. When the track changes, the app downloads the cover image from
   Spotify's own CDN (`i.scdn.co`) using the URL Spotify's local app hands it.
   It is a plain image GET, fetched once per track, carrying no account or
   licence information — and it concerns a track Spotify already knows you are
   playing. Turn the widget off in Dashboard ▸ Widgets and no request is made.

   **Apple Music artwork never leaves your Mac.** Its covers are read from your
   local library rather than fetched from a CDN, so with Apple Music as the
   source this widget makes no network request at all.

   **YouTube fetches no artwork at all**, deliberately — pulling a thumbnail
   would mean a request to Google for every track, which is exactly what this
   section promises the app does not do.

3. **Reading a YouTube tab.** If you select YouTube as the music source, the app
   asks your browser for the title of a tab whose address is a YouTube URL. The
   script is written to match only those addresses and return only that one
   title. It never enumerates, returns, or logs any other tab, and macOS gates
   the whole thing behind an Automation permission you grant per browser. Pick a
   different source, and the app never speaks to your browser at all.

4. **Nothing else.** Your transcripts, commands, and decisions are never sent
   anywhere at all.

## What we store about you

Nothing. Sentry Notch is free and open source — there is no account, no
purchase, and no server. No usage data, no telemetry, no crash reports.

## Your rights

Email <sp1r4.work@gmail.com> to get a copy of what we hold (an email address
and an order reference), to correct it, or to have it deleted. Deleting it means
we can no longer re-issue your key, but any key already installed keeps working
— it validates offline.

Use email rather than the public issue tracker for anything involving your
personal data: an issue is visible to everyone, and a request to delete your
information should not require you to publish it first.

## Children

The app is a developer tool and is not directed at anyone under 16.

## Changes

Material changes will be noted in the release notes and dated at the top of this
document. The app does not silently start collecting anything.

## Contact

Bugs and questions: https://github.com/sp1r4/sentrynotch/issues
Privacy and data requests: <sp1r4.work@gmail.com>
