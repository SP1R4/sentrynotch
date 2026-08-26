import Foundation

/// A behavioral fingerprint of what an agent has done in a project — the tools
/// it uses and the shell commands it runs. Deviation from this baseline ("first
/// time it has ever run `nc` here") is a cheap, high-signal anomaly cue: not
/// necessarily malicious, but always worth a second look.
public struct AgentProfile: Sendable, Equatable {
    public var count: Int = 0
    public var tools: Set<String> = []
    public var commandHeads: Set<String> = []   // Bash first tokens

    public init() {}

    public init(rows: [DecisionRow]) {
        for r in rows { add(tool: r.tool, key: r.key) }
    }

    public mutating func add(tool: String, key: String) {
        count += 1
        if !tool.isEmpty { tools.insert(tool) }
        if key.hasPrefix("Bash|") {
            let head = String(key.dropFirst("Bash|".count))
            if !head.isEmpty { commandHeads.insert(head) }
        }
    }
}

/// What's novel about a call relative to the profile. Empty until there's enough
/// history to have a meaningful baseline — otherwise everything reads as "first
/// seen" and the signal is worthless. Pure and unit-tested.
public func noveltyFlags(profile: AgentProfile, tool: String, key: String,
                         minHistory: Int = 12) -> [String] {
    guard profile.count >= minHistory else { return [] }
    var out: [String] = []
    if !tool.isEmpty, !profile.tools.contains(tool) {
        out.append("first use of \(tool) in this project")
    }
    if key.hasPrefix("Bash|") {
        let head = String(key.dropFirst("Bash|".count))
        if !head.isEmpty, !profile.commandHeads.contains(head) {
            out.append("first `\(head)` command here")
        }
    }
    return out
}
