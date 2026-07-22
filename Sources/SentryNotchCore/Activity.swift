import Foundation

/// One recorded decision, with everything the log kept.
///
/// `DecisionRow` deliberately narrows this to day granularity for the
/// summariser; this is the full row, for the views that show individual calls
/// rather than counts.
public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let ts: String          // ISO8601
    public let decision: String    // "*" suffix = automatic
    public let tool: String
    public let summary: String
    public let project: String     // last path component of cwd
    public let cwd: String
    public let risk: String
    public let key: String

    public init(ts: String, decision: String, tool: String, summary: String,
                project: String, cwd: String = "", risk: String = "", key: String = "") {
        self.ts = ts; self.decision = decision; self.tool = tool
        self.summary = summary; self.project = project; self.cwd = cwd
        self.risk = risk; self.key = key
    }

    public var isAuto: Bool { decision.hasSuffix("*") }
    public var outcome: String {
        decision.hasSuffix("*") ? String(decision.dropLast()) : decision
    }
    /// Grants aren't tool calls; they're changes to the ruleset. Views that
    /// list "what the agent did" must exclude them or the count is wrong.
    public var isGrant: Bool { decision == "rule-granted" }
    public var isFlagged: Bool { isFlaggedRisk(risk) }

    /// `2026-07-19T17:57:52Z` → `17:57`. Empty when the stamp is unusable, so a
    /// malformed row renders blank rather than showing a misleading time.
    public var clock: String {
        let parts = ts.split(separator: "T")
        guard parts.count == 2 else { return "" }
        return String(parts[1].prefix(5))
    }
    public var day: String { String(ts.prefix(10)) }
}

/// What the activity list is currently narrowed to. All-nil means "everything".
public struct ActivityFilter: Equatable, Sendable {
    public var text: String = ""
    public var project: String?
    public var tool: String?
    public var outcome: String?        // "allow" | "deny" | "timeout"
    public var flaggedOnly = false
    public var manualOnly = false

    public init() {}

    public var isActive: Bool {
        !text.isEmpty || project != nil || tool != nil || outcome != nil
            || flaggedOnly || manualOnly
    }
}

/// Narrow the log to what the user asked for.
///
/// Pure and case-insensitive on the free-text term, which matches against the
/// command summary and the tool name — the two things someone actually
/// remembers when they go looking for a call after the fact.
///
/// Rule grants are excluded unless explicitly searched for: they share the log
/// with tool calls but they are not tool calls, and letting them pad the list
/// would misstate how much the agent did.
public func filterActivity(_ rows: [ActivityEntry], _ f: ActivityFilter) -> [ActivityEntry] {
    let needle = f.text.trimmingCharacters(in: .whitespaces).lowercased()
    return rows.filter { r in
        if r.isGrant { return false }
        if f.flaggedOnly && !r.isFlagged { return false }
        if f.manualOnly && r.isAuto { return false }
        if let p = f.project, r.project != p { return false }
        if let t = f.tool, r.tool != t { return false }
        if let o = f.outcome, r.outcome != o { return false }
        guard !needle.isEmpty else { return true }
        return r.summary.lowercased().contains(needle)
            || r.tool.lowercased().contains(needle)
    }
}

/// Distinct projects and tools present in the log, most-used first, for the
/// filter menus. Built from the data rather than hardcoded so a tool we've
/// never heard of still shows up.
public func activityFacets(_ rows: [ActivityEntry]) -> (projects: [String], tools: [String]) {
    var p: [String: Int] = [:], t: [String: Int] = [:]
    for r in rows where !r.isGrant {
        if !r.project.isEmpty { p[r.project, default: 0] += 1 }
        if !r.tool.isEmpty { t[r.tool, default: 0] += 1 }
    }
    func ranked(_ d: [String: Int]) -> [String] {
        d.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
    return (ranked(p), ranked(t))
}

// MARK: - Rules

/// A standing allow, with the history the log can reconstruct about it.
///
/// Nothing here needs new persistence: grants are already written to the audit
/// log as `rule-granted` rows carrying their source, and every later automatic
/// approval carries the same `key`. So "when did I grant this, how, and has it
/// actually been used since" is all recoverable from what we already keep.
public struct RuleUsage: Identifiable, Equatable, Sendable {
    public let key: String
    public let grantedAt: String?    // nil for rules predating grant logging
    public let source: String?
    public let firedSince: Int       // automatic approvals after the grant
    public let lastUsed: String?
    public var id: String { key }

    public init(key: String, grantedAt: String?, source: String?,
                firedSince: Int, lastUsed: String?) {
        self.key = key; self.grantedAt = grantedAt; self.source = source
        self.firedSince = firedSince; self.lastUsed = lastUsed
    }

    public var label: String { key.split(separator: "|").last.map(String.init) ?? key }
    public var tool: String { key.split(separator: "|").first.map(String.init) ?? key }
    /// A rule that has never fired is one you can revoke for free. Surfacing
    /// these is the whole point: standing allows accumulate silently, and the
    /// ones that never trigger are pure attack surface with no convenience
    /// benefit to weigh against removing them.
    public var isUnused: Bool { firedSince == 0 }
}

/// Reconstruct what each standing rule has actually done.
///
/// `rows` is the full log. Only automatic approvals count toward `firedSince` —
/// a call you answered by hand didn't use the rule, even if a rule for it
/// exists, so counting it would overstate the rule's value.
public func ruleUsage(rules: Set<String>, rows: [ActivityEntry]) -> [RuleUsage] {
    var grantedAt: [String: String] = [:]
    var source: [String: String] = [:]
    var fired: [String: Int] = [:]
    var lastUsed: [String: String] = [:]

    // Latest grant wins: a rule revoked and re-granted should date from the
    // re-grant, not from the original.
    for r in rows where r.isGrant {
        let k = r.key.isEmpty ? r.tool : r.key
        guard rules.contains(k) else { continue }
        if let prior = grantedAt[k], prior > r.ts { continue }
        grantedAt[k] = r.ts
        source[k] = r.summary
            .replacingOccurrences(of: "standing allow created via ", with: "")
    }

    for r in rows where !r.isGrant && r.isAuto && r.outcome == "allow" {
        let k = r.key.isEmpty ? r.tool : r.key
        guard rules.contains(k) else { continue }
        // Approvals from before the grant came from some other tier (read-only
        // auto-allow, a project policy) and are not this rule's doing.
        if let g = grantedAt[k], r.ts < g { continue }
        fired[k, default: 0] += 1
        if (lastUsed[k] ?? "") < r.ts { lastUsed[k] = r.ts }
    }

    return rules.map {
        RuleUsage(key: $0, grantedAt: grantedAt[$0], source: source[$0],
                  firedSince: fired[$0] ?? 0, lastUsed: lastUsed[$0])
    }
    // Unused first — they're the ones that want a decision.
    .sorted {
        $0.isUnused != $1.isUnused ? $0.isUnused
            : ($0.firedSince == $1.firedSince ? $0.key < $1.key : $0.firedSince > $1.firedSince)
    }
}

// MARK: - Launch at login

/// Whether the app is somewhere macOS can reliably relaunch it from.
///
/// A login item records the bundle's *path*. Registering from a build
/// directory, a Downloads folder, or a mounted disk image produces a login item
/// that works until the app moves and then silently stops — the user is left
/// believing it starts at login when it no longer can. Checking up front lets
/// the UI say so instead of failing quietly later.
///
/// Pure and path-based so the rule is testable without installing anything.
public func launchAtLoginWarning(bundlePath: String, home: String) -> String? {
    let p = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
    if p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/") { return nil }
    if p.contains("/.build/") || p.contains("/DerivedData/") {
        return "Running from a build directory. Move the app to Applications first, or the login item will break the next time it's rebuilt."
    }
    if p.hasPrefix("/Volumes/") {
        return "Running from a mounted volume. Copy the app to Applications first — a login item can't start it once the volume is ejected."
    }
    return "Not installed in Applications. The login item points at the app's current location, so moving it later will stop it starting."
}

// MARK: - Log rotation

/// Archive index encoded in a rotated log filename, e.g. `decisions.7.jsonl` → 7.
/// Nil for anything that isn't one of ours.
public func logArchiveIndex(_ filename: String, stem: String) -> Int? {
    guard filename.hasPrefix(stem + "."), filename.hasSuffix(".jsonl") else { return nil }
    let middle = filename.dropFirst(stem.count + 1).dropLast(".jsonl".count)
    return Int(middle)
}

/// Log files newest-first: the live file, then archives by descending index.
///
/// Rotation renames the live file to the next *higher* index rather than
/// shifting every archive down, so writing stays O(1) no matter how much
/// history has accumulated. That makes a higher number a newer archive, which
/// is the opposite of the usual logrotate convention — hence doing the ordering
/// in one tested place instead of by eye at each call site.
public func orderedLogFiles(stem: String, archives: [String]) -> [String] {
    let sorted = archives
        .compactMap { name -> (String, Int)? in
            logArchiveIndex(name, stem: stem).map { (name, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    return ["\(stem).jsonl"] + sorted
}

/// The next archive index to rotate into.
public func nextArchiveIndex(stem: String, archives: [String]) -> Int {
    (archives.compactMap { logArchiveIndex($0, stem: stem) }.max() ?? 0) + 1
}

/// Take the newest `limit` items across log files.
///
/// `chunks` arrive newest-file-first, but the rows inside each file are
/// oldest-first — the two orderings run opposite ways, which is what made
/// slicing this by hand wrong. Taking from the front of the first chunk yields
/// the *oldest* records of the *newest* file, so once the cap binds the caller
/// summarises ancient history and ignores everything recent.
public func newestAcrossFiles<T>(_ chunks: [[T]], limit: Int) -> [T] {
    guard limit > 0 else { return [] }
    var out: [T] = []
    for chunk in chunks {
        if out.count >= limit { break }
        out.append(contentsOf: chunk.suffix(limit - out.count))
    }
    return out
}
