import Foundation

/// A named, shareable bundle of policy rules — like a filter list. Import one to
/// adopt a whole posture at once; export yours to share it. Round-trips as JSON.
public struct PolicyPack: Codable, Sendable, Identifiable, Equatable {
    public var id: String          // stable slug
    public var name: String
    public var summary: String
    public var rules: [PolicyRule]

    public init(id: String, name: String, summary: String, rules: [PolicyRule]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.rules = rules
    }

    public func encoded() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(self)
    }
}

/// Parse an imported file: accept either a full `PolicyPack` or a bare array of
/// rules, so a hand-written list of rules imports too. Fresh UUIDs are assigned
/// so importing never collides with an existing rule's id.
public func parsePolicyImport(_ data: Data) -> [PolicyRule]? {
    let dec = JSONDecoder()
    if let pack = try? dec.decode(PolicyPack.self, from: data) {
        return pack.rules.map { reid($0) }
    }
    if let rules = try? dec.decode([PolicyRule].self, from: data) {
        return rules.map { reid($0) }
    }
    return nil
}

private func reid(_ r: PolicyRule) -> PolicyRule {
    PolicyRule(id: UUID(), name: r.name, effect: r.effect, enabled: r.enabled,
               tools: r.tools, pathGlob: r.pathGlob, commandRegex: r.commandRegex,
               minRisk: r.minRisk, scope: r.scope, hostGlob: r.hostGlob)
}

/// Curated starting points. Rules are ordered most-specific first (deny before a
/// broad allow) so first-match-wins behaves.
public func builtinPolicyPacks() -> [PolicyPack] {
    [
        PolicyPack(id: "secrets-hardened", name: "Secrets-hardened",
                   summary: "Never let an agent write to credential stores; confirm anything high-risk.",
                   rules: [
                    PolicyRule(name: "Deny writes to SSH keys", effect: .deny,
                               tools: ["Write", "Edit", "MultiEdit"], pathGlob: "**/.ssh/**"),
                    PolicyRule(name: "Deny writes to cloud credentials", effect: .deny,
                               tools: ["Write", "Edit", "MultiEdit"], pathGlob: "**/.aws/**"),
                    PolicyRule(name: "Deny writes to GnuPG", effect: .deny,
                               tools: ["Write", "Edit", "MultiEdit"], pathGlob: "**/.gnupg/**"),
                    PolicyRule(name: "Always confirm high risk", effect: .prompt, minRisk: .high),
                   ]),
        PolicyPack(id: "pentest-engagement", name: "Pentest engagement",
                   summary: "Confirm every out-of-scope call and every high-risk one; auto-allow reads in the repo.",
                   rules: [
                    PolicyRule(name: "Confirm out-of-scope calls", effect: .prompt, scope: .outOfScope),
                    PolicyRule(name: "Deny writes to SSH keys", effect: .deny,
                               tools: ["Write", "Edit", "MultiEdit"], pathGlob: "**/.ssh/**"),
                    PolicyRule(name: "Always confirm high risk", effect: .prompt, minRisk: .high),
                    PolicyRule(name: "Auto-allow reads", effect: .allow, tools: ["Read", "Grep", "Glob"]),
                   ]),
        PolicyPack(id: "prod-safe", name: "Prod-safe",
                   summary: "Confirm every mutation and block the irreversible classics.",
                   rules: [
                    PolicyRule(name: "Confirm out-of-scope calls", effect: .prompt, scope: .outOfScope),
                    PolicyRule(name: "Confirm all writes", effect: .prompt, tools: ["Write", "Edit", "MultiEdit"]),
                    PolicyRule(name: "Confirm shell at medium+ risk", effect: .prompt, tools: ["Bash"], minRisk: .medium),
                   ]),
    ]
}
