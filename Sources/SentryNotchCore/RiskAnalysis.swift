import Foundation

public enum RiskLevel: Int, Comparable, Sendable {
    case none = 0, low, medium, high
    public static func < (l: RiskLevel, r: RiskLevel) -> Bool { l.rawValue < r.rawValue }

    public var label: String {
        switch self {
        case .none: return ""
        case .low: return "heads-up"
        case .medium: return "caution"
        case .high: return "danger"
        }
    }
}

public struct RiskReport: Sendable {
    public let level: RiskLevel
    public let reasons: [String]
    public init(level: RiskLevel, reasons: [String]) {
        self.level = level
        self.reasons = reasons
    }
    public var isEmpty: Bool { level == .none && reasons.isEmpty }
}

/// Flags patterns worth a second look before allowing a tool call. Heuristic,
/// deliberately conservative toward *warning* — a false "caution" is cheap, a
/// missed `rm -rf ~` is not. Pure and unit-tested.
public func analyzeRisk(toolName: String, input: [String: Any], cwd: String) -> RiskReport {
    var reasons: [(RiskLevel, String)] = []

    if toolName == "Bash", let cmd = input["command"] as? String {
        reasons += bashRisks(cmd)
    }

    // File writes/edits outside the session's working directory.
    if let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String),
       ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(toolName) {
        if !cwd.isEmpty, !isInside(path: path, dir: cwd) {
            reasons.append((.medium, "writes outside the working directory"))
        }
        if looksSensitive(path: path) {
            reasons.append((.high, "touches a sensitive path (\(abbrev(path)))"))
        }
    }

    let level = reasons.map(\.0).max() ?? .none
    return RiskReport(level: level, reasons: reasons.map(\.1))
}

// MARK: - Bash heuristics

/// True when the command runs `rm` with BOTH a recursive and a force flag, in
/// any order or spelling: combined (`-rf`, `-Rf`), separated (`-r … -f`), or
/// long (`--recursive --force`).
///
/// The previous single regex matched only a combined *lowercase* flag glued to
/// `rm`, so `rm -Rf` (— `-R` is idiomatic on macOS/BSD), `rm -r -f`, and
/// `rm --recursive --force` — all equally destructive — read as no risk at all.
private func isRecursiveForceDelete(_ cmd: String) -> Bool {
    let tokens = shellTokens(cmd)
    var i = 0
    while i < tokens.count {
        let head = tokens[i]
        if head == "rm" || head.hasSuffix("/rm") {
            var recursive = false, force = false
            var j = i + 1
            while j < tokens.count {
                let arg = tokens[j]
                // A shell separator ends this command; flags past it belong to
                // whatever runs next, not to this `rm`.
                if arg.contains(";") || arg.contains("|") || arg.contains("&") { break }
                if arg == "--recursive" { recursive = true }
                else if arg == "--force" { force = true }
                else if arg.hasPrefix("-") && !arg.hasPrefix("--") {
                    // A bundle of short flags: -rf, -Rf, -r, -f, … case-folded
                    // because -R and -r mean the same thing.
                    let flags = arg.dropFirst().lowercased()
                    if flags.contains("r") { recursive = true }
                    if flags.contains("f") { force = true }
                }
                if recursive && force { return true }
                j += 1
            }
        }
        i += 1
    }
    return false
}

private func bashRisks(_ cmd: String) -> [(RiskLevel, String)] {
    var out: [(RiskLevel, String)] = []
    let lower = cmd.lowercased()

    func has(_ pattern: String) -> Bool {
        cmd.range(of: pattern, options: .regularExpression) != nil
    }

    if isRecursiveForceDelete(cmd) {
        out.append((.high, "recursive force delete (rm -rf)"))
    }
    if has(#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#) {
        out.append((.high, "pipes a download straight into a shell"))
    }
    if lower.contains("sudo ") {
        out.append((.medium, "runs with sudo"))
    }
    if has(#"\bchmod\s+(-R\s+)?0?777\b"#) {
        out.append((.medium, "chmod 777 (world-writable)"))
    }
    if has(#"\b(mkfs|dd)\b"#) || has(#">\s*/dev/[sr]d"#) {
        out.append((.high, "raw disk / filesystem write"))
    }
    if has(#":\s*\(\s*\)\s*\{"#) {
        out.append((.high, "looks like a fork bomb"))
    }
    if has(#"\bgit\s+push\b.*(--force|-f)\b"#) {
        out.append((.medium, "force-push (rewrites remote history)"))
    }
    if has(#"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)"#) {
        out.append((.medium, "discards local changes irreversibly"))
    }
    if has(#"(?i)(api[_-]?key|secret|token|password|passwd)\s*=\s*\S"#)
        || has(#"AKIA[0-9A-Z]{16}"#) {
        out.append((.medium, "may contain a credential in plaintext"))
    }
    if has(#">\s*/dev/null.*2>&1"#) == false, lower.contains(" | base64 -d"), lower.contains("eval") {
        out.append((.high, "decodes and evals data (obfuscation)"))
    }
    return out
}

// MARK: - Paths

private func isInside(path: String, dir: String) -> Bool {
    let p = URL(fileURLWithPath: path).standardizedFileURL.path
    let d = URL(fileURLWithPath: dir).standardizedFileURL.path
    return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
}

private func looksSensitive(path: String) -> Bool {
    let p = (path as NSString).expandingTildeInPath
    let needles = ["/.ssh/", "/.aws/", "/.gnupg/", "/.config/gcloud/",
                   "/.claude/settings", "/etc/", "id_rsa", ".env", "credentials"]
    return needles.contains { p.contains($0) }
}

private func abbrev(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Whether a risk label recorded in the audit log means "high risk".
///
/// The log stores `RiskLevel.label` — `""`, `"heads-up"`, `"caution"`,
/// `"danger"`. Three call sites independently compared against `"high"` and
/// `"critical"`, which this code has never written, so every one of them
/// silently matched nothing: the analytics "high risk" counter sat at zero, the
/// engagement report's high-risk section was always empty, and — worst —
/// `suggestRules`' documented promise never to suggest a dangerous pattern was
/// dead code, so a repeatedly-approved `rm -rf` could be offered as a standing
/// allow.
///
/// Comparing through one function is the actual fix; the legacy spellings stay
/// accepted so logs written by any earlier build still classify correctly.
public func isHighRisk(_ risk: String) -> Bool {
    risk == RiskLevel.high.label || risk == "high" || risk == "critical"
}

/// Whether a label is worth surfacing at all — high or the tier below it.
public func isFlaggedRisk(_ risk: String) -> Bool {
    isHighRisk(risk) || risk == RiskLevel.medium.label
}
