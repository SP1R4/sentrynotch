import SwiftUI
import SentryNotchCore
import Foundation

/// One selectable accent, recoloring the notch's signature elements (mascot,
/// dot, spinner, logo). `alarmed` red is never themed — danger stays red.
enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case coral, blue, green, purple, amber
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .coral:  return CC.coral
        case .blue:   return Color(red: 0.30, green: 0.62, blue: 0.92)
        case .green:  return Color(red: 0.35, green: 0.78, blue: 0.55)
        case .purple: return Color(red: 0.66, green: 0.52, blue: 0.92)
        case .amber:  return Color(red: 0.95, green: 0.70, blue: 0.30)
        }
    }
}

/// The panel's base colour. The very top of the fill always stays near-black
/// (`CC.inkTop`) so the collapsed bar keeps fusing with the physical notch —
/// only the colour the panel settles into lower down is themed. `.custom` reads
/// `AppSettings.notchBackgroundHex`.
enum NotchBackground: String, CaseIterable, Codable, Identifiable {
    case warmBlack, pureBlack, charcoal, midnight, forest, plum, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .warmBlack: return "Warm Black"
        case .pureBlack: return "Pure Black"
        case .charcoal:  return "Charcoal"
        case .midnight:  return "Midnight"
        case .forest:    return "Forest"
        case .plum:      return "Plum"
        case .custom:    return "Custom"
        }
    }
    /// The preset's base colour, or nil for `.custom` (which needs the stored hex).
    var presetColor: Color? {
        switch self {
        case .warmBlack: return CC.ink
        case .pureBlack: return Color(red: 0.02, green: 0.02, blue: 0.02)
        case .charcoal:  return Color(red: 0.16, green: 0.16, blue: 0.17)
        case .midnight:  return Color(red: 0.06, green: 0.09, blue: 0.17)
        case .forest:    return Color(red: 0.06, green: 0.13, blue: 0.10)
        case .plum:      return Color(red: 0.14, green: 0.07, blue: 0.15)
        case .custom:    return nil
        }
    }
}

/// Whether the continuously-animating views (mascot, spinners, marquee) run.
/// `system` follows macOS's Reduce Motion setting; the other two force it.
enum AnimationMode: String, CaseIterable, Codable, Identifiable {
    case system, always, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .always: return "Always"
        case .never:  return "Never"
        }
    }
}

/// A togglable notch widget (an expanded-view section). Registry-driven so the
/// dashboard lists them without per-item UI code.
struct WidgetSpec: Identifiable {
    let id: String, name: String, detail: String, defaultOn: Bool
    static let all: [WidgetSpec] = [
        .init(id: "usage",      name: "Usage strip",       detail: "Context tokens, active/pending, rate-limit resets", defaultOn: true),
        .init(id: "sessions",   name: "Session list",      detail: "Live cards for your running Claude Code sessions",  defaultOn: true),
        .init(id: "approveSafe", name: "Approve-all-safe", detail: "Bulk-approve no-risk prompts in one click",         defaultOn: true),
        .init(id: "activity",   name: "Session activity feed", detail: "Expand a card to see its live message/tool feed", defaultOn: true),
        .init(id: "timer",      name: "Timer",             detail: "Countdown with editable presets and a finish chime", defaultOn: true),
        .init(id: "spotify",    name: "Now playing",       detail: "Now-playing and transport for Spotify or Apple Music",  defaultOn: true),
        .init(id: "headroom",   name: "Rate-limit headroom", detail: "Live context tokens and time until the 5h/7d windows reset", defaultOn: true),
        .init(id: "repo",       name: "Repo state",        detail: "Branch and uncommitted-file count for each working session", defaultOn: true),
        .init(id: "vitals",     name: "Agent vitals",      detail: "Context-fill gauge, burn rate, ETA to the ceiling, and a tempo heartbeat", defaultOn: true),
        .init(id: "fleet",      name: "Fleet board",       detail: "Every session as a status dot — working, waiting on you, or high-risk", defaultOn: true),
    ]
}

/// A capability module ("plugin"). Toggling gates real behavior in AppModel.
struct PluginSpec: Identifiable {
    let id: String, name: String, detail: String, defaultOn: Bool
    static let all: [PluginSpec] = [
        .init(id: "pings",         name: "Completion & attention pings", detail: "Sound + toast when a session finishes or needs input", defaultOn: true),
        .init(id: "notifications", name: "Answer-from-notification",     detail: "Post Deny / Allow / Always as a system notification",  defaultOn: true),
        .init(id: "scope",         name: "Engagement scope guard",       detail: "Flag Bash commands reaching out-of-scope hosts",       defaultOn: true),
        .init(id: "usageProbe",    name: "Rate-limit probe",             detail: "One cheap call to read the real 5h/7d reset windows",  defaultOn: true),
    ]
}

/// User-tunable settings surfaced by the dashboard — appearance, which notch
/// widgets show, and which capability modules are armed. Persisted to
/// settings.json alongside the rules.
@MainActor
final class AppSettings: ObservableObject {
    @Published var mascotEnabled: Bool { didSet { saveIfLoaded() } }
    @Published var mascotUsesProjectColor: Bool { didSet { saveIfLoaded() } }
    @Published var promptSounds: Bool { didSet { saveIfLoaded() } }
    /// Default is off: the island only ever appears on the display with a
    /// physical notch, when one is connected. A "notch" overlay floating on a
    /// plain external monitor — no camera housing for it to visually hug —
    /// reads as a rendering bug, not a feature. Switching this on restores the
    /// old behaviour of following the pointer to whichever screen is active,
    /// for anyone who preferred that.
    @Published var followPointerAcrossScreens: Bool { didSet { saveIfLoaded() } }
    @Published var accent: AccentChoice { didSet { saveIfLoaded() } }
    /// Which player the now-playing widget follows. nil = whichever is playing.
    @Published var musicSource: MusicSource? { didSet { saveIfLoaded() } }
    @Published var widgets: [String: Bool] { didSet { saveIfLoaded() } }
    @Published var plugins: [String: Bool] { didSet { saveIfLoaded() } }

    /// How the continuously-animating views behave. See AnimationMode.
    @Published var animationMode: AnimationMode { didSet { saveIfLoaded() } }
    /// Global summon shortcut. Carbon virtual key code + Carbon modifier mask;
    /// stored raw so the recorder and the registrar speak the same language.
    @Published var hotkeyKeyCode: UInt32 { didSet { saveIfLoaded() } }
    @Published var hotkeyModifiers: UInt32 { didSet { saveIfLoaded() } }
    /// Named system sounds (files in /System/Library/Sounds). High-risk and
    /// out-of-scope prompts are deliberately *not* user-overridable — they
    /// always fire the alarming default — so a muted preference can't quiet the
    /// one ping that matters most.
    @Published var soundPrompt: String { didSet { saveIfLoaded() } }
    @Published var soundFinished: String { didSet { saveIfLoaded() } }
    @Published var soundNeedsInput: String { didSet { saveIfLoaded() } }
    @Published var soundTimer: String { didSet { saveIfLoaded() } }
    /// Timer quick-pick durations, in minutes.
    @Published var timerPresets: [Int] { didSet { saveIfLoaded() } }
    /// Now-playing card options. Art colour on/off falls back to the app accent;
    /// marquee scrolls a long title instead of truncating; volume hides the
    /// inline slider for anyone who sets volume elsewhere.
    @Published var nowPlayingUseArtColor: Bool { didSet { saveIfLoaded() } }
    @Published var nowPlayingShowVolume: Bool { didSet { saveIfLoaded() } }
    @Published var nowPlayingMarquee: Bool { didSet { saveIfLoaded() } }
    /// Wash the whole expanded panel with a colour sampled from the current
    /// cover, the way Apple's full-screen player tints its background.
    @Published var panelTintFromArt: Bool { didSet { saveIfLoaded() } }
    /// The notch panel's base colour, and the hex used when it is `.custom`.
    @Published var notchBackground: NotchBackground { didSet { saveIfLoaded() } }
    @Published var notchBackgroundHex: String { didSet { saveIfLoaded() } }
    /// Declarative allow/deny/prompt policy, evaluated before the auto-allow
    /// tiers. Empty by default, so existing users are unaffected until they add
    /// a rule; `policyEnabled` is a master switch to mute the whole set at once.
    @Published var policyEnabled: Bool { didSet { saveIfLoaded() } }
    @Published var policyRules: [PolicyRule] { didSet { saveIfLoaded() } }
    /// Optional off-box alerting: POST high-signal events to a webhook (e.g. a
    /// Telegram admin bot). Off by default; when on, only high-risk /
    /// out-of-scope events fire unless `alertsAllPrompts` is set.
    @Published var alertsEnabled: Bool { didSet { saveIfLoaded() } }
    @Published var alertWebhookURL: String { didSet { saveIfLoaded() } }
    @Published var alertsAllPrompts: Bool { didSet { saveIfLoaded() } }

    private let path: String
    private var loaded = false

    init(dir: String) {
        path = "\(dir)/settings.json"
        mascotEnabled = true
        mascotUsesProjectColor = false
        promptSounds = true
        followPointerAcrossScreens = false
        accent = .coral
        musicSource = nil
        widgets = Dictionary(uniqueKeysWithValues: WidgetSpec.all.map { ($0.id, $0.defaultOn) })
        plugins = Dictionary(uniqueKeysWithValues: PluginSpec.all.map { ($0.id, $0.defaultOn) })
        animationMode = .system
        hotkeyKeyCode = Self.defaultHotkeyKeyCode
        hotkeyModifiers = Self.defaultHotkeyModifiers
        soundPrompt = "Pop"
        soundFinished = "Glass"
        soundNeedsInput = "Funk"
        soundTimer = "Submarine"
        timerPresets = Self.defaultTimerPresets
        nowPlayingUseArtColor = true
        nowPlayingShowVolume = true
        nowPlayingMarquee = true
        panelTintFromArt = true
        notchBackground = .warmBlack
        notchBackgroundHex = "1C1B1A"
        policyEnabled = true
        policyRules = []
        alertsEnabled = false
        alertWebhookURL = ""
        alertsAllPrompts = false
        load()
        loaded = true
    }

    /// Space, with Command+Shift. 49 / 768 are the Carbon key code and modifier
    /// mask (cmdKey | shiftKey); kept as literals so this file needn't import
    /// Carbon just to name a default.
    nonisolated static let defaultHotkeyKeyCode: UInt32 = 49
    nonisolated static let defaultHotkeyModifiers: UInt32 = 768
    nonisolated static let defaultTimerPresets = [5, 15, 25, 45]

    var accentColor: Color { accent.color }

    /// The colour the panel settles to at its base (preset, or the custom hex).
    var notchBaseColor: Color {
        notchBackground.presetColor ?? (Color(hex: notchBackgroundHex) ?? CC.ink)
    }
    /// The themed panel fill: near-black at the seam so the collapsed bar fuses
    /// with the hardware, easing into the chosen base lower down.
    var notchPanel: LinearGradient {
        LinearGradient(colors: [CC.inkTop, notchBaseColor], startPoint: .top, endPoint: .bottom)
    }

    func widgetOn(_ id: String) -> Bool { widgets[id] ?? true }
    func pluginOn(_ id: String) -> Bool { plugins[id] ?? true }

    /// Presets clamped to sane values, de-duplicated, sorted, capped at six, so
    /// a hand-edited file can't produce a zero-minute or runaway preset.
    var validTimerPresets: [Int] {
        let cleaned = Set(timerPresets.filter { $0 >= 1 && $0 <= 600 }).sorted()
        return cleaned.isEmpty ? Self.defaultTimerPresets : Array(cleaned.prefix(6))
    }

    func widgetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.widgetOn(id) }, set: { self.widgets[id] = $0 })
    }
    func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.pluginOn(id) }, set: { self.plugins[id] = $0 })
    }

    // MARK: - Persistence

    /// Decoded field by field so one bad value can't discard the rest.
    ///
    /// With a synthesised `Codable`, a single unrecognised entry — an accent
    /// name from a newer build, a hand-edited typo — makes the whole decode
    /// throw. Every preference then silently reverts to its default, and the
    /// next save writes those defaults over the user's file. Losing someone's
    /// entire configuration because of one unknown string is not a reasonable
    /// failure mode; each field now falls back on its own.
    private struct Saved: Codable {
        var mascotEnabled = true
        var mascotUsesProjectColor = false
        var promptSounds = true
        var followPointerAcrossScreens: Bool?
        var accent = AccentChoice.coral
        var musicSource: MusicSource?
        var widgets: [String: Bool] = [:]
        var plugins: [String: Bool] = [:]
        var animationMode = AnimationMode.system
        var hotkeyKeyCode: UInt32 = AppSettings.defaultHotkeyKeyCode
        var hotkeyModifiers: UInt32 = AppSettings.defaultHotkeyModifiers
        var soundPrompt = "Pop"
        var soundFinished = "Glass"
        var soundNeedsInput = "Funk"
        var soundTimer = "Submarine"
        var timerPresets = AppSettings.defaultTimerPresets
        var nowPlayingUseArtColor = true
        var nowPlayingShowVolume = true
        var nowPlayingMarquee = true
        var panelTintFromArt = true
        var notchBackground = NotchBackground.warmBlack
        var notchBackgroundHex = "1C1B1A"
        var policyEnabled = true
        var policyRules: [PolicyRule] = []
        var alertsEnabled = false
        var alertWebhookURL = ""
        var alertsAllPrompts = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mascotEnabled = (try? c.decode(Bool.self, forKey: .mascotEnabled)) ?? true
            mascotUsesProjectColor = (try? c.decode(Bool.self, forKey: .mascotUsesProjectColor)) ?? false
            promptSounds = (try? c.decode(Bool.self, forKey: .promptSounds)) ?? true
            followPointerAcrossScreens =
                try? c.decode(Bool.self, forKey: .followPointerAcrossScreens)
            accent = (try? c.decode(AccentChoice.self, forKey: .accent)) ?? .coral
            // nil is a real value here (auto-detect), so an unreadable field
            // and an absent one both correctly mean "choose for me".
            musicSource = try? c.decode(MusicSource.self, forKey: .musicSource)
            widgets = (try? c.decode([String: Bool].self, forKey: .widgets)) ?? [:]
            plugins = (try? c.decode([String: Bool].self, forKey: .plugins)) ?? [:]
            animationMode = (try? c.decode(AnimationMode.self, forKey: .animationMode)) ?? .system
            hotkeyKeyCode = (try? c.decode(UInt32.self, forKey: .hotkeyKeyCode)) ?? AppSettings.defaultHotkeyKeyCode
            hotkeyModifiers = (try? c.decode(UInt32.self, forKey: .hotkeyModifiers)) ?? AppSettings.defaultHotkeyModifiers
            soundPrompt = (try? c.decode(String.self, forKey: .soundPrompt)) ?? "Pop"
            soundFinished = (try? c.decode(String.self, forKey: .soundFinished)) ?? "Glass"
            soundNeedsInput = (try? c.decode(String.self, forKey: .soundNeedsInput)) ?? "Funk"
            soundTimer = (try? c.decode(String.self, forKey: .soundTimer)) ?? "Submarine"
            timerPresets = (try? c.decode([Int].self, forKey: .timerPresets)) ?? AppSettings.defaultTimerPresets
            nowPlayingUseArtColor = (try? c.decode(Bool.self, forKey: .nowPlayingUseArtColor)) ?? true
            nowPlayingShowVolume = (try? c.decode(Bool.self, forKey: .nowPlayingShowVolume)) ?? true
            nowPlayingMarquee = (try? c.decode(Bool.self, forKey: .nowPlayingMarquee)) ?? true
            panelTintFromArt = (try? c.decode(Bool.self, forKey: .panelTintFromArt)) ?? true
            notchBackground = (try? c.decode(NotchBackground.self, forKey: .notchBackground)) ?? .warmBlack
            notchBackgroundHex = (try? c.decode(String.self, forKey: .notchBackgroundHex)) ?? "1C1B1A"
            policyEnabled = (try? c.decode(Bool.self, forKey: .policyEnabled)) ?? true
            policyRules = (try? c.decode([PolicyRule].self, forKey: .policyRules)) ?? []
            alertsEnabled = (try? c.decode(Bool.self, forKey: .alertsEnabled)) ?? false
            alertWebhookURL = (try? c.decode(String.self, forKey: .alertWebhookURL)) ?? ""
            alertsAllPrompts = (try? c.decode(Bool.self, forKey: .alertsAllPrompts)) ?? false
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        mascotEnabled = s.mascotEnabled
        mascotUsesProjectColor = s.mascotUsesProjectColor
        promptSounds = s.promptSounds
        followPointerAcrossScreens = s.followPointerAcrossScreens ?? false
        accent = s.accent
        musicSource = s.musicSource
        // Merge saved over defaults so new registry entries keep their default.
        widgets.merge(s.widgets) { _, saved in saved }
        plugins.merge(s.plugins) { _, saved in saved }
        animationMode = s.animationMode
        hotkeyKeyCode = s.hotkeyKeyCode
        hotkeyModifiers = s.hotkeyModifiers
        soundPrompt = s.soundPrompt
        soundFinished = s.soundFinished
        soundNeedsInput = s.soundNeedsInput
        soundTimer = s.soundTimer
        timerPresets = s.timerPresets
        nowPlayingUseArtColor = s.nowPlayingUseArtColor
        nowPlayingShowVolume = s.nowPlayingShowVolume
        nowPlayingMarquee = s.nowPlayingMarquee
        panelTintFromArt = s.panelTintFromArt
        notchBackground = s.notchBackground
        notchBackgroundHex = s.notchBackgroundHex
        policyEnabled = s.policyEnabled
        policyRules = s.policyRules
        alertsEnabled = s.alertsEnabled
        alertWebhookURL = s.alertWebhookURL
        alertsAllPrompts = s.alertsAllPrompts
    }

    private func saveIfLoaded() { if loaded { save() } }

    private func save() {
        var s = Saved()
        s.mascotEnabled = mascotEnabled
        s.mascotUsesProjectColor = mascotUsesProjectColor
        s.promptSounds = promptSounds
        s.followPointerAcrossScreens = followPointerAcrossScreens
        s.accent = accent
        s.musicSource = musicSource
        s.widgets = widgets
        s.plugins = plugins
        s.animationMode = animationMode
        s.hotkeyKeyCode = hotkeyKeyCode
        s.hotkeyModifiers = hotkeyModifiers
        s.soundPrompt = soundPrompt
        s.soundFinished = soundFinished
        s.soundNeedsInput = soundNeedsInput
        s.soundTimer = soundTimer
        s.timerPresets = timerPresets
        s.nowPlayingUseArtColor = nowPlayingUseArtColor
        s.nowPlayingShowVolume = nowPlayingShowVolume
        s.nowPlayingMarquee = nowPlayingMarquee
        s.panelTintFromArt = panelTintFromArt
        s.notchBackground = notchBackground
        s.notchBackgroundHex = notchBackgroundHex
        s.policyEnabled = policyEnabled
        s.policyRules = policyRules
        s.alertsEnabled = alertsEnabled
        s.alertWebhookURL = alertWebhookURL
        s.alertsAllPrompts = alertsAllPrompts
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
