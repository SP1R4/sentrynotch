import Foundation
import SentryNotchCore

/// Installs/uninstalls the Sentry Notch PreToolUse hook in ~/.claude/settings.json,
/// and drops the hook script into Application Support/SentryNotch/. Every settings write is
/// backed up first. The hook is identified by its script path so we can find
/// and remove exactly our entry without touching the user's other hooks.
enum HookInstaller {
    static var dir: String { Brand.stateDir }
    static var scriptPath: String { Brand.hookScriptPath }

    /// The exact command an up-to-date install writes.
    ///
    /// Staleness is judged by comparing against this rather than by asking
    /// whether the command merely *mentions* the script path. That weaker test
    /// is why a broken install could never self-heal: the unquoted command
    /// `python3 /Users/…/Application Support/…` does contain the path, so the
    /// repair decided everything was fine and returned — leaving Claude Code
    /// unable to run a single tool, with no way to invoke the fix.
    static var expectedCommand: String { "python3 \(shellQuote(scriptPath))" }
    static var notifyScriptPath: String { Brand.notifyScriptPath }
    static var socketPath: String { Brand.socketPath }
    /// Overridable so the upgrade path can be exercised against a throwaway
    /// settings file. Mutating the real one to test it can strand the hook and
    /// lock the user out of every tool call — which is exactly how the stale-
    /// path bug below was discovered.
    static var settingsPath: String {
        if let override = ProcessInfo.processInfo.environment["SENTRYNOTCH_SETTINGS"] {
            return override
        }
        return NSString(string: "~/.claude/settings.json").expandingTildeInPath
    }

    /// Marker substring identifying any of our hook commands in settings.json.
    private static let marker = Brand.hookMarker
    private static let hookTimeoutSeconds = 600

    // MARK: - Public

    /// Move state written by a previous name/location into the current one, so
    /// an update doesn't silently orphan a user's rules, license, and history.
    /// Only ever moves *into* an empty destination — never overwrites.
    static func migrateLegacyState() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Brand.stateDir) else { return }
        for slug in Brand.legacySlugs {
            let old = NSString(string: "~/.claude/\(slug)").expandingTildeInPath
            guard fm.fileExists(atPath: old) else { continue }
            do {
                try fm.createDirectory(atPath: (Brand.stateDir as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try fm.moveItem(atPath: old, toPath: Brand.stateDir)
                NSLog("\(Brand.name): migrated state from \(old)")
            } catch {
                NSLog("\(Brand.name): migration from \(old) failed: \(error)")
            }
            return
        }
    }

    static func writeScript() throws {
        migrateLegacyState()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try write(scriptSource("sentrynotch-hook", fallback: embeddedHookScript), to: scriptPath)
        try write(scriptSource("sentrynotch-notify", fallback: embeddedNotifyScript), to: notifyScriptPath)
    }

    /// The scripts ship with a `__SOCKET_PATH__` placeholder so the repo copies
    /// stay readable and `Brand` remains the only place the path is defined.
    private static func write(_ contents: String, to path: String) throws {
        let resolved = contents.replacingOccurrences(of: "__SOCKET_PATH__", with: socketPath)
        try resolved.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Prefer a real file (bundled in the .app, or next to the dev binary) so
    /// the repo's hooks/*.py stay the single readable source; fall back to the
    /// embedded copy when neither is present.
    private static func scriptSource(_ name: String, fallback: String) -> String {
        let exeDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let candidates = [
            Bundle.main.path(forResource: name, ofType: "py"),
            "\(exeDir)/../Resources/\(name).py",
            "\(exeDir)/../../hooks/\(name).py",       // swift run layout
        ].compactMap { $0 }
        for path in candidates {
            if let s = try? String(contentsOfFile: path, encoding: .utf8), s.contains("Sentry Notch") {
                return s
            }
        }
        return fallback
    }

    static func install() throws {
        try writeScript()
        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // PreToolUse — permission broker.
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.removeAll { entryUsesOurHook($0) }
        preToolUse.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": "python3 \(shellQuote(scriptPath))", "timeout": hookTimeoutSeconds]],
        ])
        hooks["PreToolUse"] = preToolUse

        // Stop / SessionEnd / Notification — completion + attention pings, and
        // the signal that lets the notch stop drawing a finished session.
        for event in ["Stop", "SessionEnd", "Notification"] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { entryUsesOurHook($0) }
            entries.append([
                "hooks": [["type": "command", "command": "python3 \(shellQuote(notifyScriptPath))"]],
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        try backupThenWrite(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in ["PreToolUse", "Stop", "SessionEnd", "Notification"] {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entryUsesOurHook($0) }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        settings["hooks"] = hooks
        try backupThenWrite(settings)
    }

    static func isInstalled() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return preToolUse.contains(where: entryUsesOurHook)
    }

    /// An install from a previous version points at the old script path. The
    /// hook then fails to execute and the broker silently stops intercepting —
    /// the worst failure mode for a security tool, because everything looks
    /// fine. Repair it on launch whenever a hook of ours is present but stale.
    static func repairIfStale() {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]],
              preToolUse.contains(where: entryUsesOurHook) else { return }
        let current = preToolUse.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String) == expectedCommand
            } == true
        }
        guard !current else { return }
        do {
            try install()
            NSLog("\(Brand.name): repaired a stale hook path in settings.json")
        } catch {
            NSLog("\(Brand.name): could not repair stale hook: \(error)")
        }
    }

    /// Whether any of our hooks are registered but not at the current path.
    static func isStale() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]],
              preToolUse.contains(where: entryUsesOurHook) else { return false }
        return !preToolUse.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String) == expectedCommand
            } == true
        }
    }

    // MARK: - Internals

    /// Matches entries written by this version *and* by any previous name.
    ///
    /// The marker moves with the product name, so without the legacy list an
    /// upgrade can neither repair nor uninstall its own older hooks: they stay
    /// in settings.json pointing at a script the migration already moved, and
    /// every tool call then fails the hook. Matching is on the full command
    /// string, and the markers are specific enough not to collide with a user's
    /// own hooks living elsewhere in the same file.
    private static func entryUsesOurHook(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        let markers = [marker] + Brand.legacySlugs
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return markers.contains { command.contains($0) }
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        do {
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            throw InstallError(message:
                "\(settingsPath) is not plain JSON (comments/trailing commas aren't supported). " +
                "Fix it by hand or remove the extras, then re-run --install-hook. Nothing was changed.")
        }
    }

    private static func backupThenWrite(_ settings: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: settingsPath) {
            let backup = settingsPath + ".sentrynotch-bak"
            try? FileManager.default.removeItem(atPath: backup)
            try FileManager.default.copyItem(atPath: settingsPath, toPath: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }
}

/// Embedded fallback of the hook script, written to
/// the app's Application Support directory when no on-disk copy is found. The repo's
/// hooks/sentrynotch-hook.py is the readable source; keep this in sync with it.
private let embeddedHookScript = #"""
#!/usr/bin/env python3
"""Sentry Notch PreToolUse hook. Routes a pending tool call to the Sentry Notch app over
a unix socket and blocks for a decision. Fail-open: if anything goes wrong we
emit nothing and let Claude Code's normal permission flow proceed."""
import sys, os, json, socket, subprocess

SOCK = os.environ.get("SENTRYNOTCH_SOCK") or os.path.expanduser("__SOCKET_PATH__")
DECISION_TIMEOUT = 280.0
TERMINALS = ("ghostty", "warp", "iterm", "apple_terminal", "terminal",
             "wezterm", "kitty", "alacritty", "hyper", "tabby")

def defer():
    sys.exit(0)

def ancestry():
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
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason}}))
    sys.exit(0)

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        defer()
    if not os.path.exists(SOCK):
        defer()
    term_name, term_pid, claude_pid = ancestry()
    req = {"v": 1,
           "session_id": data.get("session_id", ""),
           "cwd": data.get("cwd", ""),
           "tool_name": data.get("tool_name", ""),
           "tool_input": data.get("tool_input", {}),
           "transcript_path": data.get("transcript_path", ""),
           "terminal": term_name,
           "terminal_pid": term_pid,
           "claude_pid": claude_pid}
    buf = b""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(SOCK)
        s.sendall((json.dumps(req) + "\n").encode())
        s.settimeout(DECISION_TIMEOUT)
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
    d = resp.get("decision", "ask")
    if d == "allow":
        decide("allow", resp.get("reason", "Allowed from Sentry Notch"))
    elif d == "deny":
        decide("deny", resp.get("reason", "Denied from Sentry Notch"))
    else:
        defer()

if __name__ == "__main__":
    main()
"""#

/// Embedded fallback of the lifecycle notifier. Mirror of
/// hooks/sentrynotch-notify.py.
private let embeddedNotifyScript = #"""
#!/usr/bin/env python3
"""Sentry Notch lifecycle hook (Stop / SessionEnd / Notification). Fire-and-forget
ping to the app. Never blocks, never fails a session."""
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
    req = {"kind": "event", "event": event,
           "session_id": data.get("session_id", ""),
           "cwd": data.get("cwd", ""),
           "message": data.get("message", "") or ""}
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
"""#
