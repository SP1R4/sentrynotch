import SwiftUI
import SentryNotchCore

/// Session replay — scrub through what an agent did in a project, in order, and
/// jump to the high-risk moments. Reconstructed from the audit log.
struct ReplayView: View {
    @ObservedObject var model: AppModel
    @State private var entries: [ActivityEntry] = []
    @State private var project = ""
    @State private var pos: Double = 0
    @State private var loaded = false

    private var projects: [String] { timelineProjects(entries) }
    private var line: [ActivityEntry] { timeline(for: project, in: entries) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !loaded {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(CC.textDim)
            } else if line.isEmpty {
                Text("No recorded activity to replay yet.").font(.system(size: 12)).foregroundStyle(CC.textDim)
            } else {
                summary
                scrubber
                timelineList
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            cap("REPLAY")
            Spacer()
            if !projects.isEmpty {
                Menu {
                    ForEach(projects, id: \.self) { p in
                        Button(p) { project = p; pos = 0 }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(project.isEmpty ? "Pick a project" : project)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.text)
                        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(CC.textDim)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(CC.surfaceHi))
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private var summary: some View {
        let s = summarizeTimeline(line)
        return HStack(spacing: 8) {
            stat("\(s.total)", "calls")
            stat("\(s.denied)", "denied", .red)
            stat("\(s.highRisk)", "high risk", .orange)
            stat("\(String(s.firstTS.suffix(from: s.firstTS.startIndex).prefix(10)))", "from")
        }
    }

    private var scrubber: some View {
        let count = line.count
        let idx = min(Int(pos), count - 1)
        let upto = Array(line.prefix(idx + 1))
        let s = summarizeTimeline(upto)
        return VStack(alignment: .leading, spacing: 4) {
            Slider(value: $pos, in: 0...Double(max(1, count - 1)))
                .tint(model.settings.accentColor)
            HStack {
                Text("at call \(idx + 1) of \(count) · \(shortTime(line[idx].ts))")
                Spacer()
                Text("so far: \(s.denied) denied · \(s.highRisk) high-risk")
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(CC.textFaint)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private var timelineList: some View {
        let idx = min(Int(pos), line.count - 1)
        return VStack(spacing: 0) {
            ForEach(Array(line.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 8) {
                    Circle().fill(riskColor(e.risk)).frame(width: 7, height: 7)
                    Text(shortTime(e.ts)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CC.textFaint).frame(width: 42, alignment: .leading)
                    Text(e.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(CC.text)
                        .frame(width: 62, alignment: .leading)
                    Text(e.summary).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CC.textDim).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    decisionBadge(e.decision)
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(i == idx ? model.settings.accentColor.opacity(0.16) : Color.clear))
            }
        }
    }

    // MARK: - Pieces

    private func stat(_ v: String, _ label: String, _ tint: Color = CC.text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(tint).lineLimit(1)
            Text(label).font(.system(size: 9)).foregroundStyle(CC.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(CC.surface))
    }

    private func decisionBadge(_ d: String) -> some View {
        let allow = d.hasPrefix("allow")
        let deny = d.hasPrefix("deny")
        let (text, color): (String, Color) = allow ? ("allow", Color(red: 0.35, green: 0.72, blue: 0.5))
            : deny ? ("deny", .red) : ("defer", CC.textDim)
        return Text(d.hasSuffix("*") ? "\(text)·auto" : text)
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
    }

    private func riskColor(_ r: String) -> Color {
        isHighRisk(r) ? .red : (isFlaggedRisk(r) ? .orange : Color(red: 0.35, green: 0.72, blue: 0.5))
    }

    private func shortTime(_ ts: String) -> String {
        // ISO8601 "…T16:07:00Z" → "16:07"
        guard let t = ts.split(separator: "T").last else { return "" }
        return String(t.prefix(5))
    }

    private func cap(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).tracking(0.4).foregroundStyle(CC.textDim)
    }

    private func load() async {
        let e = await model.activityLogAsync(limit: 5000)
        entries = e
        if project.isEmpty { project = timelineProjects(e).first ?? "" }
        loaded = true
    }
}
