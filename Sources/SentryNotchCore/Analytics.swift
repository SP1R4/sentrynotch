import Foundation

/// One decision as the analytics layer sees it. Deliberately decoupled from the
/// on-disk audit format so the summariser stays pure and testable.
public struct DecisionRow: Sendable, Equatable {
    public let decision: String   // "allow" | "deny" | "timeout", "*" suffix = automatic
    public let tool: String
    public let project: String
    public let risk: String
    public let day: String        // yyyy-MM-dd, caller-supplied so this stays clock-free
    /// `ruleKey` for the call, so repeated asks group exactly rather than by
    /// tool name alone. Empty for rows written before it was recorded.
    public let key: String

    public init(decision: String, tool: String, project: String, risk: String,
                day: String, key: String = "") {
        self.decision = decision
        self.tool = tool
        self.project = project
        self.risk = risk
        self.day = day
        self.key = key
    }

    public var isAuto: Bool { decision.hasSuffix("*") }
    public var outcome: String { decision.hasSuffix("*") ? String(decision.dropLast()) : decision }
}

public struct Tally: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int
    public var id: String { name }
    public init(name: String, count: Int) { self.name = name; self.count = count }
}

/// Aggregate view of the decision log — what got asked, what you said, and how
/// much of it you never had to look at.
public struct AnalyticsSummary: Sendable, Equatable {
    public var total = 0
    public var allowed = 0
    public var denied = 0
    public var deferred = 0
    public var automatic = 0
    public var risky = 0
    public var byTool: [Tally] = []
    public var byProject: [Tally] = []
    public var byDay: [Tally] = []

    public init() {}

    /// Share of decisions the broker handled without interrupting you.
    public var autoRate: Double { total == 0 ? 0 : Double(automatic) / Double(total) }
    /// Share of the prompts you *did* see that you turned down.
    public var denyRate: Double {
        let manual = total - automatic
        return manual == 0 ? 0 : Double(denied) / Double(manual)
    }
}

public func summarize(_ rows: [DecisionRow], topN: Int = 6) -> AnalyticsSummary {
    var s = AnalyticsSummary()
    var tools: [String: Int] = [:], projects: [String: Int] = [:], days: [String: Int] = [:]

    for r in rows {
        s.total += 1
        if r.isAuto { s.automatic += 1 }
        switch r.outcome {
        case "allow": s.allowed += 1
        case "deny":  s.denied += 1
        default:      s.deferred += 1
        }
        if isHighRisk(r.risk) { s.risky += 1 }
        if !r.tool.isEmpty { tools[r.tool, default: 0] += 1 }
        if !r.project.isEmpty { projects[r.project, default: 0] += 1 }
        if !r.day.isEmpty { days[r.day, default: 0] += 1 }
    }

    // Ties break by name so the UI doesn't reshuffle between refreshes.
    func rank(_ d: [String: Int], limit: Int?) -> [Tally] {
        let sorted = d.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { Tally(name: $0.key, count: $0.value) }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }
    s.byTool = rank(tools, limit: topN)
    s.byProject = rank(projects, limit: topN)
    s.byDay = days.sorted { $0.key < $1.key }.map { Tally(name: $0.key, count: $0.value) }
    return s
}
