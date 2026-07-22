import AppKit
import SentryNotchCore

/// Resolve the claude binary: $CLAUDE_NOTCH_BIN, then known locations, then PATH.
func resolveClaudePath() -> String {
    if let override = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BIN"],
       FileManager.default.isExecutableFile(atPath: override) {
        return override
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for path in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", "claude"]
    let pipe = Pipe()
    which.standardOutput = pipe
    try? which.run()
    which.waitUntilExit()
    if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
        return out
    }
    return "claude"
}

// CLI modes for the sensitive settings.json edits — run explicitly.
let arguments = CommandLine.arguments
if arguments.contains("--install-hook") {
    do {
        try HookInstaller.install()
        print("Sentry Notch hook installed.")
        print("  script:   \(HookInstaller.scriptPath)")
        print("  settings: \(HookInstaller.settingsPath) (backup: settings.json.sentrynotch-bak)")
        print("Interception is ON by default — toggle it in the island or the ✦ menu.")
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
if arguments.contains("--uninstall-hook") {
    do {
        try HookInstaller.uninstall()
        print("Sentry Notch hook removed from \(HookInstaller.settingsPath).")
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if arguments.contains("--diagnostics") {
    print(MainActor.assumeIsolated { Diagnostics.run() })
    exit(0)
}

// Remove the hook *and* the state directory. Separate from --uninstall-hook
// because the state directory holds the decision log, which is evidence from
// real engagements: deleting it is a decision the user must make explicitly,
// never a side effect of removing an integration.
if arguments.contains("--purge") {
    let dir = Brand.stateDir
    guard arguments.contains("--yes") else {
        print("""
        This deletes every trace of \(Brand.name) from this Mac:

          \(Brand.usingCustomStateDir ? "(hook entries left alone — custom state dir)" : "hook entries in " + HookInstaller.settingsPath)
          the whole state directory, including your decision log:
            \(dir)

        The decision log is your audit trail. Back it up first if you may need
        it. Re-run with --yes to go ahead:

          \(Bundle.main.bundlePath)/Contents/MacOS/\(Brand.displayDirName) --purge --yes
        """)
        exit(1)
    }
    // A relocated state dir means a throwaway instance. Removing its files is
    // fine; removing the *real* hook entries is not — that is the same mistake
    // that once took Claude Code down for a demo run.
    if Brand.usingCustomStateDir {
        print("Custom state dir — leaving hook configuration untouched.")
    } else {
        try? HookInstaller.uninstall()
    }
    do {
        try FileManager.default.removeItem(atPath: dir)
        print("Removed \(Brand.usingCustomStateDir ? "" : "hook entries and ")\(dir).")
    } catch {
        FileHandle.standardError.write(Data("could not remove \(dir): \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Inspect or set the login item without launching the UI.
//
// "It doesn't start at login" is a support question that can't be answered from
// a screenshot: the switch shows what macOS reports, but not *why*. This prints
// the raw status and the registered path, and can set the state directly, so
// the answer doesn't depend on clicking through a window.
if let i = arguments.firstIndex(of: "--login-item") {
    let verb = i + 1 < arguments.count ? arguments[i + 1] : "status"
    let item = MainActor.assumeIsolated { LoginItem() }
    switch verb {
    case "on", "off":
        MainActor.assumeIsolated { item.set(verb == "on") }
        if let f = MainActor.assumeIsolated({ item.failure }) {
            FileHandle.standardError.write(Data("login item \(verb) failed: \(f)\n".utf8))
            exit(1)
        }
    case "status": break
    default:
        FileHandle.standardError.write(Data("usage: --login-item [status|on|off]\n".utf8))
        exit(2)
    }
    let (status, warning) = MainActor.assumeIsolated {
        (item.statusDescription, item.locationWarning)
    }
    print("login item: \(status)")
    print("bundle:     \(Bundle.main.bundlePath)")
    if let warning { print("warning:    \(warning)") }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else, so a crash during setup is still recorded.
        CrashReporter.install()
        // A relocated state directory means this is a throwaway instance — a
        // demo, a screenshot run, a test. It must not rewrite the real hook
        // configuration in ~/.claude/settings.json, which is global and shared
        // with the user's actual installation. Doing so pointed the live hook
        // at a temporary directory and took Claude Code down until the entry
        // was removed by hand.
        if !Brand.usingCustomStateDir {
            try? HookInstaller.writeScript()   // migrate state + keep the script fresh
            HookInstaller.repairIfStale()      // an upgrade must not orphan the hook
        } else {
            NSLog("\(Brand.name): custom state dir — leaving hook configuration untouched")
        }
        let model = AppModel(socketPath: HookInstaller.socketPath, stateDir: HookInstaller.dir,
                             claudePath: resolveClaudePath())
        model.start()
        self.model = model
        self.controller = NotchController(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
