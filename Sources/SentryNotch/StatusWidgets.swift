import SwiftUI
import SentryNotchCore

/// Rate-limit headroom.
///
/// The numbers already existed — token counts come from the transcripts and the
/// 5h/7d reset windows from `UsageProbe` — but they only appeared in the
/// Analytics tab. The question they answer ("can I keep three agents running,
/// or am I about to hit the wall?") is one you want to glance at, not open a
/// window for.
struct HeadroomWidget: View {
    @ObservedObject var model: AppModel
    var accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.needle").font(.system(size: 11))
                .foregroundStyle(accent).frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tokenLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(CC.text)
                    Text("context")
                        .font(.system(size: 10)).foregroundStyle(CC.textFaint)
                    Spacer(minLength: 4)
                    if model.usageLoading {
                        Spinner(size: 10)
                    } else {
                        Button {
                            model.refreshUsage()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(CC.textDim)
                        }
                        .buttonStyle(.plain)
                        .help("Read the real 5h/7d reset — makes one cheap Claude call")
                    }
                }

                if model.usageWindows.isEmpty {
                    Text("resets unknown — refresh to read them")
                        .font(.system(size: 9)).foregroundStyle(CC.textFaint).lineLimit(1)
                } else {
                    // Re-render on a timer so the countdown stays honest without
                    // the model having to publish every second.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        HStack(spacing: 10) {
                            ForEach(model.usageWindows) { w in
                                window(w)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func window(_ w: UsageWindow) -> some View {
        let left = w.resetsAt.timeIntervalSinceNow
        return HStack(spacing: 4) {
            Text(w.kind).font(.system(size: 9, weight: .bold))
                .foregroundStyle(CC.textFaint)
            Text(countdown(left))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint(for: left))
        }
        .help("\(w.kind) window resets \(w.resetsAt.formatted(date: .omitted, time: .shortened))")
    }

    /// Colour by urgency: the point of the widget is to notice the wall before
    /// you hit it, not to read a timestamp.
    private func tint(for seconds: TimeInterval) -> Color {
        if seconds <= 0 { return .green }
        if seconds < 15 * 60 { return CC.alarm }
        if seconds < 60 * 60 { return .orange }
        return CC.textDim
    }

    private func countdown(_ s: TimeInterval) -> String {
        if s <= 0 { return "reset" }
        let t = Int(s)
        if t < 3600 { return "\(t / 60)m" }
        if t < 86400 { return "\(t / 3600)h\((t % 3600) / 60)m" }
        return "\(t / 86400)d\((t % 86400) / 3600)h"
    }

    private var tokenLabel: String {
        let n = model.liveTokens
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(n / 1000)k" }
        return "\(n)"
    }
}

/// Working-tree state for each active session's project.
///
/// Catches the failure mode where an agent edits a dozen files you never
/// reviewed: the count sits next to the session while it works, rather than
/// being discovered later.
struct RepoWidget: View {
    @ObservedObject var model: AppModel
    var accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                .foregroundStyle(accent).frame(width: 12)
            if rows.isEmpty {
                Text(model.hasActiveSession
                     ? "No git repository in the active projects."
                     : "No sessions working.")
                    .font(.system(size: 10)).foregroundStyle(CC.textDim).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.project) { row in
                        repoRow(row)
                    }
                }
            }
        }
    }

    private struct Row { let project: String; let state: RepoState }

    /// Only sessions that are actually working — a stale card's repo state is
    /// noise, and the widget has room for a couple of lines at most.
    private var rows: [Row] {
        var seen = Set<String>()
        return model.sessions
            .filter(\.isActive)
            .compactMap { card -> Row? in
                guard !seen.contains(card.cwd), let s = model.repos.state(for: card.cwd) else { return nil }
                seen.insert(card.cwd)
                return Row(project: card.project, state: s)
            }
            .prefix(2)
            .map { $0 }
    }

    private func repoRow(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Text(row.project).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CC.text).lineLimit(1)
            Text(row.state.branch)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(CC.textDim).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(CC.surfaceHi))
            Spacer(minLength: 4)
            if row.state.isClean {
                Label("clean", systemImage: "checkmark")
                    .font(.system(size: 9, weight: .semibold)).labelStyle(.titleAndIcon)
                    .foregroundStyle(.green.opacity(0.85))
            } else {
                HStack(spacing: 6) {
                    if row.state.staged > 0 { count(row.state.staged, "plus.circle.fill", .green) }
                    if row.state.modified > 0 { count(row.state.modified, "pencil.circle.fill", .orange) }
                    if row.state.untracked > 0 { count(row.state.untracked, "questionmark.circle.fill", CC.textDim) }
                }
                .help("\(row.state.staged) staged · \(row.state.modified) modified · \(row.state.untracked) untracked")
            }
        }
    }

    private func count(_ n: Int, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8))
            Text("\(n)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}
