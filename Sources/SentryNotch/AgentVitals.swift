import SwiftUI
import SentryNotchCore

/// Agent vitals — a context-fill gauge, the burn rate, an ETA to the ceiling,
/// and a tempo heartbeat. Every number is derived from context sizes the app
/// already tracks (`AppModel.sampleVitals`), so the widget adds no polling.
///
/// No competing notch app shows *agent* vitals — they show the user's world
/// (music, battery). This shows the run's: is it filling context fast, and is
/// it actually working right now or stalled?
struct VitalsWidget: View {
    @ObservedObject var model: AppModel
    var accent: Color

    var body: some View {
        // One clock drives the whole widget so the ring, burn label, and ETA
        // stay in step with the per-second heartbeat instead of lagging behind
        // the model's coarser publishes.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 11) {
                gauge
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 11))
                            .foregroundStyle(accent).frame(width: 12)
                        Text("Vitals").font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(CC.text)
                        Spacer(minLength: 4)
                        Text(burnLabel).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(model.contextBurnPerMin > 0 ? accent : CC.textFaint)
                    }
                    heartbeat.frame(height: 22)
                    Text(etaLabel).font(.system(size: 9)).foregroundStyle(CC.textFaint).lineLimit(1)
                }
            }
        }
    }

    /// The ring is a speedometer, not a fuel gauge: burn *rate* relative to a
    /// redline, so it stays meaningful no matter how large the absolute context
    /// grows (a compacted session can carry more than one window's worth). The
    /// readout in the middle is the live context size — speedometer over
    /// odometer.
    private var fill: Double {
        min(1, Double(model.contextBurnPerMin) / 12_000)
    }

    // A 270° speedometer — the open bottom reads as a dial, not a progress
    // ring, so "this is a rate" is unmistakable. Odometer (ctx size) in the hub.
    private var gauge: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(CC.hairline, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * fill)
                .stroke(gaugeTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: gaugeTint.opacity(fill > 0.05 ? 0.55 : 0), radius: 3)
                .animation(.easeOut(duration: 0.5), value: fill)
            VStack(spacing: 0) {
                Text(compact(model.liveTokens))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(CC.text)
                Text("ctx").font(.system(size: 7, weight: .medium)).foregroundStyle(CC.textFaint)
            }
        }
        .frame(width: 46, height: 46)
    }

    /// The tempo line — context growth per tick. A moving trace when the agent
    /// is working, a flatline when it's idle or waiting on you.
    // An area sparkline, not a bare stroke: a gradient fill under a smooth line
    // over a faint baseline, so it reads at a glance as an activity trace —
    // moving when the agent works, flat on the baseline when it's idle.
    // Refreshed by the widget's outer TimelineView.
    private var heartbeat: some View {
        GeometryReader { geo in
            let pts = points(model.vitalsPulses, in: geo.size)
            let baseY = geo.size.height - 1
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: baseY))
                    p.addLine(to: CGPoint(x: geo.size.width, y: baseY))
                }.stroke(CC.hairline, lineWidth: 1)

                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: baseY))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: baseY))
                        p.closeSubpath()
                    }.fill(LinearGradient(colors: [trace.opacity(0.38), trace.opacity(0.02)],
                                          startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
                    }.stroke(trace, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: baseY)); p.addLine(to: CGPoint(x: geo.size.width, y: baseY))
                    }.stroke(CC.textFaint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
            }
        }
    }

    private var trace: Color { model.hasActiveSession ? accent : CC.textFaint }

    private func points(_ pulses: [Int], in size: CGSize) -> [CGPoint] {
        guard pulses.count > 1, size.width > 0 else { return [] }
        let peak = max(1, pulses.max() ?? 1)
        let step = size.width / CGFloat(pulses.count - 1)
        return pulses.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step,
                    y: (size.height - 2) * (1 - 0.9 * CGFloat(v) / CGFloat(peak)) + 1)
        }
    }

    private var burnLabel: String {
        model.contextBurnPerMin > 0 ? "+\(compact(model.contextBurnPerMin))/m" : "idle"
    }

    private var etaLabel: String {
        if let eta = model.contextETAMinutes { return "~\(eta)m to full" }
        let active = model.sessions.filter(\.isActive).count
        if active > 0 { return "\(active) active · peak \(compact(model.contextPeak))" }
        return model.sessions.isEmpty ? "no sessions" : "idle"
    }

    private var gaugeTint: Color {
        fill < 0.5 ? Color(red: 0.35, green: 0.78, blue: 0.55)
            : (fill < 0.85 ? CC.coral : CC.alarm)
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 0..<1000: return "\(n)"
        case 1000..<10_000: return String(format: "%.1fk", Double(n) / 1000)
        default: return String(format: "%.0fk", Double(n) / 1000)
        }
    }
}

/// Fleet board — every session as a status dot: green working, amber waiting on
/// you, red high-risk pending, grey idle. A server-status board for your agents,
/// so "which one needs me" is answerable at a glance when several are running.
struct FleetWidget: View {
    @ObservedObject var model: AppModel
    var accent: Color

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                    .foregroundStyle(accent).frame(width: 12)
                Text("Fleet").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(CC.text)
                Spacer(minLength: 4)
                Text(summary).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CC.textFaint).lineLimit(1)
            }
            if model.sessions.isEmpty {
                Text("no sessions").font(.system(size: 10)).foregroundStyle(CC.textFaint)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(model.sessions) { card in
                        let c = color(card)
                        HStack(spacing: 6) {
                            Circle().fill(c).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(c.opacity(0.35), lineWidth: 3)
                                    .opacity(card.isActive ? 1 : 0))
                                .shadow(color: c.opacity(card.isActive ? 0.9 : 0),
                                        radius: card.isActive ? 4 : 0)
                            Text(card.project).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CC.textDim).lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(CC.text.opacity(0.05)))
                    }
                }
            }
        }
    }

    /// "1 alert · 2 waiting · 3 working", worst state first; the whole point of a
    /// board is "who needs me" without counting dots.
    private var summary: String {
        var alert = 0, waiting = 0, working = 0, idle = 0
        for card in model.sessions {
            let mine = model.pending.filter { $0.sessionID == card.id }
            if mine.contains(where: { $0.risk.level >= .high }) { alert += 1 }
            else if !mine.isEmpty { waiting += 1 }
            else if card.isActive { working += 1 }
            else { idle += 1 }
        }
        var parts: [String] = []
        if alert > 0 { parts.append("\(alert) alert") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working > 0 { parts.append("\(working) working") }
        if parts.isEmpty { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }

    private func color(_ card: SessionCard) -> Color {
        let mine = model.pending.filter { $0.sessionID == card.id }
        if mine.contains(where: { $0.risk.level >= .high }) { return CC.alarm }   // needs you, dangerous
        if !mine.isEmpty { return CC.coral }                                      // waiting on you
        if card.isActive { return Color(red: 0.35, green: 0.78, blue: 0.55) }     // working
        return CC.textFaint                                                       // idle
    }
}
