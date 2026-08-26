import SwiftUI
import AppKit
import SentryNotchCore
import UniformTypeIdentifiers
import Carbon.HIToolbox

/// Owns the dashboard window (created lazily, reused). A normal titled window —
/// unlike the transparent notch panel — so it behaves like a settings window.
@MainActor
final class DashboardWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// CoreGraphics window number of the open dashboard, or nil. Used by the
    /// screenshot harness (`SENTRYNOTCH_DASHBOARD=1`) to grab exactly this
    /// window with `screencapture -l`.
    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DashboardView(model: model, settings: model.settings))
        let win = NSWindow(contentViewController: hosting)
        win.title = "\(Brand.name) — Dashboard"
        // Share the notch island's visual language: no titlebar chrome, the
        // warm near-black panel running edge to edge under the traffic lights.
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(srgbRed: 0.11, green: 0.105, blue: 0.10, alpha: 1) // CC.ink
        win.appearance = NSAppearance(named: .darkAqua)  // keep the traffic lights light-on-dark
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 580, height: 600))
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Appearance / Widgets / Plugins, driven by the registries in AppSettings.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// Opens on Activity: the log is what the product is for, and the settings
    /// tabs are things you touch once. `SENTRYNOTCH_TAB` overrides it, matching
    /// the existing `SENTRYNOTCH_EXPAND` dev flag, so a tab can be screenshotted
    /// without clicking through focus-stealing windows.
    @State private var tab: Tab =
        ProcessInfo.processInfo.environment["SENTRYNOTCH_TAB"]
            .flatMap { name in Tab.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }
        ?? .activity
    @State private var stats = AnalyticsSummary()
    @State private var tokens: [Tally] = []
    @State private var policySuggestions: [PolicySuggestion] = []
    @State private var replay: PolicyReplay?
    @State private var replaying = false
    @State private var integrity: AuditVerification?
    @State private var integrityLegacy = 0
    @State private var verifying = false
    @State private var reportFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var reportTo = Date()


    @StateObject private var loginItem = LoginItem()
    @State private var log: [ActivityEntry] = []
    @State private var filter = ActivityFilter()
    @State private var expanded: UUID?
    @State private var rules: [RuleUsage] = []
    /// Bumped on every load. A result whose generation no longer matches is
    /// from a superseded read and is dropped — without this, switching tabs
    /// quickly leaves two reads racing and the slower, older one wins.
    @State private var generation = 0
    @State private var scopeDraft = ""
    /// What is on disk. Dirty state is a comparison rather than a flag set by
    /// `onChange`, which also fires when the draft is first populated — that
    /// made the editor offer to save a file nobody had touched.
    @State private var scopeOriginal = ""
    @State private var scopeProbe = ""
    /// Automation statuses, resolved once per tab open rather than per render.
    /// Each query is a synchronous IPC to the TCC daemon; doing it inside the
    /// view body ran up to nine of them on every redraw of this tab.
    @State private var perms: [String: Diagnostics.AutomationStatus] = [:]
    /// True while the summon-shortcut recorder is listening for a keypress.
    @State private var recordingHotkey = false
    /// New-preset entry for the timer presets editor.
    @State private var newPreset = ""

    /// Each tab reads the whole log, so nothing is loaded until it is opened —
    /// and the read itself happens off the main actor, so a long history
    /// doesn't freeze the window while a tab opens.
    private func load(_ t: Tab) {
        generation += 1
        let gen = generation
        switch t {
        case .analytics:
            tokens = model.tokenTrend()
            Task { let v = await model.analyticsAsync(); if gen == generation { stats = v } }
        case .activity:
            Task { let v = await model.activityLogAsync(); if gen == generation { log = v } }
        case .rules:
            let keys = Set(model.alwaysAllowList)
            Task {
                let v = await model.ruleUsageReportAsync(rules: keys)
                if gen == generation { rules = v }
            }
        case .policy:
            Task {
                let v = await model.policySuggestionsAsync(existing: settings.policyRules)
                if gen == generation { policySuggestions = v }
            }
        case .scope:
            // Small file, read synchronously; and re-read on every open so an
            // edit made outside the app is never silently overwritten by a
            // stale draft.
            scopeDraft = model.scopeText()
            scopeOriginal = scopeDraft
        default: break
        }
    }

    /// Resolve every Automation status off the main actor, then publish once.
    private func loadPermissions() {
        let ids = [MusicSource.spotify.bundleID, MusicSource.appleMusic.bundleID]
            + Browser.allCases.filter { Diagnostics.isAppInstalled($0.bundleID) }.map(\.bundleID)
        Task.detached {
            let pairs = ids.map { ($0, Diagnostics.automationStatus($0)) }
            let resolved = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
            await MainActor.run { perms = resolved }
        }
    }

    /// Reload the rules list after a mutation, respecting the same guard.
    private func reloadRules() {
        generation += 1
        let gen = generation
        let keys = Set(model.alwaysAllowList)
        Task {
            let v = await model.ruleUsageReportAsync(rules: keys)
            if gen == generation { rules = v }
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case activity = "Activity", rules = "Rules", policy = "Policy", scope = "Scope"
        case analytics = "Analytics", replay = "Replay"
        case appearance = "Appearance", widgets = "Widgets", plugins = "Plugins"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().overlay(CC.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .activity:   activityTab
                    case .rules:      rulesTab
                    case .policy:     policyTab
                    case .scope:      scopeTab
                    case .appearance: appearanceTab
                    case .widgets:    widgetsTab
                    case .plugins:    pluginsTab
                    case .analytics:  analyticsTab
                    case .replay:     ReplayView(model: model)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(CC.ink)
        // Recompute only when the tab is opened — the log is read whole.
        .onChange(of: tab) { _, new in load(new) }
        .onAppear { load(tab) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The shield mark — the app's identity, matching the icon, the
            // island toolbar, and the README. The owl mascot stays the notch's
            // animated character; this brand surface uses the logo.
            Mark(color: settings.accentColor)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(CC.text)
                Text("Dashboard").font(.system(size: 11)).foregroundStyle(CC.textDim)
            }
            Spacer()
        }
        // Extra top inset clears the borderless titlebar's traffic lights, now
        // that the panel runs full height under them.
        .padding(.horizontal, 16).padding(.top, 28)
    }

    /// Custom tab strip — the stock `.segmented` picker paints its selection in
    /// the system accent (blue), which fights the coral brand. This tints the
    /// selected tab with the user's accent instead. Horizontally scrollable so
    /// it never clips on a narrow window.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    let selected = tab == t
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .white : CC.textDim)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                Capsule().fill(selected ? settings.accentColor : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Policy

    private var policyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !policySuggestions.isEmpty {
                caption("SUGGESTED FROM YOUR HISTORY")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Patterns you've consistently denied — one tap promotes them to a rule.")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    ForEach(policySuggestions) { s in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.rule.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                                Text(s.rationale).font(.system(size: 10)).foregroundStyle(CC.textDim)
                            }
                            Spacer()
                            Button {
                                settings.policyRules.append(s.rule)
                                policySuggestions.removeAll { $0.id == s.id }
                            } label: {
                                Label("Add", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(settings.accentColor))
                            }.buttonStyle(.plain)
                            Button { policySuggestions.removeAll { $0.id == s.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(CC.textFaint)
                            }.buttonStyle(.plain)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
                    }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
            }
            PolicyEditor(settings: settings)

            if !settings.policyRules.isEmpty {
                caption("REGRESSION TEST")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replay your decision history against these rules — what would they have changed?")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { runReplay() } label: {
                            Label(replaying ? "Replaying…" : "Test against history", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(settings.accentColor))
                        }.buttonStyle(.plain).disabled(replaying)
                        Spacer()
                    }
                    if let r = replay {
                        Text("Over **\(r.evaluated)** matched calls: **\(r.wouldDeny)** deny · **\(r.wouldPrompt)** ask · **\(r.wouldAllow)** allow")
                            .font(.system(size: 11)).foregroundStyle(CC.text)
                        if r.newlyCaught > 0 {
                            Label("\(r.newlyCaught) call\(r.newlyCaught == 1 ? "" : "s") you allowed would now be denied — caught", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(red: 0.35, green: 0.72, blue: 0.5))
                        }
                        if r.newlyAllowed > 0 {
                            Label("\(r.newlyAllowed) call\(r.newlyAllowed == 1 ? "" : "s") you denied would now be allowed — check this", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                        }
                        Text("Scope and host rules aren't replayable — the log doesn't retain hosts.")
                            .font(.system(size: 9)).foregroundStyle(CC.textFaint)
                    }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
            }
        }
    }

    private func runReplay() {
        replaying = true
        Task {
            let r = await model.policyReplayAsync(rules: settings.policyRules)
            replay = r
            replaying = false
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("ACCENT")
            HStack(spacing: 12) {
                ForEach(AccentChoice.allCases) { a in
                    Circle().fill(a.color).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(CC.text, lineWidth: settings.accent == a ? 2.5 : 0))
                        .overlay(settings.accent == a
                                 ? Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white) : nil)
                        .contentShape(Circle())
                        .onTapGesture { settings.accent = a }
                        .help(a.name)
                }
                Spacer()
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

            caption("NOTCH BACKGROUND")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ForEach(NotchBackground.allCases) { bg in
                        let swatch = bg.presetColor ?? (Color(hex: settings.notchBackgroundHex) ?? CC.ink)
                        Circle().fill(swatch).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(CC.hairline, lineWidth: 1))
                            .overlay(Circle().stroke(CC.text,
                                     lineWidth: settings.notchBackground == bg ? 2.5 : 0))
                            .overlay(bg == .custom
                                     ? Image(systemName: "eyedropper").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(CC.text) : nil)
                            .contentShape(Circle())
                            .onTapGesture { settings.notchBackground = bg }
                            .help(bg.name)
                    }
                    Spacer()
                }
                if settings.notchBackground == .custom {
                    ColorPicker("Custom colour", selection: Binding(
                        get: { Color(hex: settings.notchBackgroundHex) ?? CC.ink },
                        set: { settings.notchBackgroundHex = $0.hexString }))
                        .font(.system(size: 12)).foregroundStyle(CC.textDim)
                }
                Text("The top edge always stays near-black so the collapsed bar keeps blending into the physical notch.")
                    .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

            caption("MASCOT")
            toggleRow("Show the notch mascot", "Rides the wedges while a session is working", $settings.mascotEnabled)
            toggleRow("Tint per project", "Colour the mascot by project instead of the accent", $settings.mascotUsesProjectColor)
                .disabled(!settings.mascotEnabled).opacity(settings.mascotEnabled ? 1 : 0.5)

            caption("MOTION")
            motionRow

            caption("SHORTCUT")
            hotkeyRow

            caption("SOUND")
            toggleRow("Prompt pings", "Play a risk-differentiated sound on each new prompt", $settings.promptSounds)
            soundMenu("New prompt", $settings.soundPrompt)
                .disabled(!settings.promptSounds).opacity(settings.promptSounds ? 1 : 0.5)
            soundMenu("Session finished", $settings.soundFinished)
            soundMenu("Needs input", $settings.soundNeedsInput)
            soundMenu("Timer finished", $settings.soundTimer)
            Text("High-risk and out-of-scope prompts always use a fixed alert, so a preference can't quiet the ping that matters most.")
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)

            caption("MULTIPLE DISPLAYS")
            toggleRow("Follow the pointer across screens",
                      "Off (default): the island only ever appears on the display with a physical notch. On: it follows your pointer to whichever screen you're using, notch or not.",
                      $settings.followPointerAcrossScreens)
        }
    }

    /// How the continuously-animating views behave, resolving `.system` against
    /// macOS's Reduce Motion setting.
    private var motionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Animations").font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
                Text("System follows macOS Reduce Motion; the mascot and marquee obey this.")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ForEach(AnimationMode.allCases) { m in
                chip(m.label, on: settings.animationMode == m) { settings.animationMode = m }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    /// Global summon shortcut with a click-to-record control.
    private var hotkeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summon the notch").font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
                Text(recordingHotkey ? "Press a shortcut, or Esc to cancel"
                                     : "Show or hide the island from any app")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isDefaultHotkey && !recordingHotkey {
                Button("Reset") {
                    settings.hotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
                    settings.hotkeyModifiers = AppSettings.defaultHotkeyModifiers
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CC.textDim)
            }
            Button(recordingHotkey ? "Press keys…" : hotkeyDisplay) { startRecordingHotkey() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recordingHotkey ? .white : settings.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(recordingHotkey ? settings.accentColor : CC.surfaceHi))
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private var isDefaultHotkey: Bool {
        settings.hotkeyKeyCode == AppSettings.defaultHotkeyKeyCode
            && settings.hotkeyModifiers == AppSettings.defaultHotkeyModifiers
    }

    private var hotkeyDisplay: String {
        modifierGlyphs(settings.hotkeyModifiers) + keyName(settings.hotkeyKeyCode)
    }

    /// Listen for one modified keypress via a local monitor, then rebind.
    private func startRecordingHotkey() {
        guard !recordingHotkey else { return }
        recordingHotkey = true
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels without changing anything.
            if event.keyCode == 53 {
                recordingHotkey = false
                if let m = monitor { NSEvent.removeMonitor(m) }
                return nil
            }
            let mods = carbonModifiers(event.modifierFlags)
            // Require at least one modifier so the recorder can't swallow a
            // bare key and leave the app impossible to type in.
            guard mods != 0 else { return nil }
            settings.hotkeyKeyCode = UInt32(event.keyCode)
            settings.hotkeyModifiers = mods
            recordingHotkey = false
            if let m = monitor { NSEvent.removeMonitor(m) }
            return nil
        }
    }

    private func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private func modifierGlyphs(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey)  != 0 { s += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    private func keyName(_ code: UInt32) -> String {
        Self.keyNames[code] ?? "Key \(code)"
    }

    /// US-layout virtual key codes → labels, enough to render any shortcut the
    /// recorder is likely to capture.
    private static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        25: "9", 29: "0",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
    ]

    /// A named system sound picker with an inline preview.
    private func soundMenu(_ title: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
            Spacer(minLength: 4)
            Button {
                NSSound(named: binding.wrappedValue)?.play()
            } label: {
                Image(systemName: "play.circle").font(.system(size: 14)).foregroundStyle(CC.textDim)
            }
            .buttonStyle(.plain).help("Preview")
            Menu {
                ForEach(Self.systemSounds, id: \.self) { name in
                    Button(name) { binding.wrappedValue = name; NSSound(named: name)?.play() }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(binding.wrappedValue).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(settings.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(CC.surface))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    /// Named sounds under /System/Library/Sounds, the set NSSound(named:)
    /// resolves. Read once.
    private static let systemSounds: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    // MARK: - Widgets

    private var widgetsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("NOTCH WIDGETS")
            ForEach(WidgetSpec.all) { w in
                toggleRow(w.name, w.detail, settings.widgetBinding(w.id))
                if w.id == "timer" && settings.widgetOn("timer") { timerPresetsRow }
                if w.id == "spotify" && settings.widgetOn("spotify") {
                    musicSourceRow
                    nowPlayingOptions
                }
            }
        }
    }

    /// Editable timer quick-picks. Tap a chip to remove it; add via the field.
    private var timerPresetsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Presets").font(.system(size: 11)).foregroundStyle(CC.textDim)
                Spacer(minLength: 4)
                ForEach(settings.validTimerPresets, id: \.self) { m in
                    Button { removePreset(m) } label: {
                        HStack(spacing: 3) {
                            Text("\(m)m").font(.system(size: 10, weight: .semibold))
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(CC.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(CC.surfaceHi))
                    }
                    .buttonStyle(.plain).help("Remove")
                }
            }
            HStack(spacing: 8) {
                TextField("Add minutes", text: $newPreset)
                    .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(CC.text)
                    .frame(width: 90).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(CC.surfaceHi))
                    .onSubmit(addPreset)
                Button("Add", action: addPreset)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settings.accentColor)
                Spacer()
                Text("1–600 min, up to 6").font(.system(size: 9)).foregroundStyle(CC.textFaint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
        .padding(.leading, 16)
    }

    private func addPreset() {
        defer { newPreset = "" }
        guard let m = Int(newPreset.trimmingCharacters(in: .whitespaces)), m >= 1, m <= 600 else { return }
        settings.timerPresets = Set(settings.timerPresets).union([m]).sorted()
    }

    private func removePreset(_ m: Int) {
        let remaining = settings.timerPresets.filter { $0 != m }
        // Keep at least one, or validTimerPresets falls back to the defaults and
        // the removal looks like it did nothing.
        if !remaining.isEmpty { settings.timerPresets = remaining }
    }

    /// Per-card now-playing options, shown under the widget toggle.
    private var nowPlayingOptions: some View {
        VStack(spacing: 8) {
            miniToggle("Colour from cover art", $settings.nowPlayingUseArtColor)
            miniToggle("Tint the whole panel from the cover", $settings.panelTintFromArt)
            miniToggle("Scroll long titles", $settings.nowPlayingMarquee)
            miniToggle("Show the volume slider", $settings.nowPlayingShowVolume)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
        .padding(.leading, 16)
    }

    private func miniToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(CC.textDim)
            Spacer(minLength: 4)
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini)
                .tint(settings.accentColor).labelsHidden()
        }
    }

    /// Which player the now-playing widget follows.
    ///
    /// Auto is the default and covers almost everyone: the widget follows
    /// whichever app is actually playing. Pinning matters when both are open
    /// and the wrong one keeps winning.
    private var musicSourceRow: some View {
        HStack(spacing: 8) {
            Text("Source").font(.system(size: 11)).foregroundStyle(CC.textDim)
            Spacer(minLength: 4)
            sourceChip("Auto", on: settings.musicSource == nil) { settings.musicSource = nil }
            ForEach(MusicSource.allCases) { s in
                sourceChip(s.label, on: settings.musicSource == s) { settings.musicSource = s }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
        .padding(.leading, 16)
    }

    private func sourceChip(_ title: String, on: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .black : CC.textDim)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(on ? settings.accentColor : CC.surfaceHi))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Plugins

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("SECURITY POSTURE")
            postureRow

            caption("STARTUP")
            startupRow

            caption("PERMISSIONS")
            permissionsPanel

            caption("CAPABILITY MODULES")
            ForEach(PluginSpec.all) { p in
                toggleRow(p.name, p.detail, settings.pluginBinding(p.id))
            }
            Text("The permission broker itself is always on — arm it with the Intercept switch in the notch.")
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                .padding(.top, 2)

            caption("OFF-BOX ALERTS")
            alertsPanel

            caption("HONEYTOKENS")
            HoneytokenEditor(settings: settings)
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

            caption("TOKEN GOVERNOR")
            tokenGovernorPanel
        }
    }

    private var tokenGovernorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow("Warn on a token budget",
                      "Alert when a session's context tokens cross the ceiling",
                      $settings.tokenGuardEnabled)
            HStack(spacing: 8) {
                Text("Budget").font(.system(size: 11)).foregroundStyle(CC.textDim)
                Menu {
                    ForEach([200_000, 500_000, 800_000, 1_000_000, 1_500_000, 2_000_000], id: \.self) { b in
                        Button("\(b / 1000)k tokens") { settings.tokenBudget = b }
                    }
                } label: {
                    Text("\(settings.tokenBudget / 1000)k tokens")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(CC.text)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(CC.surfaceHi))
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .disabled(!settings.tokenGuardEnabled).opacity(settings.tokenGuardEnabled ? 1 : 0.5)
            toggleRow("Auto-arm panic when exceeded",
                      "Off (default): warn only. On: crossing the budget denies everything until you release.",
                      $settings.tokenGuardPanics)
                .disabled(!settings.tokenGuardEnabled).opacity(settings.tokenGuardEnabled ? 1 : 0.5)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private var alertsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow("Post alerts to a webhook",
                      "Ping a URL (e.g. your Telegram admin bot) on high-signal prompts",
                      $settings.alertsEnabled)
            HStack(spacing: 8) {
                Text("URL").font(.system(size: 11)).foregroundStyle(CC.textDim).frame(width: 34, alignment: .leading)
                TextField("https://…/api/send_admins", text: $settings.alertWebhookURL)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CC.text).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(CC.surfaceHi))
            }
            .disabled(!settings.alertsEnabled).opacity(settings.alertsEnabled ? 1 : 0.5)
            toggleRow("Alert on every prompt",
                      "Off (default): only high-risk / out-of-scope prompts fire",
                      $settings.alertsAllPrompts)
                .disabled(!settings.alertsEnabled).opacity(settings.alertsEnabled ? 1 : 0.5)
            HStack {
                Button { model.sendTestAlert() } label: {
                    Label("Send test alert", systemImage: "paperplane")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
                }.buttonStyle(.plain)
                    .disabled(!settings.alertsEnabled || settings.alertWebhookURL.isEmpty)
                Spacer()
            }
            Text("The alert carries a truncated summary — it leaves your machine, so it never ships a full command or file body.")
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One-tap posture over the two risk flags, with the individual switches
    /// exposed below for anyone who wants a custom mix.
    private var postureRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(SecurityPosture.presets) { p in
                    chip(p.label, on: model.securityPosture == p) { model.applyPosture(p) }
                }
                Spacer()
                if model.securityPosture == .custom {
                    Text("Custom").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(settings.accentColor)
                }
            }
            Text(model.securityPosture.detail)
                .font(.system(size: 11)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(CC.hairline)
            miniToggle("Auto-approve read-only tools", $model.autoAllowReadOnly)
            miniToggle("Deny risky calls left unanswered (fail closed)", $model.failClosedRisky)
            miniToggle("Intercept new sessions by default", $model.interceptNewSessions)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    /// What macOS has actually granted, read without prompting.
    ///
    /// These are requested lazily — only when you switch on the feature that
    /// needs one — so "not yet asked" is the normal state for anything you
    /// don't use, not a fault. Showing them together exists because a denied
    /// grant is otherwise invisible: the widget just quietly says nothing is
    /// playing.
    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow("Spotify", MusicSource.spotify.bundleID)
            permissionRow("Music", MusicSource.appleMusic.bundleID)
            ForEach(Browser.allCases.filter { Diagnostics.isAppInstalled($0.bundleID) }) { b in
                permissionRow(b.appName, b.bundleID)
            }
            HStack(spacing: 8) {
                Button("Open Automation settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(settings.accentColor)
                Spacer()
                Button("Copy diagnostics") {
                    let text = Diagnostics.run()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(settings.accentColor)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private func permissionRow(_ name: String, _ bundleID: String) -> some View {
        let st = perms[bundleID] ?? .unknown
        return HStack(spacing: 8) {
            Circle()
                .fill(st == .granted ? Color.green : st == .denied ? .red : CC.textFaint)
                .frame(width: 6, height: 6)
            Text(name).font(.system(size: 11)).foregroundStyle(CC.text)
            Spacer()
            Text(st.label).font(.system(size: 10))
                .foregroundStyle(st == .denied ? .red : CC.textDim)
        }
    }

    /// Launch-at-login. Reads through to the system rather than to a stored
    /// preference, so it can never claim to be on when macOS says otherwise.
    private var startupRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at login").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CC.text)
                    Text("Launch \(Brand.name) automatically when you sign in to this Mac")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SwitchToggle(
                    isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }),
                    tint: settings.accentColor)
                    .disabled(loginItem.needsApproval)
                    .opacity(loginItem.needsApproval ? 0.4 : 1)
            }

            if loginItem.needsApproval {
                notice("Blocked in System Settings. macOS is holding this login item until you allow it.",
                       tint: .orange, action: ("Open Login Items", loginItem.openSystemSettings))
            }
            if let f = loginItem.failure {
                notice("Couldn't change the login item: \(f)", tint: .red, action: nil)
            }
            // Shown whenever the location is wrong, not only when switching on:
            // a login item registered earlier from a since-moved bundle is
            // already broken, and staying quiet about it is how the user finds
            // out by it simply not starting one morning.
            if let w = loginItem.locationWarning {
                notice(w, tint: .orange, action: nil)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
        .onAppear { loginItem.refresh() }
        // The user can flip this in System Settings behind our back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            loadPermissions()
        }
    }

    private func notice(_ text: String, tint: Color,
                        action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(settings.accentColor)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.12)))
    }

    // MARK: - Activity

    /// The decision log, browsable. The aggregate counts on the Analytics tab
    /// answer "how much"; this answers "what exactly did it do", which is the
    /// question that matters when writing something up after the fact.
    private var activityTab: some View {
        let shown = filterActivity(log, filter)
        let facets = activityFacets(log)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                    .foregroundStyle(CC.textFaint)
                TextField("Search commands and tools", text: $filter.text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(CC.text)
                if filter.isActive {
                    Button("Clear") { filter = ActivityFilter() }
                        .buttonStyle(.plain).font(.system(size: 10))
                        .foregroundStyle(settings.accentColor)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(CC.surface))

            HStack(spacing: 6) {
                facetMenu("Project", facets.projects, $filter.project)
                facetMenu("Tool", facets.tools, $filter.tool)
                facetMenu("Outcome", ["allow", "deny", "timeout"], $filter.outcome)
                chip("Flagged", on: filter.flaggedOnly) { filter.flaggedOnly.toggle() }
                chip("Manual", on: filter.manualOnly) { filter.manualOnly.toggle() }
            }

            Text(countLabel(shown.count, of: log.count))
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)

            if log.isEmpty {
                Text("No decisions recorded yet. Arm Intercept and the log fills in as you answer prompts.")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shown.isEmpty {
                Text("Nothing matches that filter.")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
            } else {
                // Capped for render cost, and the cap is stated rather than
                // silently applied — a truncated list that looks complete is
                // worse than no list when it is being used as evidence.
                LazyVStack(spacing: 4) {
                    ForEach(shown.prefix(400)) { row in activityRow(row) }
                }
                if shown.count > 400 {
                    Text("Showing the newest 400 of \(shown.count) matches — narrow the filter to see more, or use the engagement report on the Analytics tab for the full set.")
                        .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func countLabel(_ shown: Int, of total: Int) -> String {
        filter.isActive ? "\(shown) of \(total) calls" : "\(total) calls"
    }

    private func activityRow(_ r: ActivityEntry) -> some View {
        let isOpen = expanded == r.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(outcomeTint(r)).frame(width: 6, height: 6)
                Text(r.clock).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CC.textFaint).frame(width: 34, alignment: .leading)
                Text(r.tool).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CC.text).frame(width: 62, alignment: .leading)
                Text(r.summary).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CC.textDim).lineLimit(1)
                Spacer(minLength: 4)
                if r.isFlagged {
                    Text(r.risk).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(r.risk == "danger" ? CC.alarm : .orange)
                }
                if r.isAuto {
                    Text("auto").font(.system(size: 9)).foregroundStyle(CC.textFaint)
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    detailLine("when", r.ts)
                    detailLine("project", r.cwd.isEmpty ? r.project : r.cwd)
                    detailLine("outcome", r.isAuto ? "\(r.outcome) (automatic)" : r.outcome)
                    if !r.key.isEmpty { detailLine("rule key", r.key) }
                    Text(r.summary).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CC.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isOpen ? CC.surfaceHi : CC.surface))
        .contentShape(Rectangle())
        .onTapGesture { expanded = isOpen ? nil : r.id }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(CC.textFaint)
                .frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 10)).foregroundStyle(CC.textDim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Red means *blocked*, amber means *allowed but risky*, green means routine.
    ///
    /// These were both red, which made a denial and a risky call you approved
    /// anyway indistinguishable at a glance — the single most important
    /// difference in the whole list, since one is the tool working and the
    /// other is the thing you'd want to explain in a report.
    private func outcomeTint(_ r: ActivityEntry) -> Color {
        switch r.outcome {
        case "deny": return .red
        case "timeout": return CC.textFaint
        default: return r.isFlagged ? .orange : .green
        }
    }

    private func facetMenu(_ title: String, _ options: [String],
                           _ binding: Binding<String?>) -> some View {
        Menu {
            Button("All \(title.lowercased())s") { binding.wrappedValue = nil }
            Divider()
            ForEach(options.prefix(30), id: \.self) { o in
                Button(o) { binding.wrappedValue = o }
            }
        } label: {
            HStack(spacing: 3) {
                Text(binding.wrappedValue ?? title)
                    .font(.system(size: 10, weight: binding.wrappedValue == nil ? .regular : .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(binding.wrappedValue == nil ? CC.textDim : settings.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(CC.surface))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .black : CC.textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(on ? settings.accentColor : CC.surface))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rules

    /// Standing allows, with what each has actually done since it was granted.
    ///
    /// These are the app's main security-relevant mutable state and they
    /// accumulate silently. Reviewing them belongs somewhere with room, not in
    /// the notch panel.
    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("STANDING ALLOWS")
            if rules.isEmpty {
                Text("No standing rules. Calls you approve with Always will appear here, with what they've done since.")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let unused = rules.filter(\.isUnused).count
                Text(unused > 0
                     ? "\(rules.count) rule\(rules.count == 1 ? "" : "s") — \(unused) never used since granted, listed first."
                     : "\(rules.count) rule\(rules.count == 1 ? "" : "s"), all in use.")
                    .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(rules) { rule in ruleRow(rule) }
                Text("Revoking is immediate. The next matching call asks again; nothing already approved is undone.")
                    .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func ruleRow(_ rule: RuleUsage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.tool).font(.system(size: 10)).foregroundStyle(CC.textFaint)
                    // A rule key is derived from a command, so it can be
                    // arbitrarily long text. Truncate in the middle rather than
                    // letting one pathological key wrap to three lines and push
                    // the whole list around.
                    Text(rule.label).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CC.text)
                        .lineLimit(1).truncationMode(.middle)
                        .help(rule.key)
                    if rule.isUnused {
                        Text("unused").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }
                Text(ruleDetail(rule)).font(.system(size: 10)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Revoke") {
                model.revokeAlways(rule.key)
                reloadRules()
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.red.opacity(0.14)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
    }

    private func ruleDetail(_ r: RuleUsage) -> String {
        var bits: [String] = []
        if let g = r.grantedAt { bits.append("granted \(String(g.prefix(10)))") }
        else { bits.append("granted before this was recorded") }
        if let s = r.source { bits.append("via \(s)") }
        bits.append(r.firedSince == 0
                    ? "never used since"
                    : "used \(r.firedSince)× since"
                      + (r.lastUsed.map { ", last \(String($0.prefix(10)))" } ?? ""))
        return bits.joined(separator: " · ")
    }

    // MARK: - Scope

    /// Edit the engagement boundary, and see what actually took effect.
    ///
    /// The review beside the editor is the point. A scope file is only useful
    /// if every line in it is doing something, and an unparseable line used to
    /// vanish without a word — leaving the operator believing a range was
    /// covered when the guard would never flag it.
    private var scopeTab: some View {
        let lines = reviewScope(scopeDraft)
        let bad = lines.filter(\.isInvalid)
        let good = lines.filter(\.isTarget)
        return VStack(alignment: .leading, spacing: 12) {
            caption("ENGAGEMENT SCOPE")
            Text("One target per line: a domain, a host, an IPv4 address, a CIDR block, or a dotted prefix. Lines beginning # are notes. Anything reaching outside these is flagged, and scope overrides every convenience rule you've set.")
                .font(.system(size: 11)).foregroundStyle(CC.textDim)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $scopeDraft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CC.hairline))


            HStack(spacing: 8) {
                Text(good.isEmpty
                     ? "No active targets — the scope guard is off."
                     : "\(good.count) active target\(good.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(good.isEmpty ? .orange : CC.textDim)
                Spacer()
                if scopeDraft != scopeOriginal {
                    Button("Save & apply") {
                        if model.saveScope(scopeDraft) { scopeOriginal = scopeDraft }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(settings.accentColor))
                } else {
                    Text("saved").font(.system(size: 10)).foregroundStyle(CC.textFaint)
                }
            }

            if !bad.isEmpty {
                caption("IGNORED LINES")
                Text("These are not in force. A scope file that silently drops a line is how a target ends up unprotected.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(bad) { l in
                    HStack(alignment: .top, spacing: 8) {
                        Text("line \(l.number)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CC.textFaint).frame(width: 52, alignment: .leading)
                        Text(l.text.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(CC.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(scopeReason(l)).font(.system(size: 10)).foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
                }
            }

            caption("TEST A HOST")
            Text("Check a host against the scope that is currently saved and in force — not the draft above.")
                .font(.system(size: 10)).foregroundStyle(CC.textFaint)
            HStack(spacing: 8) {
                TextField("api.target.com", text: $scopeProbe)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CC.surface))
                if !scopeProbe.trimmingCharacters(in: .whitespaces).isEmpty {
                    let host = scopeProbe.trimmingCharacters(in: .whitespaces)
                    let inScope = model.scopeCovers(host)
                    Text(model.activeScopeTargets == 0 ? "no scope set"
                         : (inScope ? "in scope" : "OUT OF SCOPE"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(model.activeScopeTargets == 0 ? CC.textFaint
                                         : (inScope ? .green : .red))
                }
            }

            if !good.isEmpty {
                caption("IN FORCE")
                ForEach(good) { l in
                    HStack(spacing: 8) {
                        Text(l.text.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(CC.text)
                        Spacer(minLength: 6)
                        Text(scopeDescription(l)).font(.system(size: 10)).foregroundStyle(CC.textDim)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(CC.surface))
                }
            }
        }
    }

    private func scopeReason(_ l: ScopeLine) -> String {
        if case let .invalid(why) = l.kind { return why }
        return ""
    }
    private func scopeDescription(_ l: ScopeLine) -> String {
        if case let .target(d) = l.kind { return d }
        return ""
    }

    // MARK: - Analytics

    private var analyticsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if stats.total == 0 {
                caption("DECISIONS")
                Text("No decisions recorded yet. Arm Intercept and the log fills in as you answer prompts.")
                    .font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                caption("DECISIONS")
                HStack(spacing: 8) {
                    stat("\(stats.total)", "total")
                    stat("\(stats.allowed)", "allowed", .green)
                    stat("\(stats.denied)", "denied", .red)
                    stat("\(stats.risky)", "high risk", CC.alarm)
                }
                HStack(spacing: 8) {
                    stat(pct(stats.autoRate), "handled for you", settings.accentColor)
                    stat(pct(stats.denyRate), "of prompts denied", settings.accentColor)
                    stat("\(stats.deferred)", "deferred")
                }

                caption("DECISIONS — LAST 14 DAYS")
                sparkline

                if !tokens.isEmpty {
                    caption("PEAK CONTEXT TOKENS PER DAY")
                    bars(Array(tokens.suffix(7).reversed()), format: tokenLabel)
                }

                caption("BUSIEST TOOLS")
                bars(stats.byTool)

                caption("BUSIEST PROJECTS")
                bars(stats.byProject)

                caption("AUDIT INTEGRITY")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every decision is HMAC-chained to the previous one. Verify recomputes the chain and reports the first altered, removed, or reordered record.")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { verifyIntegrity() } label: {
                            Label(verifying ? "Verifying…" : "Verify chain", systemImage: "checkmark.seal")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(settings.accentColor))
                        }.buttonStyle(.plain).disabled(verifying)
                        Spacer()
                    }
                    if let v = integrity {
                        if v.intact {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                Text("\(v.total) records — chain intact"
                                     + (integrityLegacy > 0 ? " · \(integrityLegacy) legacy record\(integrityLegacy == 1 ? "" : "s") not covered" : ""))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.35, green: 0.72, blue: 0.5))
                        } else {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.octagon.fill")
                                Text("Chain breaks at record \(v.firstBreak ?? 0)\(v.breakTimestamp.map { " (\($0))" } ?? "") — a record was altered, removed, or reordered.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        }
                        Text("Head \(String(model.auditHeadMAC().prefix(16)))… — anchor this off-box to catch a full-log rewrite.")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(CC.textFaint)
                            .textSelection(.enabled)
                    }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

                caption("ENGAGEMENT REPORT")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export every recorded decision for a date range as Markdown — denied calls, high-risk calls, and per-project volume. Suitable for attaching to an engagement deliverable.")
                        .font(.system(size: 11)).foregroundStyle(CC.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        DatePicker("", selection: $reportFrom, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact)
                        Text("to").font(.system(size: 11)).foregroundStyle(CC.textFaint)
                        DatePicker("", selection: $reportTo, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact)
                        Spacer()
                        Button("Export…") { exportReport() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(settings.accentColor))
                    }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
            }
        }
    }

    private func verifyIntegrity() {
        verifying = true
        Task {
            let (r, legacy) = await model.verifyAuditAsync()
            integrity = r
            integrityLegacy = legacy
            verifying = false
        }
    }

    /// Write the report wherever the user chooses. Deliberately a save panel
    /// rather than a fixed location: this contains client hostnames and command
    /// lines, so where it lands is the operator's call, not ours.
    private func exportReport() {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let report = EngagementReport(
            title: "Agent activity report",
            from: day.string(from: reportFrom),
            to: day.string(from: reportTo),
            rows: model.decisionRows())

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let text = report.markdown(generated: stamp.string(from: Date()))

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-activity-\(day.string(from: reportTo)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.message = "This report can contain client hostnames and command lines."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A full 14-slot calendar window ending today, so a sparse log reads as
    /// "quiet days" rather than a lone bar floating in an empty box.
    /// `stats.byDay` only carries days that had activity; the gaps are filled
    /// here (the summariser stays clock-free by design).
    private var last14Days: [Tally] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let counts = Dictionary(uniqueKeysWithValues: stats.byDay.map { ($0.name, $0.count) })
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let key = fmt.string(from: day)
            return Tally(name: key, count: counts[key] ?? 0)
        }
    }

    private var sparkline: some View {
        let days = last14Days
        let peakDay = days.max { $0.count < $1.count }
        let peak = max(1, peakDay?.count ?? 1)
        return VStack(spacing: 6) {
            // Peak read-out, so the tallest bar has a number without hovering.
            HStack {
                Spacer()
                Text("peak ")
                    .font(.system(size: 10)).foregroundStyle(CC.textDim)
                + Text("\(peak)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(settings.accentColor)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { (d: Tally) in
                    let h: CGFloat = d.count == 0 ? 3 : max(6, 44 * CGFloat(d.count) / CGFloat(peak))
                    RoundedRectangle(cornerRadius: 2.5)
                        // Reserve the saturated accent for the busiest day; the
                        // rest sit back but stay legible, and empty days are a
                        // faint baseline tick.
                        .fill(d.count == 0 ? CC.textFaint
                              : settings.accentColor.opacity(d.count == peak ? 0.95 : 0.62))
                        .frame(maxWidth: 26)
                        .frame(height: h)
                        .frame(maxWidth: .infinity)
                        .help("\(d.name): \(d.count)")
                }
            }
            .frame(height: 44)
            Rectangle().fill(CC.hairline).frame(height: 1)
            HStack {
                Text(days.first.map { String($0.name.suffix(5)) } ?? "")
                Spacer()
                Text("today")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(CC.textFaint)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private func tokenLabel(_ n: Int) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M" : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    private func bars(_ items: [Tally], format: ((Int) -> String)? = nil) -> some View {
        let peak: Int = max(1, items.map { $0.count }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { (it: Tally) in
                HStack(spacing: 8) {
                    Text(it.name).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CC.text).frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        // Busiest row saturated, the rest dimmed — a hierarchy
                        // rather than one flat wall of coral.
                        Capsule().fill(settings.accentColor.opacity(it.count == peak ? 0.9 : 0.55))
                            .frame(width: max(3, geo.size.width * CGFloat(it.count) / CGFloat(peak)))
                    }
                    .frame(height: 8)
                    Text(format?(it.count) ?? "\(it.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CC.textDim).frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private func stat(_ value: String, _ label: String, _ tint: Color = CC.text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(tint)
            Text(label).font(.system(size: 10)).foregroundStyle(CC.textDim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - Pieces

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).tracking(0.4)
            .foregroundStyle(CC.textDim).padding(.top, 2)
    }

    private func toggleRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CC.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(CC.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.small)
                .tint(settings.accentColor).labelsHidden()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }
}
