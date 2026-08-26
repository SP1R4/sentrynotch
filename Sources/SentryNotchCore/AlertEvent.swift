import Foundation

/// A high-signal event worth pinging you about when you're away from the
/// machine — a high-risk or out-of-scope prompt, or a decision on one. Posted
/// to a user-configured webhook (e.g. a Telegram admin bot). Carries both a
/// preformatted `message` for generic webhooks and structured fields for ones
/// that want to parse.
public struct AlertEvent: Codable, Sendable, Equatable {
    public let app: String
    public let event: String       // "prompt" | "decision"
    public let tool: String
    public let project: String
    public let risk: String
    public let outOfScope: [String]
    public let summary: String
    public let decision: String?   // set for "decision" events
    public let ts: String
    public let message: String     // human-readable one-liner

    public init(event: String, tool: String, project: String, risk: String,
                outOfScope: [String], summary: String, decision: String?,
                ts: String, app: String = "Sentry Notch") {
        self.app = app
        self.event = event
        self.tool = tool
        self.project = project
        self.risk = risk
        self.outOfScope = outOfScope
        self.summary = summary
        self.decision = decision
        self.ts = ts
        self.message = AlertEvent.format(event: event, tool: tool, project: project,
                                         risk: risk, outOfScope: outOfScope,
                                         summary: summary, decision: decision)
    }

    static func format(event: String, tool: String, project: String, risk: String,
                       outOfScope: [String], summary: String, decision: String?) -> String {
        var tag = risk.isEmpty ? "" : "[\(risk)] "
        if !outOfScope.isEmpty { tag = "[out-of-scope] " + tag }
        let head = decision.map { "\($0.uppercased()) " } ?? ""
        let where_ = project.isEmpty ? "" : " in \(project)"
        let oos = outOfScope.isEmpty ? "" : " → \(outOfScope.joined(separator: ", "))"
        // Summary is truncated hard: an alert leaves the machine, so it should
        // not carry a full command or file body off-box.
        let snip = summary.count > 160 ? String(summary.prefix(157)) + "…" : summary
        return "\(head)\(tag)\(tool)\(where_): \(snip)\(oos)"
    }

    public func jsonData() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
