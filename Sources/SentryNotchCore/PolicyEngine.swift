import Foundation

/// Declarative allow/deny/prompt policy for tool calls.
///
/// This is the layer above the per-project auto-allow tiers (`autoDecision`):
/// an ordered list of rules, each a set of AND-ed conditions and an effect.
/// First enabled rule that matches wins; if nothing matches the caller falls
/// back to its existing tier logic. Pure and unit-tested — no I/O, no clock, so
/// a decision is fully reproducible from its inputs.

/// What a matching rule does to a tool call.
public enum PolicyEffect: String, Codable, Sendable, CaseIterable, Identifiable {
    case allow    // auto-approve without a prompt
    case deny     // auto-deny — fail closed, the agent's request is refused
    case prompt   // force a prompt, overriding any auto-allow tier

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .allow:  return "Allow"
        case .deny:   return "Deny"
        case .prompt: return "Ask"
        }
    }
}

/// Whether a rule cares about scope, and which side.
public enum ScopeMatch: String, Codable, Sendable, CaseIterable, Identifiable {
    case inScope, outOfScope
    public var id: String { rawValue }
    public var label: String { self == .inScope ? "In scope" : "Out of scope" }
}

/// The facts about one tool call a policy is evaluated against. Built by the
/// caller from the same analysis the permission card already runs, so a rule
/// sees exactly what the operator sees.
public struct PolicyContext: Sendable {
    public let tool: String
    public let paths: [String]            // affected filesystem paths
    public let command: String?           // Bash command, if any
    public let risk: RiskLevel
    public let hosts: [String]            // every host referenced by the call
    public let outOfScopeHosts: [String]  // the subset not covered by scope

    public init(tool: String, paths: [String] = [], command: String? = nil,
                risk: RiskLevel = .none, hosts: [String] = [],
                outOfScopeHosts: [String] = []) {
        self.tool = tool
        self.paths = paths
        self.command = command
        self.risk = risk
        self.hosts = hosts
        self.outOfScopeHosts = outOfScopeHosts
    }

    public var isOutOfScope: Bool { !outOfScopeHosts.isEmpty }
}

// RiskLevel is an Int-raw enum elsewhere; make it Codable so a rule's minimum
// risk threshold round-trips through settings.json.
extension RiskLevel: Codable {}

/// One declarative rule. Every non-nil condition must hold (AND); a nil
/// condition means "don't care". A rule with no conditions matches everything —
/// a deliberate catch-all (e.g. a final default-deny).
public struct PolicyRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var effect: PolicyEffect
    public var enabled: Bool

    // Conditions.
    public var tools: [String]?       // tool name is one of these
    public var pathGlob: String?      // a glob any affected path must match
    public var commandRegex: String?  // regex the Bash command must contain
    public var minRisk: RiskLevel?    // risk is at least this
    public var scope: ScopeMatch?     // in / out of scope
    public var hostGlob: String?      // a glob any referenced host matches

    public init(id: UUID = UUID(), name: String, effect: PolicyEffect,
                enabled: Bool = true, tools: [String]? = nil, pathGlob: String? = nil,
                commandRegex: String? = nil, minRisk: RiskLevel? = nil,
                scope: ScopeMatch? = nil, hostGlob: String? = nil) {
        self.id = id
        self.name = name
        self.effect = effect
        self.enabled = enabled
        self.tools = tools
        self.pathGlob = pathGlob
        self.commandRegex = commandRegex
        self.minRisk = minRisk
        self.scope = scope
        self.hostGlob = hostGlob
    }

    /// A rule that specifies not a single condition. It would match — and so
    /// short-circuit — every call, which is almost always an editing mistake
    /// rather than an intended catch-all, so the UI can warn on it.
    public var isUnconditional: Bool {
        tools == nil && pathGlob == nil && commandRegex == nil
            && minRisk == nil && scope == nil && hostGlob == nil
    }

    /// A malformed `commandRegex`/glob makes a rule impossible to satisfy; the
    /// UI surfaces this so a typo fails loud instead of silently never matching.
    public var isValid: Bool {
        if let commandRegex, (try? NSRegularExpression(pattern: commandRegex)) == nil { return false }
        return true
    }

    /// Does this rule match the call? Disabled rules never match.
    public func matches(_ ctx: PolicyContext) -> Bool {
        guard enabled else { return false }
        if let tools, !tools.contains(ctx.tool) { return false }
        if let minRisk, ctx.risk < minRisk { return false }
        if let scope {
            switch scope {
            case .outOfScope: if !ctx.isOutOfScope { return false }
            case .inScope:    if ctx.isOutOfScope { return false }
            }
        }
        if let pathGlob,
           !ctx.paths.contains(where: { globMatch(pattern: pathGlob, path: $0) }) { return false }
        if let hostGlob,
           !ctx.hosts.contains(where: { globMatch(pattern: hostGlob, path: $0) }) { return false }
        if let commandRegex {
            guard let cmd = ctx.command,
                  cmd.range(of: commandRegex, options: .regularExpression) != nil else { return false }
        }
        return true
    }
}

/// The result of evaluating the policy: the effect and the rule that produced
/// it, for the audit log and the permission card.
public struct PolicyOutcome: Sendable, Equatable {
    public let effect: PolicyEffect
    public let ruleName: String
    public init(effect: PolicyEffect, ruleName: String) {
        self.effect = effect
        self.ruleName = ruleName
    }
}

/// Evaluate rules in order; the first enabled rule that matches wins. Returns
/// nil when nothing matched, so the caller falls back to its tier/auto logic.
public func evaluatePolicy(_ ctx: PolicyContext, rules: [PolicyRule]) -> PolicyOutcome? {
    for rule in rules where rule.matches(ctx) {
        return PolicyOutcome(effect: rule.effect, ruleName: rule.name)
    }
    return nil
}

// MARK: - Glob matching

/// Minimal glob → predicate, anchored (the whole string must match).
///   `*`  matches any run of characters *within* a path segment (not `/`)
///   `**` matches across segments, `/` included
///   `?`  matches a single non-`/` character
/// Everything else is literal; regex metacharacters are escaped. Case-sensitive.
public func globMatch(pattern: String, path: String) -> Bool {
    let regex = "^" + globToRegex(pattern) + "$"
    return path.range(of: regex, options: .regularExpression) != nil
}

func globToRegex(_ glob: String) -> String {
    var out = ""
    let chars = Array(glob)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        switch c {
        case "*":
            if i + 1 < chars.count && chars[i + 1] == "*" {
                out += ".*"        // ** — across segments
                i += 1
            } else {
                out += "[^/]*"     // * — within a segment
            }
        case "?":
            out += "[^/]"
        case ".", "+", "(", ")", "|", "^", "$", "{", "}", "[", "]", "\\":
            out += "\\" + String(c)   // escape regex metacharacters
        default:
            out += String(c)
        }
        i += 1
    }
    return out
}

// MARK: - Starter policy

/// A small, safe starter policy a first-time user can enable and then edit —
/// the decisions almost everyone wants, none of them destructive. Ordered
/// most-specific first so the deny rules win over the broad allow.
public func starterPolicy() -> [PolicyRule] {
    [
        PolicyRule(name: "Block writes to SSH keys", effect: .deny,
                   tools: ["Write", "Edit", "MultiEdit"], pathGlob: "**/.ssh/**"),
        PolicyRule(name: "Block writes to cloud credentials", effect: .deny,
                   tools: ["Write", "Edit", "MultiEdit"],
                   pathGlob: "**/.aws/**"),
        PolicyRule(name: "Confirm out-of-scope network calls", effect: .prompt,
                   scope: .outOfScope),
        PolicyRule(name: "Always confirm high risk", effect: .prompt, minRisk: .high),
    ]
}
