import Foundation

/// Data-exfiltration heuristics: flag a command that sends *local data out*, the
/// way an operator reads a command rather than the way a linter does. This is
/// the lens generic agent-guards miss — not "is this command destructive" but
/// "is this command about to move a file, a secret, or a keystore off the box".
///
/// Deliberately conservative toward warning, like the rest of RiskAnalysis: a
/// false "caution" costs a glance, a missed `curl --data-binary @~/.ssh/id_rsa`
/// costs the key. Pure and unit-tested.
public func exfilRisks(command cmd: String) -> [(RiskLevel, String)] {
    var out: [(RiskLevel, String)] = []

    func has(_ pattern: String) -> Bool {
        cmd.range(of: pattern, options: .regularExpression) != nil
    }

    // A file handed to curl/wget as an upload body: --data-binary @file, -d @file,
    // --data @file, -F field=@file, -T file, --upload-file file. `@-` (read
    // stdin) is caught by the pipe check below, so a bare `@` here is a real path.
    let uploadsFile = has(#"\b(curl|wget)\b[\s\S]*(--data(-binary|-raw)?|-d|--form|-F)\s+\S*@[^\s-]"#)
        || has(#"\b(curl|wget)\b[\s\S]*(-T|--upload-file)\s+[^\s-]"#)
    if uploadsFile {
        let sensitive = mentionsSensitiveFile(cmd)
        out.append((sensitive ? .high : .medium,
                    sensitive ? "uploads a sensitive file to the network"
                              : "uploads a local file to the network"))
    }

    // Read-a-file-then-send-it: `cat X | curl ... @-`, `... | nc host port`,
    // `... | ncat`, `... | socat`. The classic exfil pipe.
    if has(#"\|\s*(curl|wget)\b[\s\S]*@-"#) {
        out.append((mentionsSensitiveFile(cmd) ? .high : .medium,
                    "pipes local data into an HTTP upload"))
    }
    if has(#"\|\s*(nc|ncat|netcat|socat)\b"#) || has(#"\b(nc|ncat|netcat)\b[\s\S]*<\s*[^\s]"#) {
        out.append((.high, "sends data over a raw socket (nc/socat)"))
    }

    // Encode-then-send: base64/xxd/openssl enc feeding a network client. A very
    // common way to smuggle a keystore past a naive content filter.
    if has(#"\b(base64|xxd|openssl\s+enc)\b[\s\S]*\|\s*(curl|wget|nc|ncat|socat)\b"#) {
        out.append((.high, "encodes local data and sends it out (obfuscated exfil)"))
    }

    // Copy local files to a remote host: the remote `host:` must be the final
    // argument (the destination). `scp user@host:file ./` is a download — its
    // last token has no colon — so anchoring the remote at end keeps uploads
    // flagged without catching pulls.
    if has(#"\bscp\b[\s\S]*\s[\w.-]*@?[\w.-]+:\S*\s*$"#)
        || has(#"\brsync\b[\s\S]*\s[\w.-]*@?[\w.-]+:\S*\s*$"#) {
        out.append((.medium, "copies local files to a remote host"))
    }

    // A cloud-storage upload. Flag when a bucket URL is the destination (the
    // last token) rather than the source — `aws s3 cp file s3://…`, not
    // `aws s3 cp s3://… file` (a restore).
    let cloudCmd = has(#"\b(aws\s+s3\s+(cp|sync)|gsutil\s+cp|gcloud\s+storage\s+cp|az\s+storage\s+blob\s+upload|rclone\s+copy)\b"#)
    if cloudCmd, has(#"(s3|gs|b2|azure)://\S+\s*$"#) || has(#"blob\s+upload\b"#) {
        out.append((.medium, "uploads local files to cloud storage"))
    }

    return out
}

/// Whether a command references a path that looks like a credential/keystore.
/// Reused by several exfil detectors to escalate medium → high.
func mentionsSensitiveFile(_ cmd: String) -> Bool {
    let lower = cmd.lowercased()
    let needles = [".ssh/", "id_rsa", "id_ed25519", ".aws/credentials", ".aws/config",
                   ".gnupg", ".env", "secrets", "credentials", ".netrc", ".kube/config",
                   ".docker/config", "keychain", ".pem", ".p12", ".pfx", "private key",
                   "wallet", ".config/gcloud"]
    return needles.contains { lower.contains($0) }
}

/// Dependency-manifest awareness for writes/edits: adding a dependency to a
/// project manifest is a supply-chain event worth a glance, even though the
/// write itself is inside the working directory. Given the added text (the
/// `new_string` of an Edit, or the whole content of a Write), return the names
/// of dependency-like lines it introduces.
public func addedDependencies(path: String, addedText: String) -> [String] {
    let name = (path as NSString).lastPathComponent.lowercased()
    var deps: [String] = []
    func scanLines(_ pattern: String) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let ns = addedText as NSString
        for m in re.matches(in: addedText, range: NSRange(location: 0, length: ns.length))
        where m.numberOfRanges > 1 {
            deps.append(ns.substring(with: m.range(at: 1)))
        }
    }
    switch name {
    case "package.json":
        // "left-pad": "^1.0.0"  inside a dependencies block.
        scanLines(#""([@\w./-]+)"\s*:\s*"[\^~<>=\d][^"]*""#)
    case "requirements.txt":
        scanLines(#"(?m)^\s*([A-Za-z0-9_.-]+)\s*(?:[=<>!~]=|@)"#)
    case "go.mod":
        scanLines(#"(?m)^\s*(?:require\s+)?([\w.\-/]+)\s+v\d"#)
    case "cargo.toml":
        scanLines(#"(?m)^\s*([A-Za-z0-9_-]+)\s*=\s*[\{"]"#)
    case "gemfile":
        scanLines(#"(?m)gem\s+['"]([\w.-]+)['"]"#)
    case "pyproject.toml", "pipfile":
        scanLines(#"(?m)^\s*([A-Za-z0-9_.-]+)\s*=\s*["\{]"#)
    default:
        break
    }
    // De-dup, drop obvious non-deps (version keys), keep it short for display.
    let noise: Set<String> = ["version", "name", "description", "license", "author",
                              "main", "scripts", "type", "private", "edition"]
    return Array(NSOrderedSet(array: deps.filter { !noise.contains($0.lowercased()) }).array as? [String] ?? []).prefix(6).map { $0 }
}
