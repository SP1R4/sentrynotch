import Foundation

/// Renders the decision log as an engagement report.
///
/// This is the artefact that makes the audit trail worth keeping: at the end of
/// a job you need to be able to show what an autonomous agent proposed, what
/// you permitted, and — critically — whether anything reached outside the
/// agreed scope. Markdown so it drops straight into a report or a ticket.
public struct EngagementReport: Sendable {
    public let title: String
    public let from: String     // yyyy-MM-dd inclusive
    public let to: String       // yyyy-MM-dd inclusive
    public let rows: [DecisionRow]

    public init(title: String, from: String, to: String, rows: [DecisionRow]) {
        self.title = title
        self.from = from
        self.to = to
        // Inclusive on both ends; ISO day strings compare correctly as text.
        self.rows = rows.filter { !$0.day.isEmpty && $0.day >= from && $0.day <= to }
    }

    public var summary: AnalyticsSummary { summarize(rows, topN: 100) }

    public func markdown(generated: String) -> String {
        let s = summary
        var out = """
        # \(title)

        **Period:** \(from) to \(to)
        **Generated:** \(generated)
        **Tool:** Sentry Notch decision log

        ## Summary

        | Metric | Value |
        |---|---|
        | Tool calls recorded | \(s.total) |
        | Allowed | \(s.allowed) |
        | Denied | \(s.denied) |
        | Deferred to Claude Code | \(s.deferred) |
        | Handled automatically | \(s.automatic) (\(pct(s.autoRate))) |
        | Flagged high risk | \(s.risky) |

        """

        if s.total == 0 {
            out += "\nNo decisions were recorded in this period.\n"
            return out
        }

        out += "\n## Denied calls\n\n"
        let denied = rows.filter { $0.outcome == "deny" }
        if denied.isEmpty {
            out += "No calls were denied in this period.\n"
        } else {
            out += "| Day | Tool | Project | Risk |\n|---|---|---|---|\n"
            for r in denied.sorted(by: { $0.day < $1.day }) {
                out += "| \(r.day) | \(r.tool) | \(r.project) | \(r.risk) |\n"
            }
        }

        out += "\n## High-risk calls\n\n"
        let risky = rows.filter { isHighRisk($0.risk) }
        if risky.isEmpty {
            out += "No calls were flagged high risk in this period.\n"
        } else {
            out += "| Day | Tool | Project | Decision |\n|---|---|---|---|\n"
            for r in risky.sorted(by: { $0.day < $1.day }) {
                out += "| \(r.day) | \(r.tool) | \(r.project) | \(r.decision) |\n"
            }
        }

        out += "\n## Activity by tool\n\n| Tool | Calls |\n|---|---|\n"
        for t in s.byTool { out += "| \(t.name) | \(t.count) |\n" }

        out += "\n## Activity by project\n\n| Project | Calls |\n|---|---|\n"
        for p in s.byProject { out += "| \(p.name) | \(p.count) |\n" }

        out += "\n## Daily volume\n\n| Day | Calls |\n|---|---|\n"
        for d in s.byDay { out += "| \(d.name) | \(d.count) |\n" }

        out += """

        ---

        *Sentry Notch is a review aid, not a security control. Its risk and
        scope flags are heuristics, and it fails open when not running: calls
        made while it was closed do not appear here. This report covers only
        what the broker observed.*

        """
        return out
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
