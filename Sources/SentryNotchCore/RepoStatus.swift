import Foundation

public struct RepoState: Equatable, Sendable {
    public var branch: String
    public var modified: Int
    public var untracked: Int
    public var staged: Int

    public init(branch: String, modified: Int, untracked: Int, staged: Int) {
        self.branch = branch
        self.modified = modified
        self.untracked = untracked
        self.staged = staged
    }

    public var dirty: Int { modified + untracked + staged }
    public var isClean: Bool { dirty == 0 }
}

/// Parse `git status --porcelain=v1 -b`.
///
/// Pure so it can be tested against real git output — the porcelain format is
/// stable but its two-column status codes are easy to misread, and getting the
/// counts wrong would make the widget quietly lie about how much an agent
/// changed.
///
/// Column 1 is the index (staged) state, column 2 the work-tree state. A file
/// can be in both, and is counted in both, because the number that matters is
/// "how much work is uncommitted", not "how many filenames".
public func parseGitStatus(_ text: String) -> RepoState {
    var branch = "?"
    var modified = 0, untracked = 0, staged = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard !line.isEmpty else { continue }

        if line.hasPrefix("##") {
            // "## main", "## main...origin/main [ahead 1]",
            // "## HEAD (no branch)", "## No commits yet on main"
            var name = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let r = name.range(of: "...") { name = String(name[..<r.lowerBound]) }
            if let space = name.firstIndex(of: " ") { name = String(name[..<space]) }
            branch = name.isEmpty ? "?" : name
            continue
        }

        let chars = Array(line)
        guard chars.count >= 2 else { continue }
        let index = chars[0], work = chars[1]

        // Only real porcelain status codes count. Without this, any stray line
        // git emits — a warning, a locale-translated notice, an advice hint —
        // has its first two characters read as a status pair and inflates the
        // change count. The widget would then report edits that don't exist.
        let codes: Set<Character> = [" ", "M", "A", "D", "R", "C", "U", "T", "?", "!"]
        guard codes.contains(index), codes.contains(work) else { continue }

        if index == "?" && work == "?" { untracked += 1; continue }
        if index == "!" && work == "!" { continue }          // ignored
        if index != " " && index != "?" { staged += 1 }
        if work != " " && work != "?" { modified += 1 }
    }
    return RepoState(branch: branch, modified: modified, untracked: untracked, staged: staged)
}
