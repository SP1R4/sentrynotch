import SwiftUI
import AppKit

/// sRGB hex ↔ Color, for the user-customisable notch background. Six-digit
/// `RRGGBB`, with or without a leading `#`.
extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// Uppercase `RRGGBB` (no `#`). Falls back to black if the colour can't be
    /// resolved into sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

/// Whether continuously-animating views should actually animate.
///
/// Every sprite and spinner here is driven by `TimelineView(.periodic)`, which
/// keeps rebuilding — and therefore keeps triggering layout and a Core
/// Animation commit — regardless of whether anyone can see the result. With a
/// session working, that was ~42 rebuilds a second burning >20% CPU
/// continuously, including while the panel was fully covered or the display was
/// asleep. When this is false the same views render one static frame instead.
private struct AnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var animationsEnabled: Bool {
        get { self[AnimationsEnabledKey.self] }
        set { self[AnimationsEnabledKey.self] = newValue }
    }
}

/// Sentry Notch visual language — warm near-black surfaces that fuse with the
/// physical notch, a single accent, cream text. Every graphic is drawn in
/// SwiftUI, so the app ships no image assets and nothing is derived from
/// another vendor's artwork.
enum CC {
    static let coral = Color(red: 0.85, green: 0.46, blue: 0.34)     // ~#D97757
    static let coralDim = Color(red: 0.85, green: 0.46, blue: 0.34).opacity(0.16)
    static let alarm = Color(red: 0.90, green: 0.28, blue: 0.24)     // high-risk red
    static let ink = Color(red: 0.11, green: 0.105, blue: 0.10)      // warm near-black
    static let inkTop = Color(red: 0.04, green: 0.038, blue: 0.035)  // blends into the notch
    // Slightly lifted from the original values so cards, dividers, and dim
    // text read clearly on the near-black panel instead of sinking into it —
    // a legibility pass, still comfortably below "bright".
    static let surface = Color(red: 1, green: 0.98, blue: 0.96).opacity(0.07)
    static let surfaceHi = Color(red: 1, green: 0.98, blue: 0.96).opacity(0.115)
    static let text = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let textDim = Color(red: 0.97, green: 0.96, blue: 0.93).opacity(0.64)
    static let textFaint = Color(red: 0.97, green: 0.96, blue: 0.93).opacity(0.42)
    static let hairline = Color(red: 1, green: 0.98, blue: 0.96).opacity(0.13)

    /// Panel fill: pure-ish black at the very top so it fuses with the physical
    /// notch, warming into `ink` as it drops down.
    static let panel = LinearGradient(
        colors: [inkTop, ink], startPoint: .top, endPoint: .bottom)
}

/// Card elevation for a near-black panel.
///
/// A flat 5.5%-white fill on this background is almost invisible, so cards read
/// as floating rather than sitting on a surface. The convention that works in
/// dark UI is to imply a light source above: a slightly brighter fill plus a
/// one-pixel highlight along the top edge that fades out by the bottom.
struct Elevated: ViewModifier {
    var radius: CGFloat = 12
    var strength: Double = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(Color(red: 1, green: 0.98, blue: 0.96)
                .opacity(0.075 * strength)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14 * strength),
                                 Color.white.opacity(0.02 * strength)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
    }
}

extension View {
    func elevated(radius: CGFloat = 12, strength: Double = 1) -> some View {
        modifier(Elevated(radius: radius, strength: strength))
    }
}

/// The Sentry Notch mark: a shield whose upper edge is cut by a notch, with a
/// watching slit at its centre. Original geometry — deliberately nothing like
/// a radiating spark, so it can't be confused with any vendor's logo.
struct Mark: View {
    var color: Color = CC.coral

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ShieldNotch().fill(color)
                // The sentry's eye. Proportionally chunky, because at the 15pt
                // size used in the toolbar a delicate slit disappears entirely
                // and the mark degrades into an orange smudge. Below ~13pt it
                // is dropped rather than rendered as mud.
                if s >= 13 {
                    Capsule().fill(CC.inkTop)
                        .frame(width: max(2, s * 0.17), height: max(4, s * 0.34))
                        .offset(y: s * 0.06)
                }
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// Shield outline with a rectangular bite taken out of the top edge — the
/// notch the product lives in.
struct ShieldNotch: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.06, y: h * 0.10))
        p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.10))
        p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.24))   // down into the notch
        p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.24))
        p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.10))   // and back up
        p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.10))
        p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.55))
        // Shoulders sweep into a point at the bottom centre.
        p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.97),
                       control: CGPoint(x: w * 0.92, y: h * 0.86))
        p.addQuadCurve(to: CGPoint(x: w * 0.06, y: h * 0.55),
                       control: CGPoint(x: w * 0.08, y: h * 0.86))
        p.closeSubpath()
        return p
    }
}

/// The Sentry Notch mascot: a perched owl sentinel. Original artwork — an
/// upright 12×12 body with ear tufts, a hooked beak, folded wings, and talons
/// gripping the wedge, deliberately unlike any vendor's character.
///
/// It reacts to the session it stands for via `mood`:
///   • idle     — nothing running: head sweeps left/right, occasional blink
///   • walking  — a session is working: steps on the perch and bobs
///   • alert    — a prompt is waiting: wings flared, eager hops
///   • alarmed  — a high-risk / out-of-scope prompt: wings out, frantic shake
struct Sentinel: View {
    var size: CGFloat = 20
    var color: Color = CC.coral
    var mood: Mood = .idle

    /// What the owl is acting out. Most map to what the agent is actually
    /// doing, read from the session's current tool — the sprite mimes the work
    /// rather than just signalling "busy".
    ///
    /// Every mood must differ in *silhouette*, not detail. At the 17pt size
    /// these render on the notch wedge, a changed pixel is invisible; a changed
    /// outline reads instantly.
    enum Mood {
        case idle          // nothing running
        case dozing        // idle a long while — eyes shut, barely breathing
        case walking       // shell work: Bash
        case reading       // Read / Grep / Glob — head down, scanning
        case typing        // Edit / Write — wings tapping alternately
        case transmitting  // WebFetch / WebSearch — wings raised, pulsing
        case thinking      // working, no tool named yet
        case alert         // a prompt is waiting
        case alarmed       // high-risk or out-of-scope prompt
        case celebrating   // session just finished
    }

    /// Where the owl is looking. Doubles as the blink state — a sentry that
    /// scans reads as "on watch" without needing any other motion.
    enum Gaze { case ahead, left, right, blink, shut, down }

    static let cols = 12

    /// Rows 0–1 ear tufts, 2–3 crown, 4–5 eyes, 6 beak, 7–9 body, 10 taper,
    /// 11 talons. Every row is exactly `cols` characters.
    static func head(_ gaze: Gaze) -> [String] {
        let tufts = [".XX......XX.", ".XXX....XXX."]
        let crown = ["..XXXXXXXX..", ".XXXXXXXXXX."]
        let eyes: [String]
        switch gaze {
        case .ahead: eyes = ["XX..XXXX..XX", "XX..XXXX..XX"]
        case .left:  eyes = ["X..XXXXX..XX", "X..XXXXX..XX"]   // pupils shifted left
        case .right: eyes = ["XX..XXXXX..X", "XX..XXXXX..X"]
        case .blink: eyes = [".XXXXXXXXXX.", "XX..XXXX..XX"]   // upper lid down
        case .shut:  eyes = [".XXXXXXXXXX.", ".XXXXXXXXXX."]   // fully closed
        case .down:  eyes = ["XX..XXXX..XX", ".XXXXXXXXXX."]   // lower lid up
        }
        return tufts + crown + eyes + ["XXXXX..XXXXX"]         // beak notch
    }

    /// Wing position. Each option changes the outline, which is the only thing
    /// legible at wedge size.
    enum Wings { case folded, flared, raised, left, right }

    static func body(_ wings: Wings) -> [String] {
        let hug = ".XXXXXXXXXX."
        switch wings {
        case .folded: return [hug, hug, hug]
        case .flared: return ["XXXXXXXXXXXX", "XXXXXXXXXXXX", hug]
        case .raised: return ["XXXXXXXXXXXX", hug, hug]           // lifted, like a signal
        case .left:   return ["XXXXXXXXXXX.", hug, hug]           // one wing out
        case .right:  return [".XXXXXXXXXXX", hug, hug]
        }
    }

    /// Talons at cols 2,4 and 7,9. `step` lifts one foot for the walk cycle.
    static func talons(step: Int) -> [String] {
        let taper = "..XXXXXXXX.."
        switch step {
        case  1: return [taper, "..X....X.X.."]   // left foot lifted
        case -1: return [taper, "..X.X..X...."]   // right foot lifted
        default: return [taper, "..X.X..X.X.."]
        }
    }

    /// Map the session's current tool to what the owl acts out. The app
    /// already knows this — miming the actual work is more informative than a
    /// generic "busy", and costs nothing extra to render.
    static func mood(forTool tool: String?) -> Mood {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "NotebookRead": return .reading
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .typing
        case "WebFetch", "WebSearch":                      return .transmitting
        case "Bash":                                       return .walking
        case .some:                                        return .thinking   // MCP / unknown
        case nil:                                          return .thinking
        }
    }

    @Environment(\.animationsEnabled) private var animationsEnabled

    /// 8fps for the active moods. Pixel animation reads as smooth from about
    /// 8fps up, and the previous 11fps cost ~35% more rebuilds for no visible
    /// gain. Idle breathing halved again — nothing about it needs to be fluid.
    private var tick: TimeInterval {
        switch mood {
        case .dozing: return 1.2          // barely moving; no reason to redraw often
        case .idle:   return 0.5
        default:      return 0.125        // 8fps — enough for pixel animation
        }
    }

    var body: some View {
        if animationsEnabled {
            TimelineView(.periodic(from: .now, by: tick)) { tl in
                frame(at: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            // A representative pose, not a blank: the notch still has to read
            // as "a session is working" while the panel is hidden or the screen
            // is asleep, it just doesn't need to move.
            frame(at: 0)
        }
    }

    @ViewBuilder private func frame(at t: TimeInterval) -> some View {
        switch mood {

        case .idle:
            // A slow 6s sweep: ahead, left, ahead, right, with a blink folded
            // in. A sentry that scans reads as "on watch" without any other cue.
            let phase = t.truncatingRemainder(dividingBy: 6)
            let gaze: Gaze = phase < 0.16 ? .blink
                : phase < 1.6 ? .ahead : phase < 3 ? .left
                : phase < 4.4 ? .ahead : .right
            sprite(gaze: gaze, wings: .folded, step: 0,
                   dx: 0, dy: CGFloat(sin(t * 1.2)) * (size * 0.015))

        case .dozing:
            // Long idle. Eyes shut, one slow rise and fall, and every so often
            // a deeper sink — asleep, not switched off.
            let breath = sin(t * 0.55)
            let sink = t.truncatingRemainder(dividingBy: 11) < 1.4 ? size * 0.05 : 0
            sprite(gaze: .shut, wings: .folded, step: 0,
                   dx: 0, dy: CGFloat(breath) * (size * 0.02) + sink)

        case .walking:
            let stride = t.truncatingRemainder(dividingBy: 0.8)
            let step = stride < 0.2 ? 1 : stride < 0.4 ? 0 : stride < 0.6 ? -1 : 0
            sprite(gaze: t.truncatingRemainder(dividingBy: 3.1) < 0.14 ? .blink : .ahead,
                   wings: .folded, step: step,
                   dx: 0, dy: CGFloat(sin(t * 7.85)) * (size * 0.045))

        case .reading:
            // Head down over the page, tracking left to right and dipping to
            // the next line — the shape of scanning, not of typing.
            let line = t.truncatingRemainder(dividingBy: 2.4)
            let gaze: Gaze = line < 0.8 ? .left : line < 1.6 ? .right : .down
            sprite(gaze: gaze, wings: .folded, step: 0,
                   dx: CGFloat(sin(t * 1.6)) * (size * 0.02),
                   dy: size * 0.03 + CGFloat(sin(t * 2.2)) * (size * 0.012))

        case .typing:
            // Wings alternate like hands on a keyboard. The asymmetry is what
            // makes it read as work rather than agitation.
            let beat = Int(t * 7) % 2
            sprite(gaze: .down, wings: beat == 0 ? .left : .right, step: 0,
                   dx: 0, dy: CGFloat(sin(t * 14)) * (size * 0.018))

        case .transmitting:
            // Wings up and pulsing — sending something outward.
            let up = t.truncatingRemainder(dividingBy: 0.7) < 0.35
            sprite(gaze: .ahead, wings: up ? .raised : .folded, step: 0,
                   dx: 0, dy: up ? -(size * 0.03) : 0)

        case .thinking:
            // Working with no tool named yet: a slow head tilt and a long blink.
            let phase = t.truncatingRemainder(dividingBy: 3.4)
            let gaze: Gaze = phase < 0.3 ? .blink : phase < 1.7 ? .left : .right
            sprite(gaze: gaze, wings: .folded, step: 0,
                   dx: CGFloat(sin(t * 0.9)) * (size * 0.025),
                   dy: CGFloat(sin(t * 1.8)) * (size * 0.015))

        case .alert:
            sprite(gaze: .ahead,
                   wings: t.truncatingRemainder(dividingBy: 0.3) < 0.15 ? .flared : .folded,
                   step: 0, dx: 0, dy: -abs(CGFloat(sin(t * 9))) * (size * 0.09))

        case .alarmed:
            sprite(gaze: .ahead,
                   wings: t.truncatingRemainder(dividingBy: 0.2) < 0.1 ? .flared : .folded,
                   step: 0, dx: CGFloat(sin(t * 26)) * (size * 0.055), dy: 0)

        case .celebrating:
            // Two quick hops with wings up. Transient — the model drops back to
            // idle a moment later.
            let hop = abs(sin(t * 6))
            sprite(gaze: .ahead, wings: hop > 0.55 ? .raised : .folded, step: 0,
                   dx: 0, dy: -CGFloat(hop) * (size * 0.13))
        }
    }

    /// Every frame the sprite can produce, for validation. A row of the wrong
    /// length draws outside the canvas and is silently clipped, so it can't be
    /// caught by looking at it — only by measuring.
    static func allFrames() -> [[String]] {
        var out: [[String]] = []
        for gaze in [Gaze.ahead, .left, .right, .blink, .shut, .down] {
            for wings in [Wings.folded, .flared, .raised, .left, .right] {
                for step in [-1, 0, 1] {
                    out.append(head(gaze) + body(wings) + talons(step: step))
                }
            }
        }
        return out
    }

    /// The bob, hop, and shake are applied *inside* the canvas rather than with
    /// `.offset()`.
    ///
    /// A modifier that changes geometry invalidates the layout of everything
    /// above it, so animating by offset made SwiftUI re-run a full layout pass
    /// eight times a second — sampling showed essentially all of the app's idle
    /// CPU inside `LayoutEngineBox.sizeThatFits` and `StackLayout.placeChildren`.
    /// Translating the drawing keeps the view's geometry constant, so only the
    /// canvas contents are redrawn and the layout engine has nothing to do.
    ///
    /// The frame is padded by the maximum excursion so a moving sprite is never
    /// clipped by its own bounds.
    private func sprite(gaze: Gaze, wings: Wings, step: Int, dx: CGFloat, dy: CGFloat) -> some View {
        let rows = Self.head(gaze) + Self.body(wings) + Self.talons(step: step)
        let px = size / CGFloat(Self.cols)
        let pad = size * 0.12
        return Canvas { ctx, _ in
            // Only the animation offset translates; the pixel grid itself is
            // snapped to whole points below. Filling fractional rects smeared
            // every block edge across a sub-pixel boundary, which read as a
            // muddy blur at these small sizes.
            ctx.translateBy(x: dx, y: dy)
            func snap(_ v: CGFloat) -> CGFloat { v.rounded() }
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "X" {
                    // Snap each cell's edges to whole points. Neighbouring cells
                    // share the same snapped edge, so blocks meet cleanly with
                    // no seams and no anti-aliased fuzz.
                    let x0 = snap(pad + CGFloat(x) * px), y0 = snap(pad + CGFloat(y) * px)
                    let x1 = snap(pad + CGFloat(x + 1) * px), y1 = snap(pad + CGFloat(y + 1) * px)
                    ctx.fill(Path(CGRect(x: x0, y: y0,
                                         width: max(1, x1 - x0), height: max(1, y1 - y0))),
                             with: .color(color))
                }
            }
        }
        .frame(width: size + pad * 2, height: px * CGFloat(rows.count) + pad * 2)
    }
}

/// Small spinning arc for "working" states.
struct Spinner: View {
    var size: CGFloat = 10
    var color: Color = CC.coral

    @Environment(\.animationsEnabled) private var animationsEnabled

    var body: some View {
        // Was 0.05s — 20fps for an 8pt arc, which is indistinguishable from
        // 10fps at that size and was the single largest source of idle CPU.
        if animationsEnabled {
            TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                let a = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                arc.rotationEffect(.degrees(a * 360))
            }
        } else {
            arc
        }
    }

    private var arc: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: max(1, size * 0.14), lineCap: .round))
            .frame(width: size, height: size)
    }
}

/// Stable per-project accent so sessions read as distinct at a glance.
func projectTint(_ name: String) -> Color {
    var h: UInt64 = 5381
    for b in name.utf8 { h = (h &* 33) &+ UInt64(b) }
    return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.85)
}

/// Lightweight shell syntax highlighting for command previews.
func highlightShell(_ s: String) -> AttributedString {
    var attr = AttributedString(s)
    attr.foregroundColor = CC.text
    func paint(_ pattern: String, _ color: Color) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s),
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
            attr[lo..<hi].foregroundColor = color
        }
    }
    paint(#"^\s*[\w./-]+"#, CC.coral)                              // leading command
    paint(#"[|&;><]"#, Color(red: 0.85, green: 0.6, blue: 0.4))    // operators
    paint(#"\s-{1,2}[A-Za-z][\w-]*"#, Color(red: 0.55, green: 0.78, blue: 0.85))  // flags
    paint(#"'[^']*'|"[^"]*""#, Color(red: 0.6, green: 0.82, blue: 0.55))          // strings
    return attr
}

/// A switch drawn from scratch, for state that must stay readable at a glance.
///
/// AppKit desaturates a stock `Toggle`'s tint whenever its window isn't key,
/// and the island is a nonactivating panel — so it is non-key most of the time.
/// That made the intercept switch render grey while interception was actually
/// armed: the one control whose colour is a safety signal was the one control
/// that kept dropping it. Drawing it here means the colour tracks the state and
/// nothing else.
struct SwitchToggle: View {
    @Binding var isOn: Bool
    var tint: Color
    @Environment(\.animationsEnabled) private var animate

    var body: some View {
        Capsule()
            .fill(isOn ? tint : Color.white.opacity(0.14))
            .frame(width: 30, height: 17)
            .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.18 : 0.10), lineWidth: 1))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .padding(.horizontal, 2)
            }
            .shadow(color: isOn ? tint.opacity(0.5) : .clear, radius: 6)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .animation(animate ? .spring(response: 0.28, dampingFraction: 0.7) : nil, value: isOn)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "on" : "off")
    }
}
