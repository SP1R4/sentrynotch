import Foundation

/// Map an audit-log risk label back to a level, so history can be replayed
/// against a policy's `minRisk` condition.
public func riskLevelFromLabel(_ s: String) -> RiskLevel {
    switch s {
    case RiskLevel.high.label, "high", "critical": return .high
    case RiskLevel.medium.label:                    return .medium
    case RiskLevel.low.label:                       return .low
    default:                                        return .none
    }
}

/// One historical call, reduced to what a policy can be evaluated against.
/// `actualOutcome` is what really happened (`allow`/`deny`), so a replay can
/// report what a draft policy *would have changed*.
public struct ReplayRow: Sendable, Equatable {
    public let tool: String
    public let command: String?
    public let paths: [String]
    public let risk: RiskLevel
    public let actualOutcome: String

    public init(tool: String, command: String?, paths: [String], risk: RiskLevel, actualOutcome: String) {
        self.tool = tool
        self.command = command
        self.paths = paths
        self.risk = risk
        self.actualOutcome = actualOutcome
    }
}

/// The outcome of replaying a policy over history.
///
/// Honest limitation: the audit log doesn't retain the hosts a call referenced,
/// so `scope` and `hostGlob` conditions can't be replayed — those rows simply
/// won't match here even if they would live. Tool, risk, command, and path
/// conditions replay faithfully.
public struct PolicyReplay: Sendable, Equatable {
    public let evaluated: Int      // rows some rule matched
    public let wouldDeny: Int
    public let wouldAllow: Int
    public let wouldPrompt: Int
    public let newlyCaught: Int    // previously allowed, now denied — the win
    public let newlyAllowed: Int   // previously denied, now allowed — a regression to check
}

/// Evaluate `rules` against historical rows without touching anything live.
public func replayPolicy(rows: [ReplayRow], rules: [PolicyRule]) -> PolicyReplay {
    var deny = 0, allow = 0, prompt = 0, caught = 0, newlyAllowed = 0, evaluated = 0
    for r in rows {
        let ctx = PolicyContext(tool: r.tool, paths: r.paths, command: r.command,
                                risk: r.risk, hosts: [], outOfScopeHosts: [])
        guard let outcome = evaluatePolicy(ctx, rules: rules) else { continue }
        evaluated += 1
        switch outcome.effect {
        case .deny:
            deny += 1
            if r.actualOutcome == "allow" { caught += 1 }
        case .allow:
            allow += 1
            if r.actualOutcome == "deny" { newlyAllowed += 1 }
        case .prompt:
            prompt += 1
        }
    }
    return PolicyReplay(evaluated: evaluated, wouldDeny: deny, wouldAllow: allow,
                        wouldPrompt: prompt, newlyCaught: caught, newlyAllowed: newlyAllowed)
}
