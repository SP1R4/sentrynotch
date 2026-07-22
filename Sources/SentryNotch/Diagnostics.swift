import Foundation
import AppKit
import ServiceManagement
import SentryNotchCore

/// One-command health dump, for support.
///
/// "It doesn't work" is unanswerable from a screenshot: the app depends on a
/// Claude Code hook, an Automation grant per target application, a per-browser
/// JavaScript setting, a login item, and a licence — each of which fails
/// independently and none of which is visible to the user. This prints all of
/// it in a form that can be pasted into an issue.
///
/// Two rules shape it:
///
/// - **It never prompts.** Permission is queried with `askUserIfNeeded: false`,
///   so running diagnostics cannot itself pop a consent dialog. A tool that
///   changes the state it is measuring is worse than none.
/// - **It never prints content.** Paths and counts, yes; command text, project
///   names, tab titles, or licence keys, never. Support output gets pasted into
///   public issue trackers, and this app's whole promise is that engagement
///   data stays on the machine.
enum Diagnostics {

    static func run() -> String {
        var out: [String] = []
        func section(_ s: String) { out.append("\n== \(s) ==") }
        func line(_ k: String, _ v: String) {
            out.append("  \(k.padding(toLength: max(k.count, 22), withPad: " ", startingAt: 0)) \(v)")
        }

        out.append("\(Brand.name) diagnostics")
        out.append(String(repeating: "=", count: 40))

        section("Build")
        line("version", UpdateChecker.currentVersion)
        line("bundle id", Bundle.main.bundleIdentifier ?? "-")
        line("bundle path", Bundle.main.bundlePath)
        line("installed in Applications", Bundle.main.bundlePath.contains("/Applications/") ? "yes" : "NO — login items and updates rely on a stable path")
        line("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        line("signed", codesignSummary())

        section("State")
        let dir = Brand.stateDir
        line("state dir", dir)
        line("custom state dir", Brand.usingCustomStateDir ? "yes (SENTRYNOTCH_STATE_DIR)" : "no")
        for name in ["decisions.jsonl", "rules.json", "settings.json", "tokens.jsonl"] {
            line(name, fileSummary("\(dir)/\(name)"))
        }
        let archives = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { logArchiveIndex($0, stem: "decisions") != nil } ?? []
        line("rotated log archives", "\(archives.count)")

        section("Claude Code hook")
        line("settings.json", HookInstaller.settingsPath)
        let hook = hookSummary()
        line("installed", hook.installed ? "yes" : "NO")
        line("command", hook.command ?? "-")
        line("path quoted", hook.quoted ? "yes" : (hook.installed ? "NO — breaks on paths with spaces" : "-"))
        line("script present", FileManager.default.isReadableFile(atPath: HookInstaller.scriptPath) ? "yes" : "NO")
        line("stale", HookInstaller.isStale() ? "YES — reinstall with --install-hook" : "no")
        line("socket", FileManager.default.fileExists(atPath: Brand.socketPath) ? "present" : "absent (created at launch)")

        section("Automation permission (no prompts)")
        for (label, id) in [("Spotify", MusicSource.spotify.bundleID),
                            ("Music", MusicSource.appleMusic.bundleID)] {
            line(label, permissionSummary(id))
        }
        for b in Browser.allCases where isInstalled(b.bundleID) {
            line(b.appName, permissionSummary(b.bundleID) + (isRunning(b.bundleID) ? " (running)" : ""))
        }

        section("Login item")
        line("status", loginItemSummary())

        section("Displays")
        line("screens", "\(NSScreen.screens.count)")
        line("notch display", NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } ? "present" : "none — island sits under the menu bar")

        section("Last crash")
        line("log", CrashReporter.crashLogPath)
        if let crash = CrashReporter.lastCrash(maxBytes: 1500) {
            out.append(crash)
        } else {
            line("recorded", "none")
        }

        out.append("\nPaths and counts only — no commands, project names, tab titles, or licence keys.")
        return out.joined(separator: "\n")
    }

    // MARK: - Probes

    enum AutomationStatus: Equatable {
        case granted, denied, notRunning, notAsked, unknown

        var label: String {
            switch self {
            case .granted:    return "granted"
            case .denied:     return "denied"
            case .notRunning: return "not running"
            case .notAsked:   return "not yet asked"
            case .unknown:    return "unknown"
            }
        }
    }

    /// Query TCC *without* asking. `askUserIfNeeded: false` is the whole point:
    /// a probe that raises a consent dialog changes the state it reports, and
    /// the permissions panel would prompt for every app just by being opened.
    static func automationStatus(_ bundleID: String) -> AutomationStatus {
        guard !bundleID.isEmpty else { return .unknown }
        var target = AEAddressDesc()
        var bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, &bytes, bytes.count, &target) == noErr else {
            return .unknown
        }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr:                            return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound):           return .notRunning
        case -1744:                            return .notAsked
        default:                               return .unknown
        }
    }

    private static func permissionSummary(_ bundleID: String) -> String {
        switch automationStatus(bundleID) {
        case .denied: return "DENIED — System Settings ▸ Privacy & Security ▸ Automation"
        case let s:   return s.label
        }
    }

    static func isAppInstalled(_ bundleID: String) -> Bool { isInstalled(bundleID) }

    private static func hookSummary() -> (installed: Bool, command: String?, quoted: Bool) {
        guard let data = FileManager.default.contents(atPath: HookInstaller.settingsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return (false, nil, false) }
        for entry in pre {
            for h in (entry["hooks"] as? [[String: Any]]) ?? [] {
                if let cmd = h["command"] as? String, cmd.contains(Brand.hookMarker) {
                    return (true, cmd, cmd.contains("'"))
                }
            }
        }
        return (false, nil, false)
    }

    private static func loginItemSummary() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "not registered"
        case .requiresApproval: return "BLOCKED — System Settings ▸ General ▸ Login Items"
        case .notFound:         return "not found"
        @unknown default:       return "unknown"
        }
    }

    private static func codesignSummary() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", Bundle.main.bundlePath]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if text.contains("adhoc") { return "ad-hoc (unsigned — Gatekeeper will warn)" }
        if let r = text.range(of: "Authority=") {
            return String(text[r.upperBound...].prefix(while: { $0 != "\n" }))
        }
        return text.isEmpty ? "unsigned" : "signed"
    }

    private static func fileSummary(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return "absent" }
        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").count
        return lines.map { "\(size) bytes, \($0) lines" } ?? "\(size) bytes"
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
