import Foundation

public enum ToolTier: String, Sendable {
    case readOnly   // safe to auto-approve
    case mutating   // writes/edits — prompt
    case network    // reaches out — prompt
    case shell      // Bash — prompt (content varies too much to auto-allow)
    case other      // unknown/MCP — prompt
}

/// Classify a tool for the tiered auto-allow policy. Only `.readOnly` is ever
/// auto-approved; everything else surfaces a prompt.
public func toolTier(_ name: String) -> ToolTier {
    switch name {
    case "Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "TodoRead":
        return .readOnly
    case "Write", "Edit", "MultiEdit", "NotebookEdit":
        return .mutating
    case "WebFetch", "WebSearch":
        return .network
    case "Bash":
        return .shell
    default:
        return .other
    }
}

/// Per-project override of the auto-allow behaviour. Lets a pentester run two
/// engagements at once with different postures — auto-allow in a scratch box,
/// prompt on everything in a client box — without touching the global toggle.
public enum ProjectPolicy: String, Sendable, CaseIterable, Codable {
    case inherit          // follow the global auto-allow-read-only setting
    case autoReadOnly     // auto-allow read-only tools regardless of the global
    case promptEverything // never auto-allow; always surface a prompt
    case bypassAll        // auto-allow everything (a scoped, revocable bypass)

    public var label: String {
        switch self {
        case .inherit: return "Default"
        case .autoReadOnly: return "Auto read-only"
        case .promptEverything: return "Prompt all"
        case .bypassAll: return "Allow all"
        }
    }
}

/// Per-session interception opt-in/opt-out. `matcher:"*"` means arming the
/// broker catches *every* session, including the one you're using to build the
/// tool. This lets a session be excluded (or singled out) explicitly.
public enum SessionArming: String, Sendable, CaseIterable, Codable {
    case inherit   // follow the "intercept new sessions" default
    case armed     // always intercept, even when the default is off
    case muted     // never intercept, even when the default is on

    public var label: String {
        switch self {
        case .inherit: return "Default"
        case .armed: return "Always intercept"
        case .muted: return "Never intercept"
        }
    }
}

/// Pure resolution of whether a given session's tool calls are intercepted.
/// `master` is the global Intercept switch; `defaultOn` is whether a session
/// with no explicit setting is caught. Unit-tested.
public func intercepts(master: Bool, defaultOn: Bool, session: SessionArming) -> Bool {
    guard master else { return false }
    switch session {
    case .armed: return true
    case .muted: return false
    case .inherit: return defaultOn
    }
}

/// How many mascots ride each notch wedge, and how many sessions didn't fit.
/// Sessions are dealt left, right, left… so two sessions read as one per side.
public func spriteLayout(sessionCount: Int, maxPerWedge: Int) -> (left: Int, right: Int, overflow: Int) {
    let capacity = maxPerWedge * 2
    let shown = min(sessionCount, capacity)
    let left = (shown + 1) / 2          // odd counts favour the left wedge
    return (left, shown - left, sessionCount - shown)
}

public enum AutoAction: Equatable, Sendable { case allow, prompt }

/// Pure resolution of whether a tool call is auto-allowed or surfaced, given the
/// project's policy and the global read-only setting. `.bypassAll` allows any
/// tool; `.promptEverything` surfaces any tool; the rest gate on the read-only
/// tier. Unit-tested.
public func autoDecision(tool: String, policy: ProjectPolicy, globalReadOnly: Bool) -> AutoAction {
    switch policy {
    case .bypassAll: return .allow
    case .promptEverything: return .prompt
    case .autoReadOnly: return toolTier(tool) == .readOnly ? .allow : .prompt
    case .inherit: return (globalReadOnly && toolTier(tool) == .readOnly) ? .allow : .prompt
    }
}

/// Pure resolution of what an *unanswered* prompt becomes at the auto-defer
/// deadline. Fail-closed: a high-risk or out-of-scope call left unanswered is
/// denied rather than handed back to Claude's own (allow-capable) flow.
/// Everything else defers ("ask"). Unit-tested.
public func timeoutDecision(failClosed: Bool, riskLevel: RiskLevel, outOfScope: Bool) -> String {
    if failClosed && (riskLevel >= .high || outOfScope) { return "deny" }
    return "ask"
}

/// One parsed line of a scope file.
///
/// Scope comes out of engagement paperwork as CIDR blocks, so the matcher has
/// to understand them properly. The old implementation only did string
/// prefixes — `10.0.0.` matched `10.0.0.7` by luck of text, and `10.0.0.0/8`
/// matched nothing at all, silently treating an entire in-scope range as
/// out-of-scope (or worse, the reverse for a `/24` written as a prefix).
public enum ScopeTarget: Sendable, Equatable {
    case cidr(base: UInt32, mask: UInt32)
    case ipv4(UInt32)
    case domain(String)
    /// Legacy trailing-dot prefix (`10.0.0.`), kept so existing scope files
    /// keep working.
    case prefix(String)

    public static func parse(_ raw: String) -> ScopeTarget? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        if let slash = s.firstIndex(of: "/") {
            let host = String(s[s.startIndex..<slash])
            let bitsPart = String(s[s.index(after: slash)...])
            guard let bits = Int(bitsPart), (0...32).contains(bits),
                  let base = ipv4ToUInt32(host) else { return nil }
            // A /0 mask must be 0, and UInt32 shifts by 32 are undefined.
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return .cidr(base: base & mask, mask: mask)
        }
        if let v = ipv4ToUInt32(s) { return .ipv4(v) }
        // Anything that is not a plausible hostname is rejected rather than
        // accepted as a domain. Falling through to `.domain(s)` meant a typo —
        // "not a host", "10.0.0.0 /8", a pasted sentence — became a target that
        // could never match any real host. The scope guard then stayed silent
        // and the operator believed a range was covered when nothing was.
        guard isPlausibleHostname(s) else { return nil }
        if s.hasSuffix(".") { return .prefix(s) }
        return .domain(s)
    }

    /// Hostname characters per RFC 1123, plus the trailing dot used to write a
    /// prefix target. No spaces, no scheme, no path.
    public static func isPlausibleHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !s.hasPrefix("."), !s.hasPrefix("-"), !s.hasSuffix("-") else { return false }
        guard !s.contains("..") else { return false }
        // A bare word with no dot is a hostname only in the loosest sense, and
        // in an engagement file it is far more likely to be a mistake.
        return s.contains(".")
    }

    public func covers(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .cidr(let base, let mask):
            guard let v = ipv4ToUInt32(h) else { return false }
            return v & mask == base
        case .ipv4(let v):
            return ipv4ToUInt32(h) == v
        case .domain(let d):
            return h == d || h.hasSuffix("." + d)
        case .prefix(let p):
            return h.hasPrefix(p)
        }
    }
}

/// Strict dotted-quad parse. Rejects anything with a non-numeric or >255
/// octet, so `999.1.1.1` and `main.swift` are not mistaken for addresses.
public func ipv4ToUInt32(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var out: UInt32 = 0
    for p in parts {
        guard !p.isEmpty, p.allSatisfy(\.isNumber), let v = UInt32(p), v <= 255 else { return nil }
        out = (out << 8) | v
    }
    return out
}

public struct ScopeConfig: Sendable {
    /// Raw lines as written in the scope file, for display.
    public let targets: [String]
    /// Parsed forms, resolved once at construction.
    public let parsed: [ScopeTarget]

    public init(targets: [String]) {
        self.targets = targets
        self.parsed = targets.compactMap(ScopeTarget.parse)
    }

    public var isEmpty: Bool { parsed.isEmpty }

    /// Lines that could not be understood, so a typo in a scope file surfaces
    /// instead of silently narrowing the scope.
    public var invalidLines: [String] {
        targets.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty
            && ScopeTarget.parse($0) == nil }
    }

    /// Hostname characters per RFC 1123, plus the trailing dot used to write a
    /// prefix target. No spaces, no scheme, no path.
    public static func isPlausibleHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !s.hasPrefix("."), !s.hasPrefix("-"), !s.hasSuffix("-") else { return false }
        guard !s.contains("..") else { return false }
        // A bare word with no dot is a hostname only in the loosest sense, and
        // in an engagement file it is far more likely to be a mistake.
        return s.contains(".")
    }

    public func covers(_ host: String) -> Bool {
        parsed.contains { $0.covers(host) }
    }
}

/// Final labels that look like a TLD to the domain regex but are really file
/// extensions. Without this, `main.swift` and `notes.md` read as out-of-scope
/// hosts — noisy enough that the operator learns to ignore the banner, which is
/// worse than not having it. Cheaper and more predictable than a public-suffix
/// list, and it only ever *suppresses* a flag, so a real host can't hide here.
let nonHostSuffixes: Set<String> = [
    "swift", "py", "js", "ts", "tsx", "jsx", "mjs", "cjs", "rb", "go", "rs",
    "java", "kt", "c", "h", "cc", "cpp", "hpp", "cs", "php", "pl", "sh", "bash",
    "zsh", "fish", "ps1", "bat", "txt", "md", "rst", "json", "jsonl", "yml",
    "yaml", "toml", "ini", "cfg", "conf", "lock", "log", "csv", "tsv", "sql",
    "xml", "html", "htm", "css", "scss", "png", "jpg", "jpeg", "gif", "svg",
    "webp", "ico", "pdf", "zip", "gz", "tar", "bz2", "xz", "dmg", "app", "so",
    "dylib", "dll", "exe", "bin", "o", "a", "class", "jar", "war", "env",
    "example", "sample", "template", "bak", "tmp", "old", "orig", "patch",
    "diff", "lst", "map", "min", "test", "spec", "mock", "d", "gitignore",
]

/// Keys whose values are filesystem paths, never network destinations. Scanning
/// them produces only false positives.
let pathLikeKeys: Set<String> = [
    "file_path", "path", "notebook_path", "cwd", "directory", "dir",
    "old_path", "new_path", "destination", "output_path", "filepath",
]

/// Extract host-like tokens from a shell command and return those NOT covered
/// by any in-scope target. Empty result = nothing out of scope (or no scope
/// configured). For an authorized-engagement workflow: a fast "is this command
/// reaching somewhere I'm not cleared to touch" flag.
public func outOfScopeHosts(command: String, scope: ScopeConfig) -> [String] {
    outOfScopeHosts(texts: [command], scope: scope)
}

/// Same check over several strings at once — every host-bearing field of a tool
/// call, not just a shell command. `WebFetch`'s URL is exactly as much of a
/// scope breach as `curl`, so it has to run through the same gate.
/// Compiled once. These were rebuilt on every call, and the call sites include a
/// SwiftUI TimelineView, so the app was compiling two regexes several times a
/// second while a prompt was on screen.
private let hostPatterns: [NSRegularExpression] = [
    #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#,
    #"\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b"#,
].compactMap { try? NSRegularExpression(pattern: $0) }

/// A host that appears with an explicit URL scheme — `https://evil.zip`,
/// `ftp://10.0.0.9`, `http://[2001:db8::1]` — is a network destination, not a
/// filename, so its captured host bypasses the file-extension suppression that
/// bare tokens go through. Without this, a real host on a TLD that doubles as a
/// common extension (`.zip`, `.app`, `.sh`) hid from the scope guard entirely,
/// even though dropping those from the extension list would flag every
/// `release.sh` and `SentryNotch.app` as noise. Group 1 is the host, IPv6
/// literals included in brackets.
private let schemeHostPattern = try? NSRegularExpression(
    pattern: #"[a-zA-Z][a-zA-Z0-9+.\-]*://(?:[^/@\s]+@)?(\[[0-9A-Fa-f:]+\]|[a-zA-Z0-9.\-]+)"#)

public func outOfScopeHosts(texts: [String], scope: ScopeConfig) -> [String] {
    guard !scope.isEmpty else { return [] }
    var hosts = Set<String>()

    for text in texts {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for re in hostPatterns {
            for m in re.matches(in: text, range: range) {
                let token = ns.substring(with: m.range)
                if plausibleHost(token) { hosts.insert(token) }
            }
        }
        // Scheme-qualified hosts are added unconditionally (no extension
        // suppression) — a dot or an IPv6 literal is enough to be a host.
        if let re = schemeHostPattern {
            for m in re.matches(in: text, range: range) where m.numberOfRanges > 1 {
                var h = ns.substring(with: m.range(at: 1))
                let isIPv6 = h.hasPrefix("[") && h.hasSuffix("]")
                if isIPv6 { h = String(h.dropFirst().dropLast()) }
                // A dotted name or IPv6 literal is a host; so is an obfuscated
                // IP behind a scheme — a bare decimal (http://2130706433) or hex
                // (http://0x7f000001) integer is a classic allowlist-evasion form
                // and is worth surfacing. A scheme-less bare word (localhost,
                // myhost) is deliberately left to the dotted matchers to avoid
                // noise.
                let obfuscatedIP = h.allSatisfy(\.isNumber) || h.lowercased().hasPrefix("0x")
                if isIPv6 || h.contains(".") || obfuscatedIP { hosts.insert(h) }
            }
        }
    }

    return hosts.filter { !scope.covers($0) }.sorted()
}

/// A dotted token is a host unless its last label is a known file extension.
/// Dotted-quad IPs always pass.
public func plausibleHost(_ token: String) -> Bool {
    guard let last = token.split(separator: ".").last else { return false }
    if last.allSatisfy(\.isNumber) { return true }   // IP literal
    return !nonHostSuffixes.contains(last.lowercased())
}

/// Flatten a tool input into the strings worth scanning for hosts. Path-valued
/// keys are skipped; everything else (URLs, commands, prompts, MCP params,
/// nested objects and arrays) is fair game.
public func scannableTexts(_ input: [String: Any], depth: Int = 0) -> [String] {
    guard depth < 6 else { return [] }   // guard against pathological nesting
    var out: [String] = []
    for (key, value) in input {
        if pathLikeKeys.contains(key.lowercased()) { continue }
        out.append(contentsOf: scannableValue(value, depth: depth))
    }
    return out
}

private func scannableValue(_ value: Any, depth: Int) -> [String] {
    switch value {
    case let s as String:
        return [s]
    case let d as [String: Any]:
        return scannableTexts(d, depth: depth + 1)
    case let a as [Any]:
        return a.flatMap { scannableValue($0, depth: depth + 1) }
    default:
        return []
    }
}


// MARK: - Scope file review

/// One line of a scope file, with what became of it.
public struct ScopeLine: Equatable, Sendable, Identifiable {
    public let number: Int
    public let text: String
    public let kind: Kind
    public var id: Int { number }

    public enum Kind: Equatable, Sendable {
        case comment
        case blank
        case target(String)   // human description of what it matches
        case invalid(String)  // why it was rejected
    }

    public var isTarget: Bool { if case .target = kind { return true }; return false }
    public var isInvalid: Bool { if case .invalid = kind { return true }; return false }
}

/// Review a scope file line by line.
///
/// `ScopeConfig` builds itself with `compactMap(ScopeTarget.parse)`, which
/// silently discards anything unparseable. For a convenience setting that would
/// be fine; for an engagement boundary it is the worst possible failure — a
/// typo'd CIDR means you believe a range is in scope, the guard never flags it,
/// and nothing anywhere says so. This exists so the editor can show exactly
/// which lines took effect and which were thrown away.
public func reviewScope(_ text: String) -> [ScopeLine] {
    text.components(separatedBy: "\n").enumerated().map { i, raw in
        let n = i + 1
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ScopeLine(number: n, text: raw, kind: .blank) }
        if trimmed.hasPrefix("#") { return ScopeLine(number: n, text: raw, kind: .comment) }
        guard let target = ScopeTarget.parse(trimmed) else {
            return ScopeLine(number: n, text: raw, kind: .invalid(rejectionReason(trimmed)))
        }
        return ScopeLine(number: n, text: raw, kind: .target(describe(target)))
    }
}

/// Say *why* a line was rejected. "Invalid" alone sends someone hunting.
func rejectionReason(_ s: String) -> String {
    if let slash = s.firstIndex(of: "/") {
        let host = String(s[s.startIndex..<slash])
        let bits = String(s[s.index(after: slash)...])
        if Int(bits) == nil { return "prefix length after / is not a number" }
        if let b = Int(bits), !(0...32).contains(b) { return "prefix length must be 0–32" }
        if ipv4ToUInt32(host) == nil { return "the part before / is not an IPv4 address" }
        return "not a valid CIDR block"
    }
    if s.contains(" ") { return "contains a space — one target per line" }
    if !s.contains(".") { return "no dot — write a domain, IP, or CIDR block" }
    if s.contains("..") { return "contains an empty label (..)" }
    return "not a hostname, domain, IP, or CIDR block"
}

func describe(_ t: ScopeTarget) -> String {
    switch t {
    case .domain(let d):  return "domain \(d) and its subdomains"
    case .prefix(let p):  return "anything starting \(p)"
    case .ipv4:           return "a single IPv4 address"
    case .cidr(_, let m): return "an IPv4 range (/\(maskBits(m)))"
    }
}

func maskBits(_ mask: UInt32) -> Int { mask == 0 ? 0 : 32 - Int(mask.trailingZeroBitCount) }
