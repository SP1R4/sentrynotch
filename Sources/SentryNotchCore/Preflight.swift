import Foundation

/// A single "what this command will actually do" note for the pre-flight
/// preview, so a decision isn't made blind.
public struct PreflightNote: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable { case info, caution, danger }
    public let severity: Severity
    public let text: String
    public init(_ severity: Severity, _ text: String) { self.severity = severity; self.text = text }
    public var id: String { "\(severity.rawValue):\(text)" }
}

/// Read-only classification of a Bash command's irreversible effects. Pure — no
/// filesystem, no process exec — so it's fully testable. The caller layers
/// filesystem-backed detail (rm target counts) on top via `removalTargets`.
public func preflightNotes(command cmd: String) -> [PreflightNote] {
    var notes: [PreflightNote] = []
    func has(_ p: String) -> Bool { cmd.range(of: p, options: .regularExpression) != nil }

    if has(#"\bgit\s+push\b[\s\S]*(--force-with-lease\b|--force\b|(?<![\w-])-[a-zA-Z]*f\b)"#) {
        let lease = has(#"--force-with-lease"#)
        notes.append(.init(lease ? .caution : .danger,
            lease ? "force-push with lease — overwrites remote history unless it has moved"
                  : "force-push — overwrites remote history unconditionally"))
    }
    if has(#"\bgit\s+reset\s+--hard\b"#) {
        notes.append(.init(.danger, "discards every uncommitted change in the working tree"))
    }
    if has(#"\bgit\s+clean\b[\s\S]*-[a-z]*f"#) {
        let dirs = has(#"\bgit\s+clean\b[\s\S]*-[a-z]*d"#)
        notes.append(.init(.danger, dirs ? "deletes untracked files and directories"
                                          : "deletes untracked files"))
    }
    if has(#"\bgit\s+(checkout\s+--\s|restore\b)"#) {
        notes.append(.init(.caution, "reverts files to their committed state, dropping local edits"))
    }
    if has(#"\b(mkfs|dd)\b"#) {
        notes.append(.init(.danger, "writes raw device/filesystem data — not reversible"))
    }
    if has(#"\bgit\s+branch\s+-D\b"#) {
        notes.append(.init(.caution, "force-deletes a branch, even if unmerged"))
    }
    return notes
}

/// The non-flag arguments to each `rm` in the command, so the caller can expand
/// them against the filesystem and count what a deletion would actually remove.
/// Stops each `rm` at a shell separator so flags of a later command aren't
/// mistaken for targets. Pure.
public func removalTargets(command cmd: String) -> [String] {
    let tokens = shellTokens(cmd)
    var targets: [String] = []
    var i = 0
    while i < tokens.count {
        if tokens[i] == "rm" || tokens[i].hasSuffix("/rm") {
            var j = i + 1
            while j < tokens.count {
                let arg = tokens[j]
                if arg.contains(";") || arg.contains("|") || arg.contains("&") { break }
                // Skip flags, including the `--` end-of-options marker.
                if !arg.hasPrefix("-") { targets.append(arg) }
                j += 1
            }
            i = j
        } else {
            i += 1
        }
    }
    return targets
}
