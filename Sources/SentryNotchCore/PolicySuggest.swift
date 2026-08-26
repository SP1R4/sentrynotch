import Foundation

/// A policy rule the decision log suggests you adopt, with the evidence for it.
public struct PolicySuggestion: Sendable, Identifiable, Equatable {
    /// Stable across refreshes so the UI doesn't reshuffle — the rule key.
    public let id: String
    public let rule: PolicyRule
    public let rationale: String
    public let denied: Int
    public let total: Int
}

/// Turn a history of decisions into proposed **deny** rules: patterns you have
/// consistently refused. A pattern qualifies when it was denied at least
/// `minDenied` times and denied in at least 80% of its appearances — i.e. you
/// clearly don't want it, so it's a candidate to automate. Suggestions that a
/// current rule already names are dropped. Pure and unit-tested.
public func suggestPolicyRules(rows: [DecisionRow], existing: [PolicyRule],
                               minDenied: Int = 3) -> [PolicySuggestion] {
    var total: [String: Int] = [:], denied: [String: Int] = [:], toolOf: [String: String] = [:]
    for r in rows {
        guard !r.key.isEmpty else { continue }
        total[r.key, default: 0] += 1
        if r.outcome == "deny" { denied[r.key, default: 0] += 1 }
        if toolOf[r.key] == nil, !r.tool.isEmpty { toolOf[r.key] = r.tool }
    }

    var out: [PolicySuggestion] = []
    for (key, tot) in total {
        let d = denied[key] ?? 0
        guard d >= minDenied, Double(d) / Double(tot) >= 0.8 else { continue }
        let (rule, name) = denyRuleFromKey(key, tool: toolOf[key] ?? "")
        if existing.contains(where: { $0.name == name }) { continue }
        out.append(PolicySuggestion(id: key, rule: rule,
                                    rationale: "denied \(d) of \(tot) times", denied: d, total: tot))
    }
    // Most-refused first.
    return out.sorted { $0.denied == $1.denied ? $0.id < $1.id : $0.denied > $1.denied }
}

/// Build a deny rule from a rule key. `Bash|<head>` becomes a command-regex rule
/// on the first token; any other key is a tool-name rule.
func denyRuleFromKey(_ key: String, tool: String) -> (rule: PolicyRule, name: String) {
    if key.hasPrefix("Bash|") {
        let head = String(key.dropFirst("Bash|".count))
        let name = "Deny \(head)"
        let regex = "(^|[^A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: head) + "($|[^A-Za-z0-9_-])"
        return (PolicyRule(name: name, effect: .deny, tools: ["Bash"], commandRegex: regex), name)
    }
    let toolName = key.isEmpty ? tool : key
    let name = "Deny \(toolName)"
    return (PolicyRule(name: name, effect: .deny, tools: [toolName]), name)
}
