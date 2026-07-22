import Foundation

/// A standing rule the decision log says you'd probably want.
public struct RuleSuggestion: Sendable, Equatable, Identifiable {
    /// The `ruleKey` this would cover, e.g. `Bash|cd`.
    public let key: String
    /// How many times it was allowed, counting automatic approvals.
    public let allowed: Int
    /// How many of those you answered by hand — the ones that actually cost
    /// you attention.
    public let manual: Int
    public var id: String { key }

    public init(key: String, allowed: Int, manual: Int) {
        self.key = key
        self.allowed = allowed
        self.manual = manual
    }

    /// Human-readable head of the key: `Bash|cd` → `cd`.
    public var label: String {
        key.split(separator: "|").last.map(String.init) ?? key
    }
    public var tool: String {
        key.split(separator: "|").first.map(String.init) ?? key
    }
}

/// Find patterns worth turning into standing rules.
///
/// The product's real failure mode is prompt fatigue: a checkpoint that asks
/// questions whose answer is always yes gets switched off, and then none of the
/// safety features matter. The decision log already knows which asks are
/// reflexive — this surfaces them so they can become rules in one click.
///
/// Deliberately conservative:
///
/// - **Anything ever denied is never suggested.** One deny means the answer
///   depends on context, and a standing allow would be wrong exactly when it
///   mattered.
/// - **High-risk patterns are never suggested**, however often they were
///   allowed. `Bash|sudo` approved twenty times is still not something to
///   auto-approve forever.
/// - It requires manual answers, not just volume. Calls already auto-allowed by
///   the read-only tier cost no attention, so turning them into rules buys
///   nothing.
public func suggestRules(_ rows: [DecisionRow],
                         minManual: Int = 3,
                         existing: Set<String> = []) -> [RuleSuggestion] {
    var allowed: [String: Int] = [:]
    var manual: [String: Int] = [:]
    var vetoed: Set<String> = []

    for r in rows {
        let key = r.key.isEmpty ? r.tool : r.key
        if r.outcome == "deny" { vetoed.insert(key); continue }
        if isHighRisk(r.risk) { vetoed.insert(key); continue }
        guard r.outcome == "allow" else { continue }
        allowed[key, default: 0] += 1
        if !r.isAuto { manual[key, default: 0] += 1 }
    }

    return manual
        .filter { $0.value >= minManual }
        .filter { !vetoed.contains($0.key) && !existing.contains($0.key) }
        .map { RuleSuggestion(key: $0.key, allowed: allowed[$0.key] ?? 0, manual: $0.value) }
        .sorted { $0.manual == $1.manual ? $0.key < $1.key : $0.manual > $1.manual }
}

// MARK: - Blast radius

/// What a tool call is about to touch.
///
/// The prompt used to show only the command string, which answers "what will
/// run" but not "how much of my machine does this reach". For a call you are
/// about to approve, the second question is the one that matters.
public struct BlastRadius: Sendable, Equatable {
    public let inside: [String]      // paths within the working directory
    public let outside: [String]     // paths beyond it
    public let sensitive: [String]   // credential-ish paths, wherever they are
    /// True when the command names no paths at all — worth saying explicitly,
    /// because "nothing detected" and "nothing to detect" look identical
    /// otherwise.
    public var isEmpty: Bool { inside.isEmpty && outside.isEmpty && sensitive.isEmpty }
    public var total: Int { inside.count + outside.count + sensitive.count }
}

/// Path fragments that mean credentials or keys regardless of location.
let sensitiveMarkers = [
    ".ssh", ".aws", ".gnupg", ".kube", ".docker/config", ".netrc",
    ".env", "credentials", "id_rsa", "id_ed25519", ".pem", ".p12",
    "keychain", ".npmrc", ".pypirc", ".git-credentials",
]

/// Extract the paths a tool call names, split by where they land.
///
/// This is a *reading* of the command, not an execution trace: a shell can
/// construct paths at runtime, and nothing here will see those. It exists to
/// surface the obvious blast radius, not to prove a bound.
public func blastRadius(toolName: String, input: [String: Any], cwd: String) -> BlastRadius {
    var candidates: [String] = []

    // Explicit path arguments first — these are exact, not guesses.
    for key in ["file_path", "path", "notebook_path", "old_path", "new_path"] {
        if let p = input[key] as? String, !p.isEmpty { candidates.append(p) }
    }
    if let command = input["command"] as? String {
        candidates.append(contentsOf: pathsIn(command: command))
    }

    let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
    var inside: [String] = [], outside: [String] = [], sensitive: [String] = []
    var seen = Set<String>()

    for raw in candidates {
        let p = normalise(raw, cwd: base)
        guard seen.insert(p).inserted else { continue }
        if sensitiveMarkers.contains(where: { p.lowercased().contains($0) }) {
            sensitive.append(p)
        } else if p.hasPrefix(base + "/") || p == base {
            inside.append(p)
        } else {
            outside.append(p)
        }
    }
    return BlastRadius(inside: inside.sorted(), outside: outside.sorted(),
                       sensitive: sensitive.sorted())
}

/// Pull path-looking tokens out of a shell command.
func pathsIn(command: String) -> [String] {
    var out: [String] = []
    // Split on shell separators so `a>b` and `x;y` don't fuse into one token.
    let tokens = command.split(whereSeparator: { " \t\n|;&<>()".contains($0) })
    for t in tokens {
        var s = String(t).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,"))
        guard !s.isEmpty, !s.hasPrefix("-") else { continue }        // flags
        // Absolute, home-relative, or explicitly relative paths only. A bare
        // word like `swift` is a command, not a path, and treating it as one
        // would make every prompt claim a blast radius it doesn't have.
        guard s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("./") || s.hasPrefix("../")
                || s.contains("/") else { continue }
        if s.hasSuffix("/") { s.removeLast() }
        guard s.count > 1 else { continue }
        out.append(s)
    }
    return out
}

/// Resolve `~` and relative paths against the working directory so inside and
/// outside are decided on real locations, not on how the path was written.
func normalise(_ path: String, cwd: String) -> String {
    var p = path
    if p.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        p = home + p.dropFirst()
    }
    if !p.hasPrefix("/") {
        p = cwd + "/" + p
    }
    // Collapse `.` and `..` textually — `cd /a/b/../c` must land in /a/c, or a
    // path that escapes the project would be reported as inside it.
    var parts: [String] = []
    for c in p.split(separator: "/") {
        if c == "." { continue }
        if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
        parts.append(String(c))
    }
    return "/" + parts.joined(separator: "/")
}
