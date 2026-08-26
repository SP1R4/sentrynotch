import SwiftUI
import SentryNotchCore

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    /// Physical notch height (0 on a notchless display). Content is inset by
    /// this so it clears the notch/menu-bar line.
    @Published var notchHeight: CGFloat = 0
    @Published var notchWidth: CGFloat = 0
    @Published var flankWidth: CGFloat = 46
    /// Intrinsic height of the expanded content, measured by the view and used
    /// by the controller to size the panel. Without this the panel is a fixed
    /// rectangle and anything short of a full list leaves a black void.
    @Published var contentHeight: CGFloat = 0
    /// False when nothing can see the animations — panel occluded, display
    /// asleep, or the screen locked. Sprites and spinners then hold a static
    /// frame instead of rebuilding several times a second.
    @Published var animate = true
    /// A popover is open somewhere in the island.
    ///
    /// Popovers live in their own window, outside the panel's bounds. Opening
    /// one therefore makes the panel resign key *and* fires an `onHover(false)`
    /// — both of which collapse the island, closing the popover the user just
    /// opened. The island must stay put until the popover is dismissed.
    @Published var popoverOpen = false
    /// When the panel last took keyboard focus. Keyboard answers are ignored
    /// for a moment afterwards so a focus-steal can't turn the user's next
    /// keystroke into an answer.
    @Published var focusedAt = Date.distantPast
}

/// Carries the measured content height out of the view tree.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct IslandView: View {
    /// How long after the panel takes focus keyboard answers are ignored.
    /// Covers the keystroke that was already on its way to another app.
    static let keyGrace: TimeInterval = 0.6

    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    var onToggle: () -> Void
    var onDashboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                expanded.transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                CollapsedPill(model: model, state: state, music: model.music, onTap: onToggle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.animationsEnabled, state.animate)
    }

    private var islandShape: some Shape {
        let top = state.notchHeight > 0 ? 0.0 : 20.0
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: 22,
            bottomTrailingRadius: 22, topTrailingRadius: top, style: .continuous)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if state.notchHeight > 0 { Color.clear.frame(height: state.notchHeight) }
            TopStrip(model: model, state: state, onCollapse: onToggle, onDashboard: onDashboard)
            Rectangle().fill(CC.hairline).frame(height: 1)
            if let toast = model.toast { ToastView(toast: toast) }
            if model.showRules {
                RulesView(model: model)
            } else if model.showHistory {
                HistoryView(entries: model.history)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        WidgetRow(model: model, state: state)
                        if model.panic {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.raised.fill").font(.system(size: 11))
                                Text("Panic stop armed — every tool call is being denied").font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Button("Release") { model.setPanic(false) }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            }
                            .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.red.opacity(0.85)))
                        }
                        if let flash = model.flash {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle").font(.system(size: 10))
                                Text(flash).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .foregroundStyle(CC.textDim).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(CC.surfaceHi))
                        }
                        if !model.trustWindows.isEmpty { TrustStrip(model: model) }
                        if model.pending.count > 1 && model.settings.widgetOn("approveSafe") {
                            Button(action: model.approveAllSafe) {
                                Label("Approve all safe (\(model.pending.filter { $0.risk.level == .none }.count))",
                                      systemImage: "checkmark.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(model.settings.accentColor)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(model.settings.accentColor.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(model.pending) { req in
                            PermissionCard(req: req, model: model)
                        }
                        if model.settings.widgetOn("sessions") {
                            ForEach(model.sessions) { card in
                                VStack(spacing: 0) {
                                    SessionRow(card: card,
                                               expanded: model.expandedSessionID == card.id,
                                               policy: model.policyFor(card.cwd),
                                               arming: model.armingFor(card.id),
                                               intercepted: model.isIntercepted(card.id),
                                               onTap: { model.toggleSession(card) },
                                               onRevoke: { model.revokeBypass(card.id) },
                                               onSetPolicy: { model.setPolicy($0, for: card.cwd) },
                                               onSetArming: { model.setArming($0, for: card.id) },
                                               onStash: { model.stashSession(cwd: card.cwd, project: card.project) },
                                               onInterrupt: model.canInterrupt(card) ? { model.interrupt(card) } : nil,
                                               ambiguous: model.sessions.filter { $0.project == card.project }.count > 1)
                                    if model.expandedSessionID == card.id && model.settings.widgetOn("activity") {
                                        ActivityFeed(items: model.activity)
                                    }
                                }
                            }
                        }
                        if model.pending.isEmpty && model.sessions.isEmpty {
                            EmptyState(model: model)
                        }
                    }
                    .padding(10)
                    // Measured inside the ScrollView, so this is the height the
                    // content actually wants — the ScrollView itself always
                    // reports whatever height it is given.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
                }
                .onPreferenceChange(ContentHeightKey.self) { height in
                    Task { @MainActor in state.contentHeight = height }
                }
            }
        }
        .background {
            ZStack {
                // The themed base is used only while expanded; collapsed stays
                // the flat warm-black `CC.panel` so a light custom colour can't
                // stop the ~43pt bar from merging with the physical notch.
                (state.expanded ? model.settings.notchPanel : CC.panel)
                // Ambient wash pulled from the current cover, in front of the
                // panel fill but behind all content so text stays legible.
                if state.expanded {
                    PanelArtTint(music: model.music, enabled: model.settings.panelTintFromArt)
                }
            }
        }
        // Light spilling from the notch seam. The panel is pure flat black
        // against a black bezel, so its top edge reads as a rectangle pasted
        // below the hardware rather than as the notch opening up. A soft warm
        // falloff at the top gives it a source and makes the two read as one
        // object. Purely decorative — no hit testing, and it sits under the
        // clip so it can never bleed past the island's corners.
        //
        // Expanded only. The collapsed notch is ~43pt tall, so a 90pt falloff
        // never reaches `.clear` inside it — instead of a glow at the seam the
        // whole bar lifts to grey, and the collapsed island stops merging with
        // the black bezel it is supposed to be part of.
        .background(alignment: .top) {
            if state.expanded {
                LinearGradient(
                    colors: [Color.white.opacity(0.055), Color.white.opacity(0.012), .clear],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(islandShape)
        .overlay(islandShape.stroke(CC.hairline, lineWidth: 1))
        // A brighter lip along the very top edge only — the highlight a real
        // bezel would catch. Expanded only, for the same reason as the glow:
        // the collapsed bar sits against black and any lift breaks the illusion
        // that it is part of the hardware.
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.white.opacity(state.expanded ? 0.22 : 0), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .mask(LinearGradient(colors: [.clear, .white, .white, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .allowsHitTesting(false)
        }
        .onExitCommand(perform: onToggle)
    }
}

/// Timer and Spotify side by side above the session list. Laid out as a row
/// because the island is now wider than it is tall; either can be switched off
/// in the dashboard, and the row disappears entirely when both are.
/// Timer and now-playing as one ambient strip.
///
/// These are peripheral: useful to glance at, never the reason the panel is
/// open. Previously they were two tall cards stacked above the session list,
/// which inverted the hierarchy — the least important content was the largest
/// and loudest. Collapsed to a single row, they read as a status bar and hand
/// the vertical space back to sessions and prompts.
/// A soft, art-derived wash for the whole expanded panel — the ambient tint
/// Apple's full-screen player pulls from the current cover. Observes the music
/// controller directly so it re-colours on track change without republishing
/// the whole island every second.
private struct PanelArtTint: View {
    @ObservedObject var music: NowPlayingController
    var enabled: Bool

    private var color: Color? {
        guard enabled, music.available, let a = music.artAccent else { return nil }
        return Color(red: a.r, green: a.g, blue: a.b)
    }

    var body: some View {
        // Top-anchored so the colour appears to fall from the notch seam and
        // fades out before the content, keeping the wash subtle.
        LinearGradient(colors: [(color ?? .clear).opacity(color == nil ? 0 : 0.16),
                                (color ?? .clear).opacity(color == nil ? 0 : 0.03),
                                .clear],
                       startPoint: .top, endPoint: .bottom)
            .animation(.easeInOut(duration: 0.55), value: color)
            .allowsHitTesting(false)
    }
}

private struct WidgetRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState

    private var on: (String) -> Bool {
        { id in model.settings.widgetOn(id) }
    }

    var body: some View {
        let accent = model.settings.accentColor
        VStack(spacing: 8) {
            // Media row: timer hugs its content, Spotify takes the rest.
            if on("timer") || on("spotify") {
                HStack(alignment: .top, spacing: 8) {
                    if on("timer") {
                        TimerWidget(timer: model.timer, accent: accent,
                                    presets: model.settings.validTimerPresets,
                                    popoverOpen: $state.popoverOpen)
                            .padding(.horizontal, 11).padding(.vertical, 10)
                            .frame(maxHeight: .infinity)
                            .elevated(radius: 12, strength: 0.7)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if on("spotify") {
                        NowPlayingWidget(spotify: model.music, accent: accent,
                                         useArtColor: model.settings.nowPlayingUseArtColor,
                                         showVolume: model.settings.nowPlayingShowVolume,
                                         marquee: model.settings.nowPlayingMarquee)
                            .padding(.horizontal, 11).padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .elevated(radius: 12)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Status row: both are about "is this run healthy", so they read as
            // a pair rather than competing with the media widgets above.
            if on("headroom") || on("repo") {
                HStack(alignment: .top, spacing: 8) {
                    if on("headroom") {
                        HeadroomWidget(model: model, accent: accent)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .elevated(radius: 12, strength: 0.7)
                    }
                    if on("repo") {
                        RepoWidget(model: model, accent: accent)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .elevated(radius: 12, strength: 0.7)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Agent-vitals row: the run's own instrumentation — how fast it's
            // filling context, and which sessions need you.
            if on("vitals") || on("fleet") {
                HStack(alignment: .top, spacing: 8) {
                    if on("vitals") {
                        VitalsWidget(model: model, accent: accent)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .elevated(radius: 12, strength: 0.7)
                    }
                    if on("fleet") {
                        FleetWidget(model: model, accent: accent)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .elevated(radius: 12, strength: 0.7)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EmptyState: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Sentinel(size: 40).opacity(0.85)
            Text(model.interceptEnabled ? "Listening for sessions" : "Interception is off")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(CC.text)
            Text(model.interceptEnabled
                 ? "Start Claude Code in a terminal —\nits prompts land here."
                 : "Flip the switch above to answer\npermission prompts from the notch.")
                .font(.system(size: 11)).multilineTextAlignment(.center)
                .foregroundStyle(CC.textDim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

private struct CollapsedPill: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    // Observed directly so the music wedge shows/hides and re-dims the instant
    // playback state changes, not a tick later.
    @ObservedObject var music: NowPlayingController
    var onTap: () -> Void

    private var dotColor: Color {
        if !model.pending.isEmpty { return model.settings.accentColor }
        if model.sessions.contains(where: { $0.isActive }) { return .orange }
        return CC.textFaint
    }

    private var activeProject: String {
        model.sessions.first(where: { $0.isActive })?.project ?? "claude"
    }

    /// The centre lip below the physical notch: the dot / pending count /
    /// working ticker. No background of its own — the whole band shares one.
    private var centerLip: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.notchHeight)
            HStack(spacing: 5) {
                if !model.pending.isEmpty {
                    Circle().fill(model.settings.accentColor).frame(width: 6, height: 6)
                        .shadow(color: model.settings.accentColor.opacity(0.8), radius: 3)
                    Text("\(model.pending.count)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(CC.text)
                } else if model.hasActiveSession, let tool = model.ticker_text {
                    // The walking mascots already say "working". Running a
                    // second animated indicator beside them was redundant and
                    // cost another 10 rebuilds a second.
                    if !showMascot { Spinner(size: 8) }
                    Text(tool).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CC.textDim).lineLimit(1)
                } else if model.timer.running && model.settings.widgetOn("timer") {
                    // Nothing is working — give the lip to the running timer.
                    Image(systemName: "timer").font(.system(size: 8))
                        .foregroundStyle(model.settings.accentColor)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(TimerModel.clock(model.timer.remaining))
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(CC.textDim)
                    }
                } else {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 11).padding(.horizontal, 6)
        }
    }

    /// One sprite per working session. Each carries its own mood and project
    /// colour, so three concurrent sessions read as three walkers rather than
    /// one mood for whichever happens to be busiest.
    private var riders: [Rider] {
        model.sessions.filter(\.isActive).map { card in
            let mine = model.pending.filter { $0.sessionID == card.id }
            let danger = mine.contains { $0.risk.level >= .high || !model.scopeFlags($0).isEmpty }
            let mood: Sentinel.Mood = danger ? .alarmed
                : !mine.isEmpty ? .alert
                : model.isCelebrating(card.id) ? .celebrating
                : Sentinel.mood(forTool: card.lastTool)
            let color = model.settings.mascotUsesProjectColor
                ? projectTint(card.project) : model.settings.accentColor
            return Rider(id: card.id, mood: mood, color: danger ? CC.alarm : color)
        }
    }

    private var showMascot: Bool { model.hasActiveSession && model.settings.mascotEnabled }

    /// The right wedge shows the music source's mark while a track is actively
    /// playing — on its own now, so it appears even with no session working (the
    /// notch grows a flank for it in `NotchController.collapsedSize`). Gated on
    /// `playing`, not merely `available`, so it disappears the moment playback
    /// pauses or stops rather than lingering, dimmed.
    private var showMusic: Bool {
        model.settings.widgetOn("spotify") && music.playing
    }

    /// Whether the notch is wearing side flanks at all — for either the mascots
    /// or the music mark. Drives the empty spacers that keep it centred under the
    /// hardware notch when only one side has content.
    private var wantsFlanks: Bool { showMascot || showMusic }

    var body: some View {
        if state.notchHeight > 0 {
            // One continuous black band — mascots on the wedges, lip in the
            // middle — clipped once so the bottom is a single smooth curve
            // (no pinched seams where the pieces meet).
            let crew = riders
            let split = spriteLayout(sessionCount: crew.count, maxPerWedge: 2)
            let slots = max(split.left, split.right)
            // The notch always grows on both sides to stay centred under the
            // physical notch, so both wedges must be filled. A single session
            // dealt only to the left left the right wedge as an empty black
            // slab — it read as the animation failing to load. One session is
            // mirrored across both wedges instead.
            // …unless music is playing, in which case the right wedge is a
            // better home for the visualiser than a duplicate owl: work on the
            // left, music on the right.
            let mirror = crew.count == 1 && !showMusic
            let leftRiders = mirror ? crew : Array(crew.prefix(split.left))
            let rightRiders = mirror ? crew : Array(crew.dropFirst(split.left).prefix(split.right))
            HStack(spacing: 0) {
                // Left wedge: mascots, or an empty spacer that keeps the band
                // centred when only the right side (music) has content.
                if showMascot {
                    FlankMascot(state: state, riders: leftRiders, slots: slots)
                } else if wantsFlanks {
                    Color.clear.frame(width: state.flankWidth)
                }
                centerLip.frame(width: state.notchWidth)
                // Right wedge: music wins it, else mascots, else an empty spacer.
                if showMusic {
                    FlankMusic(state: state, source: music.source,
                               playing: music.playing,
                               color: model.settings.accentColor)
                } else if showMascot {
                    FlankMascot(state: state, riders: rightRiders,
                                overflow: split.overflow, slots: slots)
                } else if wantsFlanks {
                    Color.clear.frame(width: state.flankWidth)
                }
            }
            .background(CC.inkTop)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        } else {
            HStack(spacing: 7) {
                Mark().frame(width: 13, height: 13)
                Text(model.pending.isEmpty ? Brand.name : "\(model.pending.count) pending")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CC.text)
            }
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(CC.ink))
            .overlay(Capsule().stroke(CC.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture(perform: onTap).padding(.top, 2)
        }
    }
}

/// One working session's sprite: its own mood and project colour.
struct Rider: Identifiable {
    let id: String
    let mood: Sentinel.Mood
    let color: Color
}

/// The Claude mascots riding a notch wedge — one per working session, up to two
/// per side. Each acts out its own session's state (walking / alerting /
/// alarmed). The black background and rounded bottom are owned by the parent
/// band, so the whole notch reads as one shape.
private struct FlankMascot: View {
    @ObservedObject var state: NotchState
    var riders: [Rider]
    /// Sessions that didn't fit on either wedge, shown as a "+N" on the right.
    var overflow: Int = 0
    /// Sprites on the *busiest* wedge. Both wedges size to this so an odd
    /// session count doesn't put a giant sprite next to two small ones.
    var slots: Int

    private var botSize: CGFloat {
        // The owl is square (12×12), so height == size. Fit it inside the wedge
        // on both axes, leaving a little breathing room on each edge.
        let n = CGFloat(max(1, slots))
        let byWidth = (state.flankWidth - 8) / n - (n > 1 ? 2 : 0)
        return max(9, min(byWidth, state.notchHeight - 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: slots > 1 ? 3 : 0) {
                ForEach(riders) { r in
                    Sentinel(size: botSize, color: r.color, mood: r.mood)
                }
                if overflow > 0 {
                    Text("+\(overflow)").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(CC.textDim)
                }
            }
            .frame(width: state.flankWidth, height: state.notchHeight)
            Spacer(minLength: 0)
        }
        .frame(width: state.flankWidth)
    }
}

/// The current music source's mark on the right wedge, sized like the mascots
/// beside it. Replaces the animated equalizer bars with a static brand mark,
/// which reads more clearly at wedge size and doesn't compete with the walking
/// sprites on the left. Dimmed while paused.
private struct FlankMusic: View {
    @ObservedObject var state: NotchState
    var source: MusicSource
    var playing: Bool
    var color: Color
    @Environment(\.animationsEnabled) private var animationsEnabled

    private var markSize: CGFloat { min(state.flankWidth - 10, state.notchHeight - 6) }

    var body: some View {
        VStack(spacing: 0) {
            dancing(mark)
                .frame(width: state.flankWidth, height: state.notchHeight)
            Spacer(minLength: 0)
        }
        .frame(width: state.flankWidth)
    }

    /// Bobs, sways, and pulses the mark to the beat while a track plays — a
    /// double-time bounce with a slower sway, so it grooves rather than jitters.
    /// Held still when paused or when Reduce Motion is on.
    @ViewBuilder private func dancing(_ v: some View) -> some View {
        if playing && animationsEnabled {
            // 30fps periodic, not `.animation`: the rest of the notch caps its
            // frame rate this way on purpose (see DesignSystem) — a display-
            // linked schedule would rebuild this shadowed gradient at 120Hz.
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                v.scaleEffect(1 + 0.045 * sin(t * 6.6))
                    .rotationEffect(.degrees(9 * sin(t * 3.3)))
                    .offset(y: 1.4 * sin(t * 6.6))
            }
        } else {
            v
        }
    }

    @ViewBuilder private var mark: some View {
        switch source {
        case .spotify:
            SpotifyMark(size: markSize)
        case .appleMusic:
            Image(systemName: "music.note").font(.system(size: markSize * 0.62, weight: .bold))
                .foregroundStyle(color)
        case .youtube:
            Image(systemName: "play.rectangle.fill").font(.system(size: markSize * 0.6))
                .foregroundStyle(color)
        }
    }
}

/// The Spotify mark — the three sound-wave arcs on the green disc — drawn rather
/// than bundled as the trademarked asset: recognisable at wedge size, with no
/// image file to ship. Brand colour is used here deliberately, at the app
/// owner's request (it reverses the card's "no service brand colour" rule).
struct SpotifyMark: View {
    var size: CGFloat
    private let brand = Color(red: 0.114, green: 0.725, blue: 0.329)

    var body: some View {
        ZStack {
            // Cinematic disc: a lit gradient with a top-left gloss and a faint
            // rim, so the mark reads as a polished button rather than a flat
            // sticker on the black notch.
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.118, green: 0.843, blue: 0.376),
                                              Color(red: 0.086, green: 0.596, blue: 0.271)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.22), .clear],
                                                      center: .init(x: 0.32, y: 0.24),
                                                      startRadius: 0, endRadius: size * 0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: max(0.5, size * 0.015)))
            GeometryReader { geo in
                let s = geo.size
                let lw = max(1, s.width * 0.12)
                ForEach(0..<3, id: \.self) { i in
                    wave(i, in: s).stroke(.black, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: brand.opacity(0.6), radius: size * 0.14, y: size * 0.03)
    }

    // The three sound-waves as concentric circular arcs sharing a centre just
    // below the disc — wide and shallow like the real mark, top arc largest.
    private func wave(_ i: Int, in s: CGSize) -> Path {
        let radii: [CGFloat] = [0.68, 0.52, 0.36]
        let center = CGPoint(x: s.width * 0.5, y: s.height * 1.05)
        let theta = Angle.degrees(33)
        var p = Path()
        p.addArc(center: center, radius: radii[i] * s.height,
                 startAngle: .degrees(270) - theta, endAngle: .degrees(270) + theta,
                 clockwise: false)
        return p
    }
}

private struct TopStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    var onCollapse: () -> Void
    var onDashboard: () -> Void

    private var usage: String {
        var parts: [String] = []
        if model.liveTokens > 0 {
            let k = model.liveTokens / 1000
            parts.append(k > 0 ? "\(k)k ctx" : "\(model.liveTokens) ctx")
        }
        parts.append("\(model.sessions.filter(\.isActive).count) active")
        if !model.pending.isEmpty { parts.append("\(model.pending.count) pending") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Mark(color: model.settings.accentColor).frame(width: 16, height: 16)
            // The wordmark always shows. With the usage strip switched off the
            // left half of the toolbar was empty apart from a 15pt orange
            // smudge, which read as the app having nothing to say.
            Text(Brand.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(CC.text).fixedSize()
            if model.settings.widgetOn("usage") {
                Rectangle().fill(CC.hairline).frame(width: 1, height: 12)
                usageLabel
            }
            if model.scopeActive {
                Image(systemName: "scope").font(.system(size: 10)).foregroundStyle(model.settings.accentColor)
                    .help("Engagement scope loaded — out-of-scope hosts are flagged")
            }
            Spacer(minLength: 4)
            if model.settings.pluginOn("usageProbe") {
                if model.usageLoading {
                    Spinner(size: 11)
                } else {
                    IconButton(system: "gauge.with.needle", tint: CC.textDim) { model.refreshUsage() }
                        .help("Fetch real 5h/7d reset — makes one cheap Claude call")
                }
            }
            Button { model.setPanic(!model.panic) } label: {
                Image(systemName: model.panic ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(model.panic ? .white : Color.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(model.panic ? Color.red : Color.red.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help(model.panic ? "Panic stop is ARMED — every call is denied. Click to release."
                              : "Panic stop — deny every tool call until released")
            HStack(spacing: 3) {
                Text("intercept").font(.system(size: 9, weight: .medium)).foregroundStyle(CC.textFaint)
                SwitchToggle(isOn: $model.interceptEnabled, tint: model.settings.accentColor)
                    .help("On: Claude Code permission prompts route here. Off: the terminal handles them.")
            }
            IconButton(system: "square.grid.2x2", tint: CC.textDim, action: onDashboard)
                .help("Dashboard — appearance, widgets, plugins")
            IconButton(system: model.showRules ? "slider.horizontal.3" : "slider.horizontal.2.square",
                       tint: model.showRules ? CC.coral : CC.textDim) { model.toggleRules() }
                .help("Manage standing rules (Always-Allow, bypass, per-project policy)")
            IconButton(system: model.showHistory ? "clock.fill" : "clock",
                       tint: model.showHistory ? CC.coral : CC.textDim) { model.toggleHistory() }
                .help("Decision history")
            IconButton(system: state.pinned ? "pin.fill" : "pin",
                       tint: state.pinned ? CC.coral : CC.textDim) { state.pinned.toggle() }
                .help("Keep the island open (don't auto-collapse)")
            IconButton(system: "chevron.up", tint: CC.textDim, action: onCollapse)
        }
        .padding(.horizontal, 12).frame(height: 42)
    }

    @ViewBuilder private var usageLabel: some View {
        if model.usageWindows.isEmpty {
            Text(usage).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CC.textDim).lineLimit(1)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(model.usageWindows.map { "\($0.kind) \(resetIn($0.resetsAt))" }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CC.textDim).lineLimit(1)
                    .help("Time until each rate-limit window resets")
            }
        }
    }

    private func resetIn(_ date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        return "\(s / 86400)d\((s % 86400) / 3600)h"
    }
}

private struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11))
            Text(toast.text).font(.system(size: 11, weight: .medium)).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(tint).padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14))
    }
    private var icon: String {
        switch toast.kind { case .done: return "checkmark.circle.fill"
        case .attention: return "bell.fill"; case .info: return "info.circle.fill" }
    }
    private var tint: Color {
        switch toast.kind { case .done: return .green; case .attention: return CC.coral; case .info: return CC.textDim }
    }
}

private struct HistoryView: View {
    let entries: [AuditLog.Entry]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if entries.isEmpty {
                    Text("No decisions recorded yet.").font(.system(size: 12))
                        .foregroundStyle(CC.textDim).padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
                ForEach(entries) { e in
                    HStack(spacing: 8) {
                        Text(mark(e.decision)).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color(e.decision)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(e.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(CC.text)
                                Text(e.project).font(.system(size: 10)).foregroundStyle(CC.textFaint)
                                Spacer()
                                Text(shortTime(e.ts)).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CC.textFaint)
                            }
                            if !e.summary.isEmpty {
                                Text(e.summary).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CC.textDim).lineLimit(1)
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
                }
            }
            .padding(10)
        }
    }
    private func mark(_ d: String) -> String {
        if d.hasPrefix("allow") { return "✓" }
        if d.hasPrefix("deny") { return "✗" }
        return "•"
    }
    private func color(_ d: String) -> Color {
        if d.hasPrefix("allow") { return .green }
        if d.hasPrefix("deny") { return .red }
        return CC.textFaint
    }
    private func shortTime(_ iso: String) -> String {
        String(iso.dropFirst(11).prefix(8))   // HH:MM:SS
    }
}

/// Manager for standing grants: Always-Allow rules, bypassed sessions, and
/// per-project policy overrides — each revocable — plus the fail-closed switch.
/// Closes the "grants accumulate invisibly" gap.
private struct RulesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(CC.coral)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fail closed on risky prompts")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                        Text("Deny unanswered high-risk / out-of-scope calls at timeout")
                            .font(.system(size: 10)).foregroundStyle(CC.textDim)
                    }
                    Spacer()
                    Toggle("", isOn: $model.failClosedRisky)
                        .toggleStyle(.switch).controlSize(.mini).tint(CC.coral)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

                HStack(spacing: 8) {
                    Image(systemName: "person.badge.shield.checkmark")
                        .font(.system(size: 13)).foregroundStyle(CC.coral)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Intercept new sessions")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                        Text("Off = only sessions you arm are caught, so the hook's \"*\" matcher can't grab the one you're working in")
                            .font(.system(size: 10)).foregroundStyle(CC.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $model.interceptNewSessions)
                        .toggleStyle(.switch).controlSize(.mini).tint(CC.coral)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))

                let armings = model.armingList
                section("Per-session interception",
                        empty: armings.isEmpty ? "Every session follows the default." : nil) {
                    ForEach(armings, id: \.session) { entry in
                        ruleRow(icon: entry.arming == .muted ? "bell.slash" : "shield.checkerboard",
                                text: "\(sessionLabel(entry.session)) — \(entry.arming.label)",
                                tint: entry.arming == .muted ? CC.textDim : CC.coral) {
                            model.setArming(.inherit, for: entry.session)
                        }
                    }
                }

                section("Always-Allow rules",
                        empty: model.alwaysAllowList.isEmpty ? "No standing allow rules." : nil) {
                    ForEach(model.alwaysAllowList, id: \.self) { key in
                        ruleRow(icon: "checkmark.seal", text: key) { model.revokeAlways(key) }
                    }
                }

                section("Bypassed sessions",
                        empty: model.bypassedSessions.isEmpty ? "No bypassed sessions." : nil) {
                    ForEach(Array(model.bypassedSessions).sorted(), id: \.self) { sid in
                        ruleRow(icon: "shield.slash", text: bypassLabel(sid),
                                tint: .red.opacity(0.8)) { model.revokeBypass(sid) }
                    }
                }

                let policies = model.projectPolicy.sorted { $0.key < $1.key }
                section("Per-project policy",
                        empty: policies.isEmpty ? "All projects use the default." : nil) {
                    ForEach(policies, id: \.key) { kv in
                        ruleRow(icon: "folder.badge.gearshape",
                                text: "\((kv.key as NSString).lastPathComponent) — \(kv.value.label)") {
                            model.setPolicy(.inherit, for: kv.key)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, empty: String?,
                                               @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(CC.textFaint)
            if let empty {
                Text(empty).font(.system(size: 11)).foregroundStyle(CC.textDim)
            }
            content()
        }
    }

    private func ruleRow(icon: String, text: String, tint: Color = CC.coral,
                         revoke: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
            Text(text).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CC.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("revoke", action: revoke).buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(CC.coral)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 9).fill(CC.surface))
    }

    private func bypassLabel(_ sid: String) -> String { sessionLabel(sid) }

    private func sessionLabel(_ sid: String) -> String {
        if let card = model.sessions.first(where: { $0.id == sid }) { return card.project }
        return String(sid.prefix(8))
    }
}

private struct PermissionCard: View {
    let req: PermissionRequest
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text("Claude wants to run \(req.toolName)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(CC.text)
            RiskBanner(risk: req.risk)
            ScopeBanner(hosts: model.scopeFlags(req))
            BlastBanner(radius: model.blast(req))
            DetailView(detail: req.detail)
            PreflightBanner(notes: req.preflight)
            if let s = model.suggestion(for: req) { SuggestionBar(model: model, suggestion: s) }
            countdown
            HStack(spacing: 6) {
                PillButton(title: "Deny", key: "⌘1", style: .plain) { model.deny(req) }
                PillButton(title: "Allow Once", key: "⌘2", style: .primary) { model.allowOnce(req) }
                PillButton(title: "Always", key: "⌘3", style: .plain) { model.alwaysAllow(req, source: "Always button") }
                PillButton(title: "Bypass", key: "⌘4", style: .danger) { model.bypass(req) }
            }
            trustRow
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CC.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(borderColor, lineWidth: 1))
    }

    private var borderColor: Color {
        req.risk.level >= .high ? Color.red.opacity(0.55)
            : req.risk.level >= .medium ? Color.orange.opacity(0.45) : CC.coral.opacity(0.45)
    }

    /// Time-boxed trust: approve the routine stuff for a few minutes without a
    /// permanent grant. Read-only is the safe default; "all" is offered too but
    /// visually quieter.
    private var trustRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.checkmark").font(.system(size: 9)).foregroundStyle(CC.textFaint)
            Text("Trust here:").font(.system(size: 10)).foregroundStyle(CC.textFaint)
            Button("reads 5m") { model.grantTrust(cwd: req.cwd, tier: .readOnly, minutes: 5) }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CC.coral)
            Text("·").foregroundStyle(CC.textFaint)
            Button("reads 15m") { model.grantTrust(cwd: req.cwd, tier: .readOnly, minutes: 15) }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CC.coral)
            Text("·").foregroundStyle(CC.textFaint)
            Button("all 5m") { model.grantTrust(cwd: req.cwd, tier: .all, minutes: 5) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(CC.textDim)
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Sentinel(size: 16)
            Text(projectLabel).font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(CC.text)
            if let term = req.terminal {
                Tag(text: term, tint: CC.textDim)
                IconButton(system: "arrow.up.forward.app", tint: CC.textDim) { model.focusTerminal(req) }
            }
            Spacer()
            if req.agent != "claude" { Tag(text: req.agent, tint: model.settings.accentColor) }
            Tag(text: req.toolName, tint: CC.coral)
        }
    }

    /// Says what will *actually* happen at the deadline. Under fail-closed a
    /// high-risk or out-of-scope call is denied, not deferred — showing
    /// "auto-defers" there would misrepresent the safety posture.
    private var willDeny: Bool {
        model.failClosedRisky
            && (req.risk.level >= .high || !model.scopeFlags(req).isEmpty)
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(0, Int(req.deadline.timeIntervalSinceNow))
            Text(willDeny ? "auto-denies in \(remaining)s if unanswered"
                          : "auto-defers in \(remaining)s if unanswered")
                .font(.system(size: 10))
                .foregroundStyle(willDeny ? Color.red.opacity(0.75) : CC.textFaint)
        }
    }

    private var projectLabel: String {
        let name = (req.cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }
}

private struct RiskBanner: View {
    let risk: RiskReport
    var body: some View {
        if !risk.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                Text(risk.reasons.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.14)))
        }
    }
    private var tint: Color { risk.level >= .high ? .red : .orange }
}

/// Active time-boxed trust windows, with a live countdown and one-tap revoke.
private struct TrustStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 4) {
            ForEach(model.trustWindows) { tw in
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = Int(tw.remaining(now: ctx.date))
                    HStack(spacing: 7) {
                        Image(systemName: "clock.badge.checkmark").font(.system(size: 11))
                            .foregroundStyle(model.settings.accentColor)
                        Text("Trusting \(tw.tier == .all ? "all tools" : "reads") in \(tw.label)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(CC.text)
                        Spacer()
                        Text(String(format: "%d:%02d", secs / 60, secs % 60))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CC.textDim)
                        Button { model.revokeTrust(tw.id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                .foregroundStyle(CC.textFaint)
                        }.buttonStyle(.plain).help("Revoke now")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(model.settings.accentColor.opacity(0.12)))
                }
            }
        }
    }
}

/// Read-only "what this will actually do" preview — rm expansion counts and
/// irreversible-git notes — so a Bash decision isn't made blind.
private struct PreflightBanner: View {
    let notes: [PreflightNote]
    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Pre-flight", systemImage: "binoculars.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(CC.textDim)
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: icon(note.severity)).font(.system(size: 10))
                        Text(note.text).font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(color(note.severity))
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(CC.surfaceHi))
        }
    }
    private func color(_ s: PreflightNote.Severity) -> Color {
        switch s { case .danger: return .red; case .caution: return .orange; case .info: return CC.textDim }
    }
    private func icon(_ s: PreflightNote.Severity) -> String {
        switch s {
        case .danger: return "exclamationmark.octagon.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }
}

private struct ScopeBanner: View {
    let hosts: [String]
    var body: some View {
        if !hosts.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "scope").font(.system(size: 11))
                Text("out of engagement scope: \(hosts.joined(separator: ", "))")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.red).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.red.opacity(0.16)))
        }
    }
}

private struct DetailView: View {
    let detail: ToolDetail
    var body: some View {
        switch detail {
        case .command(let cmd):
            codeBox { Text(highlightShell(cmd)) }
        case .write(let path, let content):
            VStack(alignment: .leading, spacing: 4) {
                pathLabel(path, verb: "create")
                codeBox { Text(content.prefix(1200)).foregroundStyle(.green.opacity(0.85)) }
            }
        case .diff(let path, let lines):
            VStack(alignment: .leading, spacing: 4) {
                pathLabel(path, verb: "edit")
                codeBox {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(lines.prefix(40)) { line in
                            Text(prefix(line) + line.text)
                                .foregroundStyle(color(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        case .text(let s):
            codeBox { Text(s.prefix(1200)).foregroundStyle(CC.textDim) }
        }
    }

    private func pathLabel(_ path: String, verb: String) -> some View {
        Text("\(verb) \((path as NSString).lastPathComponent)")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(CC.textDim)
    }
    private func prefix(_ l: DiffLine) -> String {
        switch l.kind { case .added: return "+ "; case .removed: return "- "; case .context: return "  " }
    }
    private func color(_ l: DiffLine) -> Color {
        switch l.kind {
        case .added: return .green.opacity(0.85)
        case .removed: return .red.opacity(0.8)
        case .context: return CC.textFaint
        }
    }
    private func codeBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content().font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220).padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)))
    }
}

private struct Tag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

private struct IconButton: View {
    let system: String
    var tint: Color = CC.textDim
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: system).font(.system(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(tint)
    }
}

private struct PillButton: View {
    enum Style { case plain, primary, danger }
    let title: String
    let key: String
    var style: Style = .plain
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(key).font(.system(size: 8)).opacity(0.5)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(bg)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var bg: some View {
        switch style {
        case .primary:
            RoundedRectangle(cornerRadius: 9).fill(
                LinearGradient(colors: [CC.coral, CC.coral.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom))
        case .danger:
            RoundedRectangle(cornerRadius: 9).fill(Color.red.opacity(0.16))
        case .plain:
            RoundedRectangle(cornerRadius: 9).fill(CC.surfaceHi)
        }
    }
    private var fg: Color {
        switch style {
        case .primary: return .white
        case .danger: return .red.opacity(0.9)
        case .plain: return CC.text
        }
    }
}

/// "This touches N files, M outside the project." The command string answers
/// what will run; this answers how far it reaches, which is the question you
/// actually weigh before approving.
private struct BlastBanner: View {
    let radius: BlastRadius

    var body: some View {
        if !radius.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    // Name the paths that leave the project. A count alone
                    // ("2 outside") isn't actionable — which two matters.
                    ForEach((radius.sensitive + radius.outside).prefix(3), id: \.self) { p in
                        Text(p).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CC.textDim).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        }
    }

    private var summary: String {
        var parts: [String] = []
        let n = radius.total
        parts.append("touches \(n) path\(n == 1 ? "" : "s")")
        if !radius.outside.isEmpty { parts.append("\(radius.outside.count) outside the project") }
        if !radius.sensitive.isEmpty { parts.append("\(radius.sensitive.count) credential") }
        return parts.joined(separator: " · ")
    }
    private var icon: String {
        !radius.sensitive.isEmpty ? "key.fill"
            : !radius.outside.isEmpty ? "arrow.up.forward.square" : "doc.on.doc"
    }
    private var tint: Color {
        !radius.sensitive.isEmpty ? CC.alarm
            : !radius.outside.isEmpty ? .orange : CC.textDim
    }
}

/// Offered inline on the prompt it would remove. The log knows which asks are
/// reflexive; this turns the most repetitive one into a rule at the moment it
/// is annoying you, rather than burying it in a settings pane.
private struct SuggestionBar: View {
    @ObservedObject var model: AppModel
    let suggestion: RuleSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").font(.system(size: 11))
                .foregroundStyle(model.settings.accentColor)
            Text("You've allowed **\(suggestion.label)** \(suggestion.manual) times")
                .font(.system(size: 11)).foregroundStyle(CC.textDim)
            Spacer(minLength: 4)
            Button("Always allow") { model.acceptSuggestion(suggestion) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(model.settings.accentColor))
            Button {
                model.dismissSuggestion(suggestion)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CC.textFaint)
            }
            .buttonStyle(.plain)
            .help("Don't suggest this again")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(model.settings.accentColor.opacity(0.10)))
    }
}

private struct SessionRow: View {
    let card: SessionCard
    var expanded: Bool
    var policy: ProjectPolicy
    var arming: SessionArming
    var intercepted: Bool
    var onTap: () -> Void
    var onRevoke: () -> Void
    var onSetPolicy: (ProjectPolicy) -> Void
    var onSetArming: (SessionArming) -> Void
    var onStash: () -> Void
    var onInterrupt: (() -> Void)?
    /// True when another visible card shares this card's project name. The
    /// project label alone (the cwd's basename) can't tell two sessions in the
    /// same directory apart, so a short session-id chip is shown to break the
    /// tie — but only when it's actually needed.
    var ambiguous: Bool = false

    /// A working card mimes its current tool; a card that has been quiet for
    /// more than five minutes dozes rather than staring blankly.
    private var rowMood: Sentinel.Mood {
        guard card.isActive else {
            return Date().timeIntervalSince(card.lastActivity) > 300 ? .dozing : .idle
        }
        return Sentinel.mood(forTool: card.lastTool)
    }

    var body: some View {
        HStack(spacing: 10) {
            // A live session gets an accent bar down its left edge, so "which
            // of these is actually running" is answerable from peripheral
            // vision rather than by reading timestamps.
            Capsule()
                .fill(card.isActive ? projectTint(card.project) : Color.clear)
                .frame(width: 2.5)
            ZStack {
                Sentinel(size: 20, color: projectTint(card.project),
                         mood: rowMood)
                    .opacity(card.isActive ? 1 : 0.45)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(CC.textFaint)
                    Text(card.project).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(CC.text)
                    if let term = card.terminal { Tag(text: term, tint: CC.textDim) }
                    else if ambiguous { Tag(text: String(card.id.prefix(6)), tint: CC.textFaint) }
                    // Only worth saying when it differs from the global default,
                    // otherwise every card carries a redundant badge.
                    if arming != .inherit {
                        Tag(text: arming == .muted ? "not intercepted" : "intercepted",
                            tint: arming == .muted ? CC.textDim : CC.coral)
                    }
                    if policy != .inherit {
                        Tag(text: policy.label, tint: policy == .bypassAll ? .red.opacity(0.8) : CC.coral)
                    }
                    if card.bypassed {
                        Tag(text: "bypassed", tint: .red.opacity(0.8))
                        Button("revoke", action: onRevoke).buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(CC.coral)
                    }
                    Spacer()
                    if card.tokens > 0 {
                        Text(tokenLabel(card.tokens))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(CC.textFaint)
                    }
                    if card.isActive, let onInterrupt {
                        Button(action: onInterrupt) { Image(systemName: "stop.circle").font(.system(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
                            .help("Interrupt this session")
                    }
                    Text(relativeTime(card.lastActivity))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(CC.textFaint)
                }
                if !card.lastText.isEmpty {
                    Text(card.lastText).font(.system(size: 11)).foregroundStyle(CC.textDim).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 10).padding(.trailing, 10).padding(.leading, 8)
        .elevated(radius: 13, strength: card.isActive ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Text("Auto-allow policy — \(card.project)")
            Divider()
            ForEach(ProjectPolicy.allCases, id: \.self) { p in
                Button {
                    onSetPolicy(p)
                } label: {
                    Label(p.label, systemImage: policy == p ? "checkmark" : "")
                }
            }
            Divider()
            Text("Intercept this session\(intercepted ? "" : " (currently off)")")
            ForEach(SessionArming.allCases, id: \.self) { a in
                Button {
                    onSetArming(a)
                } label: {
                    Label(a.label, systemImage: arming == a ? "checkmark" : "")
                }
            }
            Divider()
            Button { onStash() } label: {
                Label("Stash working changes (recoverable)", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func tokenLabel(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k tok" : "\(n) tok"
    }
    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

/// The expanded session's live feed — the agent's messages and tool calls.
private struct ActivityFeed: View {
    let items: [ActivityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("no recent activity").font(.system(size: 11)).foregroundStyle(CC.textFaint)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 7) {
                    Text(glyph(item.kind)).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color(item.kind)).frame(width: 12)
                    Text(item.text)
                        .font(.system(size: 11, design: item.kind == .tool ? .monospaced : .default))
                        .foregroundStyle(color(item.kind))
                        .lineLimit(item.kind == .assistant ? 4 : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        // Recessed rather than elevated: this is the *inside* of the card above
        // it, so it should read as a well, not as another floating surface.
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
        )
        .padding(.horizontal, 6).padding(.top, 4)
        .padding(.top, 3)
    }

    private func glyph(_ k: ActivityItem.Kind) -> String {
        switch k { case .user: return "›"; case .assistant: return "✦"; case .tool: return "⚙"; case .result: return "↳" }
    }
    private func color(_ k: ActivityItem.Kind) -> Color {
        switch k {
        case .user: return CC.text
        case .assistant: return CC.coral
        case .tool: return Color(red: 0.55, green: 0.78, blue: 0.85)
        case .result: return CC.textFaint
        }
    }
}
