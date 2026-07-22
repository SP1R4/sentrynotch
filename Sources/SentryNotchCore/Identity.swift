import Foundation

/// Coarse rule identity for "Always Allow": tool name + first command token
/// (for Bash) so allowing `git status` doesn't also allow `rm -rf`.
public func ruleKey(toolName: String, input: [String: Any]) -> String {
    // Bash always carries the separator, even when the command is missing or
    // not a string. Otherwise a malformed call collapses to the bare tool name
    // — the same shape as a whole-tool key like "Edit" — and an Always-Allow
    // created from it would read as covering every Bash call.
    if toolName == "Bash" {
        let cmd = input["command"] as? String ?? ""
        let parsed = commandHead(cmd)
        // An environment prefix gets its own key rather than collapsing into
        // the bare command's. `FOO=bar npm test` reusing a standing `Bash|npm`
        // rule would be a silent widening of that grant, and the prefix is
        // exactly where LD_PRELOAD, DYLD_INSERT_LIBRARIES, NODE_OPTIONS and
        // PATH live — variables that change what the command actually does.
        // So it is deliberately *not* the same rule, and must be approved once
        // on its own terms.
        return parsed.hasEnvPrefix ? "Bash|env:\(parsed.head)" : "Bash|\(parsed.head)"
    }
    return toolName
}

/// The real command a shell line invokes, looking past `VAR=value` prefixes.
///
/// Taking the first whitespace-delimited token verbatim meant a line like
/// `SC="/tmp/x" ./run.sh` produced the key `Bash|SC="/tmp/x"` — a rule that can
/// never match anything again, quietly accumulating as junk in the ruleset.
public func commandHead(_ command: String) -> (head: String, hasEnvPrefix: Bool) {
    var sawAssignment = false
    for token in shellTokens(command) {
        if isEnvAssignment(token[...]) { sawAssignment = true; continue }
        return (token, sawAssignment)
    }
    // Nothing but assignments (or nothing at all). There is no command to key
    // on, so the separator is kept and the head left empty — still distinct
    // from the bare tool name, which would read as covering every Bash call.
    return ("", sawAssignment)
}

/// Split a command into tokens, respecting quotes.
///
/// Splitting on bare whitespace tears `SC="/tmp/a b" ./run.sh` into
/// `SC="/tmp/a`, `b"`, `./run.sh` — so the second fragment, part of a quoted
/// value, was mistaken for the command being run. Quotes are not stripped; the
/// token text only has to be stable enough to recognise an assignment and to
/// name a rule.
public func shellTokens(_ command: String) -> [String] {
    var out: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for c in command {
        if escaped { current.append(c); escaped = false; continue }
        if c == "\\" && quote != "'" { escaped = true; current.append(c); continue }
        if let q = quote {
            current.append(c)
            if c == q { quote = nil }
            continue
        }
        if c == "'" || c == "\"" { quote = c; current.append(c); continue }
        if c == " " || c == "\n" || c == "\t" {
            if !current.isEmpty { out.append(current); current = "" }
            continue
        }
        current.append(c)
    }
    if !current.isEmpty { out.append(current) }
    return out
}

/// `NAME=value` in the leading position, per POSIX variable-name rules.
func isEnvAssignment(_ token: Substring) -> Bool {
    guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
    let name = token[token.startIndex..<eq]
    guard let first = name.first, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

public enum ProjectPath {
    /// Prefer a real cwd (from the transcript) over decoding; only decode the
    /// directory name as a fallback. The decode is lossy for names containing
    /// dashes, so it must never override a known cwd.
    public static func displayName(cwd: String?, encodedDir: String) -> String {
        if let cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return (decode(encodedDir) as NSString).lastPathComponent
    }

    public static func displayCwd(cwd: String?, encodedDir: String) -> String {
        if let cwd, !cwd.isEmpty { return cwd }
        return decode(encodedDir)
    }

    /// "-Users-sp1r4-Downloads-veil" -> "/Users/sp1r4/Downloads/veil".
    /// Lossy: a real dash in a path component is indistinguishable from a
    /// separator, which is exactly why callers should prefer a known cwd.
    public static func decode(_ encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }
}

/// Quote a path for embedding in a shell command line.
///
/// Hook commands are stored in `settings.json` as a single string and executed
/// through a shell, so any path containing a space must be quoted. This was
/// latent for a long time: the state directory used to be `~/.claude/xisland/`,
/// which has no space, and an unquoted command worked. Moving state into
/// `~/Library/Application Support/…` made every generated command split at
/// "Application", so `python3` received a nonexistent file, every PreToolUse
/// hook errored, and Claude Code refused every tool call — a total outage on
/// first install, for every user, since that path is not optional.
///
/// Single quotes rather than double: they suppress every form of shell
/// expansion, so a path containing `$`, backticks or a backslash can't be
/// interpreted. The only character needing care is a single quote itself,
/// which is closed, escaped, and reopened.
public func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
