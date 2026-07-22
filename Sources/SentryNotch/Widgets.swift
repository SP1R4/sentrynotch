import SwiftUI
import AppKit
import Foundation
import SentryNotchCore

// MARK: - Timer

/// A plain countdown for the notch. State is an absolute deadline rather than a
/// decrementing counter, so the display stays correct across sleep and the view
/// can render it from a TimelineView without a tick of its own.
@MainActor
final class TimerModel: ObservableObject {
    @Published private(set) var endsAt: Date?
    @Published private(set) var paused: TimeInterval?
    @Published private(set) var minutes: Int = 25

    var onFinish: ((Int) -> Void)?
    private var alarm: Timer?
    private var path: String?

    static let presets = [5, 15, 25, 45]

    /// Point the timer at its state file and restore whatever was running. A
    /// deadline is absolute, so a countdown survives a restart (and expires
    /// quietly if the app was down past its end).
    func restore(dir: String) {
        let p = "\(dir)/timer.json"
        path = p
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // Clamp on the way in as well as on the way out: `set(minutes:)`
        // validates user input, but a hand-edited or truncated file could
        // otherwise load a zero or negative duration that can never start.
        minutes = max(Self.minMinutes, min(Self.maxMinutes, s.minutes))
        paused = s.paused.map { max(0, $0) }
        // Rewrite immediately if the file held something unusable, so the bad
        // value doesn't sit there being re-read (and re-clamped) forever.
        if minutes != s.minutes || paused != s.paused { persist() }
        if let end = s.endsAt {
            let left = end.timeIntervalSinceNow
            if left > 0 { endsAt = end; scheduleAlarm(after: left) }
        }
    }

    private struct Saved: Codable {
        var minutes = 25
        var endsAt: Date?
        var paused: TimeInterval?

        init(minutes: Int, endsAt: Date?, paused: TimeInterval?) {
            self.minutes = minutes; self.endsAt = endsAt; self.paused = paused
        }
        /// Lenient for the same reason as the other stores: a bad field should
        /// cost you the timer's duration, not silently reset everything.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 25
            endsAt = try? c.decode(Date.self, forKey: .endsAt)
            paused = try? c.decode(TimeInterval.self, forKey: .paused)
        }
    }

    private func persist() {
        guard let path else { return }
        let s = Saved(minutes: minutes, endsAt: endsAt, paused: paused)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    var running: Bool { endsAt != nil }

    var remaining: TimeInterval {
        if let paused { return paused }
        guard let endsAt else { return TimeInterval(minutes * 60) }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    /// 0…1 elapsed, for the ring.
    var progress: Double {
        let total = TimeInterval(minutes * 60)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    func toggle() { running ? pause() : start() }

    func start() {
        let left = paused ?? TimeInterval(minutes * 60)
        guard left > 0 else { return }
        paused = nil
        endsAt = Date().addingTimeInterval(left)
        scheduleAlarm(after: left)
        persist()
    }

    func pause() {
        guard let endsAt else { return }
        paused = max(0, endsAt.timeIntervalSinceNow)
        self.endsAt = nil
        alarm?.invalidate(); alarm = nil
        persist()
    }

    func reset() {
        endsAt = nil; paused = nil
        alarm?.invalidate(); alarm = nil
        persist()
    }

    static let minMinutes = 1
    static let maxMinutes = 600      // 10 hours; beyond that use a calendar

    /// Set the duration. Clamped rather than rejected, so a pasted or
    /// fat-fingered value still produces a usable timer instead of an error.
    func set(minutes m: Int) {
        minutes = max(Self.minMinutes, min(Self.maxMinutes, m))
        reset()
    }

    /// Adjust relative to the current duration, for the stepper buttons.
    func nudge(by delta: Int) { set(minutes: minutes + delta) }

    /// Set a duration and start it in one go — used by "Set & start" only.
    /// Choosing a duration on its own never starts the clock.
    ///
    /// Applied as one transition rather than `set()` then `start()`. The latter
    /// went running → stopped → running, and each intermediate state published,
    /// so the widget visibly flickered: the countdown reset to the full
    /// duration, the play/pause glyph flipped twice, and the reset button
    /// appeared mid-way.
    func startFresh(minutes m: Int) {
        let clamped = max(Self.minMinutes, min(Self.maxMinutes, m))
        let duration = TimeInterval(clamped * 60)
        alarm?.invalidate()
        minutes = clamped
        paused = nil
        endsAt = Date().addingTimeInterval(duration)
        scheduleAlarm(after: duration)
        persist()
    }

    private func scheduleAlarm(after seconds: TimeInterval) {
        alarm?.invalidate()
        alarm = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let m = self.minutes
                self.reset()
                // The chime is played by AppModel's onFinish handler, which can
                // read the user's chosen sound; TimerModel has no settings.
                self.onFinish?(m)
            }
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Compact timer: progress ring, countdown, transport. One line.
///
/// The duration presets moved to a context menu. They were four pills eating a
/// third of the widget's height to expose a setting most people touch once,
/// while the session list — the actual product — was squeezed below.
struct TimerWidget: View {
    @ObservedObject var timer: TimerModel
    var accent: Color
    /// Quick-pick durations shown in the menu and setup popover, in minutes.
    var presets: [Int]
    /// Bound to the island's shared popover flag so the panel knows not to
    /// collapse out from under an open popover.
    @Binding var popoverOpen: Bool

    private var showSetup: Binding<Bool> {
        Binding(get: { popoverOpen }, set: { popoverOpen = $0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            ring
            // The countdown is the control: clicking it opens the setup
            // popover. A right-click-only affordance was undiscoverable, and
            // four fixed presets couldn't express "37 minutes".
            Button { popoverOpen = true } label: {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(TimerModel.clock(timer.remaining))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timer.running ? CC.text : CC.textDim)
                        // Reserve the widest form ("100:00"). Without this the
                        // card shrank as the countdown crossed 10:00 and 1:00,
                        // which re-laid out the widget row and re-fitted the
                        // whole panel — and moved the popover's anchor out from
                        // under it while it was open. Width tracks the font.
                        .frame(width: 84, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help("Click to set the duration")
            .popover(isPresented: showSetup, arrowEdge: .bottom) {
                TimerSetup(timer: timer, accent: accent, presets: presets,
                           done: { popoverOpen = false })
            }

            iconButton(timer.running ? "pause.fill" : "play.fill") { timer.toggle() }
            // Always present, disabled when there is nothing to reset. It used
            // to appear and disappear, changing the card's width the instant a
            // preset was pressed.
            iconButton("arrow.counterclockwise", enabled: canReset) { timer.reset() }
        }
        .contextMenu {
            Text("Duration")
            ForEach(presets, id: \.self) { m in
                Button {
                    timer.set(minutes: m)
                } label: {
                    Label("\(m) minutes", systemImage: timer.minutes == m ? "checkmark" : "")
                }
            }
            Divider()
            Button("Custom…") { popoverOpen = true }
        }
    }

    private var ring: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            ZStack {
                Circle().stroke(CC.hairline, lineWidth: 3)
                Circle().trim(from: 0, to: timer.progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "timer").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent.opacity(timer.running ? 0 : 0.8))
            }
            .frame(width: 24, height: 24)
        }
    }

    /// True when the timer has been started or partly consumed. Derived from
    /// published state only — `remaining` changes continuously without
    /// publishing, so testing it here produced a stale answer.
    private var canReset: Bool { timer.running || timer.paused != nil }

    private func iconButton(_ symbol: String, enabled: Bool = true,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: enabled ? action : {}) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? CC.text : CC.textFaint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(enabled ? CC.surfaceHi : CC.surface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Duration picker: presets for the common cases, a stepper and a field for
/// everything else. Choosing a preset starts the timer immediately — picking
/// "25m" and then having to press play is a pointless second step.
private struct TimerSetup: View {
    @ObservedObject var timer: TimerModel
    var accent: Color
    var presets: [Int]
    var done: () -> Void

    @State private var field: String
    @FocusState private var fieldFocused: Bool

    /// Seeded in init rather than `onAppear`. SwiftUI can rebuild popover
    /// content without re-running onAppear, which left the field showing a
    /// stale or truncated value instead of the current duration.
    init(timer: TimerModel, accent: Color, presets: [Int], done: @escaping () -> Void) {
        self.timer = timer
        self.accent = accent
        self.presets = presets
        self.done = done
        _field = State(initialValue: "\(timer.minutes)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TIMER DURATION")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(CC.textFaint)

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    Button {
                        // A preset only chooses the duration; starting is a
                        // separate, deliberate act via play or "Set & start".
                        //
                        // Dismiss first, then mutate: changing the timer while
                        // the popover is still open re-lays out its anchor
                        // underneath it, which made the dismissal stutter.
                        done()
                        DispatchQueue.main.async { timer.set(minutes: m) }
                    } label: {
                        Text("\(m)m")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(timer.minutes == m ? .white : CC.text)
                            .frame(width: 42, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(timer.minutes == m ? accent : CC.surfaceHi))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().overlay(CC.hairline)

            HStack(spacing: 8) {
                Text("Custom").font(.system(size: 11)).foregroundStyle(CC.textDim)
                stepButton("minus") { timer.nudge(by: -5); field = "\(timer.minutes)" }
                TextField("", text: $field)
                    .textFieldStyle(.plain).multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(CC.text)
                    .frame(width: 52, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(CC.surfaceHi))
                    .focused($fieldFocused)
                    .onSubmit(apply)
                stepButton("plus") { timer.nudge(by: 5); field = "\(timer.minutes)" }
                Text("min").font(.system(size: 11)).foregroundStyle(CC.textFaint)
            }

            Text("\(TimerModel.minMinutes)–\(TimerModel.maxMinutes) minutes")
                .font(.system(size: 9)).foregroundStyle(CC.textFaint)

            HStack(spacing: 8) {
                Button("Set") { apply(); done() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent))
                Button("Set & start") {
                    apply()
                    let m = timer.minutes
                    done()
                    DispatchQueue.main.async { timer.startFresh(minutes: m) }
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(accent)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(CC.ink)
        .onAppear { fieldFocused = true }
        // Keep the field in step when the presets or stepper change the model.
        .onChange(of: timer.minutes) { _, new in field = "\(new)" }
    }

    /// Ignores junk rather than clearing the field, so a mistyped character
    /// doesn't silently wipe the duration the user already had.
    private func apply() {
        guard let v = Int(field.trimmingCharacters(in: .whitespaces)) else {
            field = "\(timer.minutes)"
            return
        }
        timer.set(minutes: v)
        field = "\(timer.minutes)"      // reflect clamping back to the user
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(CC.text)
                .frame(width: 22, height: 22)
                .background(Circle().fill(CC.surfaceHi))
        }
        .buttonStyle(.plain)
    }
}
// MARK: - Now playing

/// Reads and drives the local music player over AppleScript — Spotify or Apple
/// Music, whichever is actually in use.
///
/// No OAuth and no Web API. The only network call is fetching album artwork
/// from Spotify's own CDN (see PRIVACY.md); Apple Music's artwork comes out of
/// the local library and never leaves the machine. Neither app is ever launched
/// by us — if it isn't already running, polling is skipped entirely.
@MainActor
final class NowPlayingController: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var playing = false
    @Published private(set) var track = ""
    @Published private(set) var album = ""
    @Published private(set) var artist = ""
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 70
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var artwork: NSImage?
    /// Dominant colour of the current cover, nil for greyscale art or before the
    /// image lands. The UI tints itself with this and falls back to the user's
    /// own accent, so nil is a normal state rather than a failure.
    @Published private(set) var artAccent: RGB?
    /// Which player the widget is currently following.
    @Published private(set) var source: MusicSource = .spotify
    /// Why the widget has nothing to show. Distinguishing these matters: a
    /// script that failed because no track is loaded is not a permissions
    /// problem, and telling the user to open System Settings for it sends them
    /// somewhere useless.
    @Published private(set) var problem: Problem?
    /// False when the source can be read but not driven — a YouTube tab whose
    /// browser has the JavaScript bridge switched off. The UI hides transport
    /// rather than showing buttons that silently do nothing.
    @Published private(set) var controllable = true
    /// Which browser currently holds the YouTube tab, once resolved.
    @Published private(set) var youtubeBrowser: Browser?
    /// True when YouTube was found but only the tab title is readable.
    @Published private(set) var youtubeNeedsBridge = false

    enum Problem: Equatable {
        case notRunning        // no supported player is open
        case denied            // user declined Automation, or TCC has no grant
        case scriptFailed      // running but the query didn't return usable data
    }

    /// Pin the widget to one player. nil follows whichever is playing.
    var preference: MusicSource? {
        didSet {
            if preference != oldValue {
                permissionChecked = []; permissionDenied = []; refresh()
            }
        }
    }

    private var poll: Timer?
    private var busy = false
    /// TCC is granted per target app, so the check is tracked per source — a
    /// Spotify grant says nothing about whether we may drive Music.
    private var permissionChecked: Set<MusicSource> = []
    /// TCC is granted per target application, and YouTube's target is whichever
    /// browser holds the tab — not the source — so browser grants are tracked
    /// by bundle id separately.
    private var checkedBundles: Set<String> = []
    private var deniedBundles: Set<String> = []
    /// Per-browser "found title-only until" timestamps. A downgrade expires so
    /// enabling the JavaScript bridge is picked up without restarting anything.
    private var titleOnlyUntil: [Browser: Date] = [:]
    private var noTabBrowsers: Set<Browser> = []
    private var browserObserverInstalled = false
    /// Sources whose Automation grant was refused. Kept so a denied player is
    /// not re-probed on every poll — the request itself is only made once (TCC
    /// remembers), but the script would otherwise keep failing forever.
    private var permissionDenied: Set<MusicSource> = []
    /// Permission requests in flight, so a 3s poll can't stack several.
    private var permissionInFlight: Set<MusicSource> = []
    private var artKey = ""
    /// Which sources were playing at the last poll, feeding source selection.
    private var playingSources: Set<MusicSource> = []
    private var lastSource: MusicSource?
    /// Local scrub/volume gestures win over polled values until the user lets
    /// go, otherwise the knob fights the 3s refresh and jumps backwards.
    private var suppressPollUntil = Date.distantPast

    /// Browsers currently open, in a stable order so the choice doesn't flap
    /// between polls when several are running.
    private var runningBrowsers: [Browser] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var list = Browser.allCases.filter { ids.contains($0.bundleID) }
        // Ask about the browser the user actually uses. Declaration order put
        // Safari first, so a windowless Safari — which macOS keeps running long
        // after its last window closed — collected the permission prompt while
        // the YouTube tab sat in another browser entirely.
        if let recent = lastActiveBrowser, let i = list.firstIndex(of: recent) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }

    /// The most recently foregrounded browser, used to decide which one is
    /// worth asking about first.
    private var lastActiveBrowser: Browser?

    private func observeBrowserActivation() {
        // Seed from whatever is frontmost now: a browser already in the
        // foreground at launch never fires an activation notification.
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let b = Browser.allCases.first(where: { $0.bundleID == id }) {
            lastActiveBrowser = b
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier,
                  let b = Browser.allCases.first(where: { $0.bundleID == id }) else { return }
            Task { @MainActor in self?.lastActiveBrowser = b }
        }
    }

    private var runningSources: Set<MusicSource> {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var found = Set(MusicSource.allCases.filter {
            !$0.bundleID.isEmpty && ids.contains($0.bundleID)
        })
        // YouTube has no app of its own; it counts as available whenever a
        // browser that could be holding the tab is open.
        if !runningBrowsers.isEmpty && (preference == .youtube || youtubeBrowser != nil) {
            found.insert(.youtube)
        }
        return found
    }

    /// Ask TCC directly whether we may drive `source`, prompting if it hasn't
    /// been decided yet.
    ///
    /// This has to be asked by *this* process. Shelling out to `osascript`
    /// makes the Apple Event originate from osascript, and macOS then resolves
    /// the responsible process through the parent chain — which is unreliable
    /// for a bundle without a stable signing identity, so the request is
    /// silently denied and the user never sees a prompt. Asking here attributes
    /// it to us and shows our NSAppleEventsUsageDescription.
    ///
    /// Must not run on the main thread: with `askUserIfNeeded` it blocks while
    /// the system dialog is up. `nonisolated` because it is *required* to run
    /// off the main actor — it touches no instance state, only locals.
    nonisolated private static func requestAutomationPermission(
        for source: MusicSource) -> Problem? {
        requestAutomationPermission(bundleID: source.bundleID)
    }

    nonisolated private static func requestAutomationPermission(bundleID: String) -> Problem? {
        guard !bundleID.isEmpty else { return .scriptFailed }
        var target = AEAddressDesc()
        var idBytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, &idBytes, idBytes.count, &target) == noErr else {
            return .scriptFailed
        }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, true)
        switch status {
        case noErr: return nil
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .scriptFailed
        }
    }

    private var pollInterval: TimeInterval = 0

    /// Idempotent, and re-arms if the cadence changed.
    ///
    /// The collapsed notch shows a music visualiser, so polling can't simply
    /// stop when the island closes — but it doesn't need 3s resolution either.
    /// Collapsed only needs the playing/paused flag, so it drops to 15s: four
    /// osascript spawns a minute instead of twenty.
    func startPolling(every seconds: TimeInterval = 3) {
        if browserObserverInstalled == false { browserObserverInstalled = true; observeBrowserActivation() }
        if poll != nil && pollInterval == seconds { return }
        poll?.invalidate()
        pollInterval = seconds
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() { poll?.invalidate(); poll = nil; pollInterval = 0 }

    private func clear(_ p: Problem) {
        available = false; playing = false
        track = ""; artist = ""; album = ""
        artwork = nil; artKey = ""; artAccent = nil
        problem = p
    }

    func refresh() {
        let running = runningSources
        // Choose before checking permission: asking to drive an app that isn't
        // open would prompt the user about software they aren't using.
        guard let chosen = pickSource(preference: preference, running: running,
                                      playing: playingSources,
                                      last: lastSource) else {
            clear(.notRunning)
            lastSource = nil
            return
        }
        if chosen != source {
            source = chosen
            // Identity changed — drop the old track's art so the previous
            // player's cover never appears above the new player's title.
            artwork = nil; artKey = ""; artAccent = nil
        }
        lastSource = chosen

        guard !busy else { return }
        busy = true

        if chosen == .youtube { refreshYouTube(); return }

        // Resolve the TCC grant once per source, off the main thread so the
        // consent dialog can't deadlock the UI.
        guard permissionChecked.contains(chosen) else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.requestAutomationPermission(for: chosen)
                Task { @MainActor in
                    self.permissionChecked.insert(chosen)
                    self.busy = false
                    self.problem = result
                    if result == nil { self.refresh() }
                    else { self.available = false }
                }
            }
            return
        }

        Self.run(nowPlayingScript(chosen)) { [weak self] out in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                // Permission was already confirmed above, so a failure here is
                // the script itself (e.g. no track loaded), not TCC.
                guard let out, let n = parseNowPlaying(out) else {
                    self.clear(.scriptFailed)
                    return
                }
                self.problem = nil
                self.available = true
                self.controllable = true
                self.youtubeNeedsBridge = false
                self.playing = n.playing
                self.track = n.track
                self.album = n.album
                self.artist = n.artist
                if Date() > self.suppressPollUntil {
                    self.position = n.positionMs / 1000
                    self.volume = n.volume
                }
                self.duration = n.durationMs / 1000
                self.shuffling = n.shuffling
                self.repeating = n.repeating
                self.loadArtwork(n.artKey, from: chosen)
                self.playingSources = n.playing ? [chosen] : []
                // Only look at the other app when this one has fallen silent —
                // otherwise every poll would spawn an extra osascript for a
                // player the user isn't listening to.
                if !n.playing { self.probeOthers(besides: chosen, running: running) }
            }
        }
    }

    /// Ask the other running players whether they're playing, so auto-detect
    /// can hand the widget over when the user switches apps.
    private func probeOthers(besides current: MusicSource, running: Set<MusicSource>) {
        guard preference == nil else { return }   // pinned: nothing to decide
        for other in running where other != current
            && !permissionDenied.contains(other) && !permissionInFlight.contains(other) {
            // Automation is granted per target app, so the other player needs
            // its own grant before it can be asked anything.
            //
            // This used to require the grant to already exist, which made the
            // whole feature unreachable: a source is only permission-checked
            // once it has been chosen, and it can only be chosen once we know
            // it is playing, which is what this probe exists to find out. The
            // widget therefore stayed on the first player forever. Requesting
            // here breaks the cycle, and it is a fair moment to ask — the user
            // has both apps open and the one being followed has gone quiet.
            guard permissionChecked.contains(other) else {
                permissionInFlight.insert(other)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let result = Self.requestAutomationPermission(for: other)
                    Task { @MainActor in
                        guard let self else { return }
                        self.permissionInFlight.remove(other)
                        self.permissionChecked.insert(other)
                        if result == .denied { self.permissionDenied.insert(other) }
                        else if result == nil { self.probeState(other) }
                    }
                }
                continue
            }
            probeState(other)
        }
    }

    /// One-word "is it playing" query against a player we may hand over to.
    private func probeState(_ other: MusicSource) {
        Self.run(playerStateScript(other)) { [weak self] out in
            Task { @MainActor in
                guard let self, out == "playing" else { return }
                self.playingSources.insert(other)
            }
        }
    }

    /// Read a YouTube tab, resolving which browser holds it and how much that
    /// browser is willing to tell us.
    private func refreshYouTube() {
        let browsers = runningBrowsers.filter { !deniedBundles.contains($0.bundleID) }
        if let b = youtubeBrowser, !browsers.contains(b) { youtubeBrowser = nil }
        guard !browsers.isEmpty else { busy = false; clear(.notRunning); return }

        // Search order matters twice over. Browsers already granted are tried
        // first so no prompt is raised while a usable one exists; browsers
        // already found to have no YouTube tab are set aside so the search
        // actually advances instead of re-asking the same one every poll.
        // Without the second half, a granted-but-empty browser (a windowless
        // Safari, say) pinned the search and the real tab was never found.
        let candidates = browsers.filter { !noTabBrowsers.contains($0) }
        guard !candidates.isEmpty else {
            noTabBrowsers.removeAll()   // start over; a tab may open later
            busy = false
            clear(.notRunning)
            return
        }
        // Never prompt for more than one browser. Rotating through every open
        // browser meant someone with Safari, Brave and Chrome running could be
        // asked three times in a row — which reads as an app demanding access
        // to everything. Granted browsers are probed freely; only the most
        // recently used one is ever worth a prompt.
        let browser: Browser
        if let known = youtubeBrowser {
            browser = known
        } else if let granted = candidates.first(where: { checkedBundles.contains($0.bundleID) }) {
            browser = granted
        } else if let askable = candidates.first(where: { $0 == lastActiveBrowser }) ?? candidates.first,
                  preference == .youtube {
            browser = askable          // explicit choice; a prompt is expected
        } else {
            busy = false; clear(.notRunning); return
        }

        guard checkedBundles.contains(browser.bundleID) else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Self.requestAutomationPermission(bundleID: browser.bundleID)
                Task { @MainActor in
                    guard let self else { return }
                    self.checkedBundles.insert(browser.bundleID)
                    if result == .denied { self.deniedBundles.insert(browser.bundleID) }
                    self.busy = false
                    if result == nil { self.refresh() }
                    else { self.problem = result; self.available = false }
                }
            }
            return
        }

        let fidelity: YouTubeFidelity =
            useTitleOnly(downgradedUntil: titleOnlyUntil[browser], now: Date()) ? .titleOnly : .full
        Self.run(youTubeScript(browser, fidelity: fidelity)) { [weak self] out in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false

                // nil and "" mean different things and must not be conflated:
                // nil is a script *error*, which at .full fidelity means the
                // JavaScript bridge is switched off. "" is a clean run that
                // simply found no YouTube tab in this browser.
                if out == nil {
                    if fidelity == .full {
                        // Bridge is off. Remember for 30s, then re-probe — the
                        // user may enable it at any time.
                        self.titleOnlyUntil[browser] = Date().addingTimeInterval(30)
                        self.refresh()
                    } else {
                        self.clear(.scriptFailed)
                    }
                    return
                }
                guard let out, !out.isEmpty, let n = parseNowPlaying(out) else {
                    // Clean run, no YouTube tab in this browser: set it aside
                    // so the next poll moves on to another one.
                    self.youtubeBrowser = nil
                    self.noTabBrowsers.insert(browser)
                    self.clear(.notRunning)
                    return
                }

                self.youtubeBrowser = browser
                self.noTabBrowsers.removeAll()
                self.youtubeNeedsBridge = (fidelity == .titleOnly)
                self.controllable = n.controllable
                self.problem = nil
                self.available = true
                self.playing = n.playing
                // A page title is one string; split it into artist and track
                // only as far as the title's own convention allows.
                let parsed = parseYouTubeTitle(n.track)
                self.track = parsed.track
                self.artist = parsed.artist
                self.album = ""
                if Date() > self.suppressPollUntil {
                    self.position = n.positionMs / 1000
                    if n.controllable { self.volume = n.volume }
                }
                self.duration = n.durationMs / 1000
                self.shuffling = false
                self.repeating = n.repeating
                // No artwork: a thumbnail would mean a fresh request to
                // Google's CDN for every track, which the privacy policy
                // promises this app does not make.
                self.artwork = nil; self.artKey = ""; self.artAccent = nil
            }
        }
    }

    // MARK: - Artwork

    /// Load the album image once per track.
    ///
    /// Spotify hands over a CDN URL; Apple Music holds the bytes in the local
    /// library and has to be asked to write them out. `key` is whatever
    /// identifies the current art for that source, so both paths skip the work
    /// when the track hasn't changed.
    private func loadArtwork(_ key: String, from source: MusicSource) {
        guard key != artKey else { return }
        artKey = key
        artwork = nil
        artAccent = nil
        guard !key.isEmpty else { return }
        if source.artworkIsRemote { loadRemoteArtwork(key) } else { loadLocalArtwork(key) }
    }

    private func loadRemoteArtwork(_ url: String) {
        guard let u = URL(string: url), u.scheme == "https" else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            // Extract off the main thread: the downsample rasterises the image,
            // and this runs on every track change.
            let accent = Self.accent(of: image)
            Task { @MainActor in
                // A slow fetch may land after the track already changed.
                guard let self, self.artKey == url else { return }
                self.artwork = image
                self.artAccent = accent
            }
        }.resume()
    }

    /// Have Music write the current artwork to a scratch file, then read it.
    ///
    /// The file lives in our own temp directory and is overwritten each time —
    /// it is a transport buffer for bytes the user already owns, not a cache,
    /// so nothing accumulates and nothing needs cleaning up later.
    private func loadLocalArtwork(_ key: String) {
        let path = NSTemporaryDirectory() + "sentrynotch-art.dat"
        guard let script = artworkDumpScript(.appleMusic, path: path) else { return }
        Self.run(script) { [weak self] out in
            guard out == "ok",
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let image = NSImage(data: data) else { return }
            let accent = Self.accent(of: image)
            Task { @MainActor in
                guard let self, self.artKey == key else { return }
                self.artwork = image
                self.artAccent = accent
            }
        }
    }

    /// Downsample the cover to 16×16 and pick an accent from those 256 pixels.
    ///
    /// The small grid is the point, not a compromise: scaling averages away
    /// JPEG noise and single stray pixels for free, and 256 samples is ample for
    /// hue bucketing. Cost is a one-off per track change.
    ///
    /// Runs on the URLSession delegate queue or the script queue. Safe off the
    /// main thread: the drawing target is an offscreen bitmap rep, not a window
    /// or a shared context, and the graphics state is saved and restored.
    private nonisolated static func accent(of image: NSImage) -> RGB? {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        var samples: [RGB] = []
        samples.reserveCapacity(side * side)
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            // Fully transparent pixels are padding, not artwork.
            guard data[i + 3] > 8 else { continue }
            samples.append(RGB(r: Double(data[i]) / 255,
                               g: Double(data[i + 1]) / 255,
                               b: Double(data[i + 2]) / 255))
        }
        return pickAccent(from: samples)
    }

    // MARK: - Transport

    func playPause() { command(.playPause) }
    func next()      { command(.next) }
    func previous()  { command(.previous) }

    func toggleShuffle() {
        shuffling.toggle()
        command(.setShuffle(shuffling))
    }

    func toggleRepeat() {
        repeating.toggle()
        command(.setRepeat(repeating))
    }

    /// Scrub to a fraction of the track.
    func seek(toFraction f: Double) {
        guard duration > 0 else { return }
        let seconds = max(0, min(duration, duration * f))
        position = seconds
        holdPoll()
        command(.seek(seconds))
    }

    func setVolume(_ v: Double) {
        volume = max(0, min(100, v))
        holdPoll()
        command(.setVolume(volume))
    }

    /// Ignore polled position/volume briefly so a drag isn't yanked back by the
    /// next refresh landing mid-gesture.
    private func holdPoll() { suppressPollUntil = Date().addingTimeInterval(1.2) }

    private func command(_ verb: TransportVerb) {
        guard available, controllable else { return }
        if source == .youtube {
            guard let b = youtubeBrowser, let script = youTubeTransportScript(b, verb) else { return }
            Self.run(script) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            return
        }
        guard permissionChecked.contains(source) else { return }
        Self.run(transportScript(source, verb)) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// osascript out-of-process: an AppleScript timeout or a refused Automation
    /// prompt then costs us a nil, not a hung main thread.
    private static func run(_ script: String, timeout: TimeInterval = 10,
                            _ done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { done(nil); return }

            // Kill a script that hangs. An unresponsive app — a browser busy or
            // wedged on an Apple Event, which we have seen take minutes — would
            // otherwise block this thread indefinitely, and because the
            // completion never fires the caller's `busy` flag stays set and the
            // widget stops polling for good. SIGTERM to osascript unblocks the
            // read by closing its end of the pipe.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationStatus == 0 else { done(nil); return }
            done(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Now-playing card: artwork, title/album/artist, full transport, scrubber with
/// elapsed and remaining, and a volume slider.
///
/// Colour is led by the artwork, the way Apple's own now-playing surfaces are:
/// the scrubber fill and the ambient wash take an accent sampled from the
/// cover, the transport stays monochrome, and the app's own accent is the only
/// fallback. No music service's brand colour is drawn.
struct NowPlayingWidget: View {
    @ObservedObject var spotify: NowPlayingController
    var accent: Color
    /// When off, the card uses the app accent instead of a colour sampled from
    /// the cover.
    var useArtColor: Bool = true
    /// When off, the inline volume slider is hidden.
    var showVolume: Bool = true
    /// When on, a long title scrolls instead of truncating (subject to the
    /// motion preference).
    var marquee: Bool = true

    @Environment(\.animationsEnabled) private var animationsEnabled

    /// The colour the card leads with. Falls back to the app accent when art
    /// colour is off, or when the cover is greyscale or hasn't loaded, so the
    /// card is never untinted — an accent that blinks in and out between tracks
    /// reads as a glitch, not as a feature.
    private var tint: Color {
        guard useArtColor, let a = spotify.artAccent else { return accent }
        return Color(red: a.r, green: a.g, blue: a.b)
    }

    var body: some View {
        Group {
            if spotify.available { player } else { placeholder }
        }
        // Album art changes the moment the track does; easing the tint across
        // that boundary is what makes it read as the room lighting up rather
        // than a colour swap.
        .animation(.easeInOut(duration: 0.55), value: spotify.artAccent)
    }

    // MARK: - Player

    private var player: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: spotify.track.isEmpty ? "—" : spotify.track,
                                    font: .system(size: 14, weight: .semibold),
                                    color: CC.text,
                                    enabled: marquee && animationsEnabled)
                        Text(spotify.artist).font(.system(size: 11))
                            .foregroundStyle(CC.textDim).lineLimit(1)
                        if !spotify.album.isEmpty && spotify.album != spotify.track {
                            Text(spotify.album).font(.system(size: 9.5))
                                .foregroundStyle(CC.textFaint).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if spotify.controllable { controls }
                }
                if spotify.controllable { scrubber } else { readOnlyNote }
            }
        }
        .padding(.leading, -2)
        .background(alignment: .leading) {
            // A wash bleeding out of the artwork's edge, so the colour appears
            // to come off the cover itself.
            //
            // A radial gradient rather than a blurred linear one. `blur` forces
            // an offscreen render pass on every recomposite, and the scrubber
            // recomposites this card twice a second; a gradient is drawn in one
            // pass and gives the same falloff. Chosen on that reasoning — the
            // difference was below the noise floor of what I could measure here.
            RadialGradient(colors: [tint.opacity(0.14), tint.opacity(0.03), .clear],
                           center: .leading, startRadius: 4, endRadius: 190)
                .frame(width: 280)
                .allowsHitTesting(false)
        }
    }

    /// Shown instead of transport when the source can be read but not driven.
    /// Naming the exact menu path matters: this setting is buried, and a vague
    /// "not supported" would read as the widget being broken.
    private var readOnlyNote: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle").font(.system(size: 9))
                .foregroundStyle(CC.textFaint)
            Text(spotify.youtubeBrowser.map {
                    $0.isChromium
                        ? "Read-only. For playback control: View ▸ Developer ▸ Allow JavaScript from Apple Events."
                        // Safari 26 moved this out of the Develop menu itself.
                        : "Read-only. For playback control: Develop ▸ Developer Settings… ▸ Allow JavaScript from Apple Events."
                 } ?? "Read-only source.")
                .font(.system(size: 9)).foregroundStyle(CC.textDim)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06))
            if let image = spotify.artwork {
                // Canvas-style widescreen art (Spotify serves some tracks a 640×360
                // frame instead of a square cover) center-crops brutally at 1:1 —
                // often slicing off exactly the part of the design that reads as
                // the cover. A blurred, filled copy behind a fitted, uncropped
                // copy on top keeps every pixel visible and still reads as one
                // square tile, the same trick Music/Spotify use for Canvas art.
                if Self.isWideAspect(image) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 8)
                        .overlay(Color.black.opacity(0.25))
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            } else {
                Image(systemName: "music.note").font(.system(size: 18))
                    .foregroundStyle(CC.textFaint)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        // A soft neutral drop shadow, the way Apple floats artwork: the colour
        // belongs to the ambient wash behind the card, not to a glow ringing
        // the sleeve.
        .shadow(color: .black.opacity(0.38), radius: 8, y: 3)
    }

    private static func isWideAspect(_ image: NSImage) -> Bool {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return false }
        // Only genuinely *wide* frames (Spotify's 640×360 Canvas covers) benefit
        // from the letterbox trick — a square crop there slices off the design.
        // Portrait and near-square art fills cleanly, the way Apple Music always
        // does; letterboxing a tall cover just paints a muddy blurred box.
        return w / h > 1.2
    }

    private var controls: some View {
        HStack(spacing: 12) {
            toggle("shuffle", on: spotify.shuffling) { spotify.toggleShuffle() }
            icon("backward.end.fill", size: 15) { spotify.previous() }
            // A plain glyph, not a filled disc. Apple keeps transport controls
            // monochrome and lets the artwork carry the colour; a saturated
            // circle here reads as another player's language, not the system's.
            Button { spotify.playPause() } label: {
                Image(systemName: spotify.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(CC.text)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            icon("forward.end.fill", size: 15) { spotify.next() }
            toggle("repeat", on: spotify.repeating) { spotify.toggleRepeat() }
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(clock(spotify.position))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(CC.textDim)
                .frame(width: 30, alignment: .leading)
            SeekBar(progress: progress, tint: tint) { spotify.seek(toFraction: $0) }
                .frame(height: 10)
            Text("-\(clock(max(0, spotify.duration - spotify.position)))")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(CC.textDim)
                .frame(width: 34, alignment: .trailing)
            if showVolume {
                Image(systemName: volumeGlyph).font(.system(size: 9))
                    .foregroundStyle(CC.textDim).frame(width: 12)
                SeekBar(progress: spotify.volume / 100, tint: CC.text.opacity(0.75)) {
                    spotify.setVolume($0 * 100)
                }
                .frame(width: 54, height: 10)
            }
        }
    }

    private var volumeGlyph: String {
        spotify.volume < 1 ? "speaker.slash.fill"
            : spotify.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private var progress: Double {
        guard spotify.duration > 0 else { return 0 }
        return min(1, max(0, spotify.position / spotify.duration))
    }

    private func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func icon(_ symbol: String, size: CGFloat,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(CC.text)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? accent : CC.textFaint)
                // A dot under an active toggle survives at this size where a
                // colour change alone does not.
                if on {
                    Circle().fill(accent).frame(width: 2.5, height: 2.5).offset(y: 8)
                }
            }
            .frame(height: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note").font(.system(size: 12))
                .foregroundStyle(CC.textFaint).frame(width: 12)
            Text(message).font(.system(size: 10)).foregroundStyle(CC.textDim)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if spotify.problem == .denied {
                Button("Fix") { openAutomationSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
            }
        }
        .frame(height: 54)
    }

    private var message: String {
        // Named after whichever player is actually selected — telling someone
        // who only uses Apple Music that "Spotify isn't running" is noise.
        let app = spotify.source.label
        switch spotify.problem {
        case .notRunning, .none:
            return "Neither Spotify nor Apple Music is running."
        case .denied:
            return "\(Brand.name) isn't allowed to control \(app). Tick it under Automation, then reopen the notch."
        case .scriptFailed:
            return "\(app) is running but isn't reporting a track — start something playing."
        }
    }

    /// Deep-link straight to the Automation pane; hunting for it manually is
    /// the step most people give up on.
    private func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A thin draggable bar. Click anywhere to jump; drag to scrub. Reports a
/// 0…1 fraction so it serves both the position and volume controls.
private struct SeekBar: View {
    var progress: Double
    var tint: Color
    var onChange: (Double) -> Void

    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 3)
                Capsule().fill(tint)
                    .frame(width: max(0, min(w, w * progress)), height: 3)
                if hovering {
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .offset(x: max(0, min(w, w * progress)) - 4)
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(min(1, max(0, $0.location.x / w))) }
            )
        }
    }
}

/// A single line that scrolls horizontally when it overflows — the way Apple's
/// now-playing title does — and falls back to a truncated line when it fits or
/// when `enabled` is false (marquee off, or Reduce Motion).
///
/// Both the full-text width and the container width are measured in a
/// `.background`, which never resizes the primary view. The base is a *clear,
/// truncating* copy that fills the available width but never exceeds it; the
/// visible (scrolling or truncating) copy rides in an `.overlay` on top. This
/// matters: the scrolling copy is `fixedSize` and so reports its full text
/// width to layout — as a sizing child it would stretch the row and shove the
/// transport controls off the card, and `.clipped()` only clips drawing, not
/// layout. In an overlay it can overflow freely without resizing anything.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var enabled: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        let overflow = max(0, textWidth - containerWidth)
        let scroll = enabled && overflow > 1
        return Text(text).font(font).foregroundStyle(.clear).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if scroll {
                    Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
                        .offset(x: animate ? -overflow : 0)
                        .animation(.linear(duration: max(3, Double(overflow) / 24))
                                    .repeatForever(autoreverses: true), value: animate)
                } else {
                    Text(text).font(font).foregroundStyle(color)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        .clipped()
        .background(GeometryReader { c in
            Color.clear
                .onAppear { containerWidth = c.size.width }
                .onChange(of: c.size.width) { _, w in containerWidth = w }
        })
        .background(alignment: .leading) {
            Text(text).font(font).lineLimit(1).fixedSize().hidden()
                .background(GeometryReader { t in
                    Color.clear
                        .onAppear { textWidth = t.size.width }
                        .onChange(of: t.size.width) { _, w in textWidth = w }
                })
        }
        // Kick the loop off (or stop it) whenever overflow/motion state flips.
        .onChange(of: scroll) { _, s in animate = s }
        .onAppear { animate = scroll }
    }
}
