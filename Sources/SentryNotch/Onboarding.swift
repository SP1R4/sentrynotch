import SwiftUI
import AppKit
import SentryNotchCore

/// First-run setup.
///
/// The app is inert until its hooks are registered in `~/.claude/settings.json`,
/// and that registration used to be reachable only through a `--install-hook`
/// CLI flag on the binary inside the bundle. A paying customer would install the
/// app, launch it, and get nothing — with no indication why.
///
/// This also exists as a trust moment. The product's pitch is that it sits
/// between an agent and your machine, so the one thing it must not do is edit
/// your config silently. The exact change is shown before anything is written,
/// the backup path is named, and declining is a first-class outcome.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// Whether the user has already made a choice about the hook.
    private var skipMarkerPath: String { "\(Brand.stateDir)/setup-dismissed" }

    var shouldShowAtLaunch: Bool {
        if HookInstaller.isInstalled() { return false }
        return !FileManager.default.fileExists(atPath: skipMarkerPath)
    }

    func markDismissed() {
        FileManager.default.createFile(atPath: skipMarkerPath, contents: Data())
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(model: model,
                                  onFinish: { [weak self] in self?.close() },
                                  onSkip: { [weak self] in self?.markDismissed(); self?.close() })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Set up \(Brand.name)"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 560, height: 560))
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var onFinish: () -> Void
    var onSkip: () -> Void

    @State private var installed = HookInstaller.isInstalled()
    @State private var error: String?
    @State private var working = false
    /// Briefly disables the primary button after the label changes, so one
    /// click can't act on two different actions.
    @State private var settling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CC.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if installed { installedState } else { setupState }
                }
                .padding(18)
            }
            Divider().overlay(CC.hairline)
            footer
        }
        .frame(minWidth: 540, minHeight: 520)
        .background(CC.ink)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Mark(color: model.settings.accentColor).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(CC.text)
                Text("A permission checkpoint for coding agents")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
            }
            Spacer()
            Sentinel(size: 30, color: model.settings.accentColor, mood: .idle)
                .frame(width: 30, height: 30)
        }
        .padding(18)
    }

    // MARK: - Not yet installed

    private var setupState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One change is needed before this can do anything.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)

            Text("Claude Code asks registered hooks for permission before it runs a tool. \(Brand.name) needs to register as one of those hooks — otherwise it can watch your sessions but never intercept anything.")
                .font(.system(size: 12)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)

            caption("WHAT GETS ADDED TO \(HookInstaller.settingsPath)")
            diffBlock

            caption("WHAT THIS MEANS")
            bullet("checkmark.shield", "Your existing hooks are untouched. Only entries matching \(Brand.slug) are ever added or removed.")
            bullet("arrow.uturn.backward", "A backup is written to settings.json.\(Brand.slug)-bak before any change.")
            bullet("bolt.fill", "Interception starts **on**, so prompts route here as soon as this is installed. Flip **Intercept** off in the notch at any time — the setting sticks.")
            bullet("exclamationmark.triangle", "If this app isn't running, the hook does nothing and Claude Code's own prompts take over. It fails open by design.")

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(CC.alarm)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CC.alarm.opacity(0.12)))
            }
        }
    }

    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(previewLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("+") ? Color.green.opacity(0.85) : CC.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CC.hairline, lineWidth: 1))
    }

    /// Shows the real command strings that will be written, not a sanitised
    /// illustration — the point is that the user can verify it.
    private var previewLines: [String] {
        ["  \"hooks\": {",
         "    \"PreToolUse\": [",
         "+     { \"matcher\": \"*\", \"hooks\": [",
         "+         { \"type\": \"command\",",
         "+           \"command\": \"python3 \\\"\(HookInstaller.scriptPath)\\\"\" } ] }",
         "    ],",
         "    \"Stop\" / \"SessionEnd\" / \"Notification\": [",
         "+     { \"hooks\": [",
         "+         { \"type\": \"command\",",
         "+           \"command\": \"python3 \\\"\(HookInstaller.notifyScriptPath)\\\"\" } ] }",
         "    ]",
         "  }"]
    }

    // MARK: - Installed

    private var installedState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hooks installed").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CC.text)
                    Text("Claude Code is routing tool calls here now.")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                }
                Spacer()
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

            caption("NEXT")
            bullet("switch.2", "**Intercept** is on. Prompts route here now. Turn it off in the notch if you want Claude Code to handle them itself.")
            bullet("keyboard", "⌘⇧Space opens the island from anywhere. ⌘1–⌘4 answer the top prompt.")
            bullet("scope", "Drop your engagement scope — one host, domain, or CIDR block per line — into scope.txt beside the app's data, and out-of-scope calls get flagged.")
            bullet("square.grid.2x2", "The dashboard (⌘,) has appearance, widgets, and analytics.")

            HStack(spacing: 8) {
                Button("Reveal data folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Brand.stateDir)
                }
                Button("Remove hooks") { uninstall() }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(model.settings.accentColor)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !installed {
                Button("Not now", action: onSkip)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CC.textDim)
            }
            Spacer()
            // The primary button swaps label and action when the install
            // succeeds. Without the settle delay the same click's mouse-up
            // lands on the freshly-rendered "Done" and closes the window before
            // the confirmation can be read — it looked like the window vanished
            // on install.
            Button(installed ? "Done" : "Install hooks") {
                if installed { onFinish() } else { install() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(settling ? model.settings.accentColor.opacity(0.5) : model.settings.accentColor))
            .disabled(working || settling)
            .opacity(working ? 0.6 : 1)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func install() {
        working = true
        error = nil
        do {
            try HookInstaller.install()
            installed = HookInstaller.isInstalled()
            if !installed {
                error = "The hooks were written but couldn't be read back. Check \(HookInstaller.settingsPath)."
            } else {
                settling = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settling = false }
            }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    private func uninstall() {
        do {
            try HookInstaller.uninstall()
            installed = HookInstaller.isInstalled()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Pieces

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(CC.textFaint)
            .padding(.top, 2)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle(model.settings.accentColor).frame(width: 16)
            Text(.init(text)).font(.system(size: 11)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
