import Foundation

/// Active deception. A honeytoken is a decoy an agent must never touch — a fake
/// `.env`, a bait private key, a planted AWS credential file. Legitimate work
/// never reads it, so any access is a near-certain signal of something wrong:
/// an over-eager agent scraping secrets, or a compromised one. A trip is treated
/// as an incident, not a prompt — the caller denies it and arms the panic brake.
public struct Honeytoken: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// An absolute path, a `~`-path, or a bare filename matched by basename.
    public var path: String
    public var label: String

    public init(id: UUID = UUID(), path: String, label: String) {
        self.id = id
        self.path = path
        self.label = label
    }

    var basename: String { (path as NSString).lastPathComponent }
    var expanded: String { (path as NSString).expandingTildeInPath }
}

/// Which honeytokens a tool call trips. Matches a full/`~` path by exact or
/// path-suffix equality, and a bare-filename token by its basename appearing as
/// a whole word in the command text or as a referenced file path. Pure.
public func trippedHoneytokens(command: String?, paths: [String],
                               tokens: [Honeytoken]) -> [Honeytoken] {
    guard !tokens.isEmpty else { return [] }
    var tripped: [Honeytoken] = []

    for t in tokens {
        let base = t.basename
        guard !base.isEmpty else { continue }
        var hit = false

        // Referenced file paths (Read/Write/Edit file_path, etc.).
        for p in paths {
            let ep = (p as NSString).expandingTildeInPath
            if ep == t.expanded || ep.hasSuffix("/" + t.expanded)
                || (p as NSString).lastPathComponent == base {
                hit = true
                break
            }
        }

        // The basename appearing as a whole word in a Bash command.
        if !hit, let cmd = command, !cmd.isEmpty {
            let pattern = "(^|[^A-Za-z0-9._-])" + NSRegularExpression.escapedPattern(for: base) + "($|[^A-Za-z0-9._-])"
            if cmd.range(of: pattern, options: .regularExpression) != nil { hit = true }
        }

        if hit { tripped.append(t) }
    }
    return tripped
}

/// A small starter set of convincing bait, for the "plant decoys" helper. Names
/// are chosen to look like exactly what an agent scraping for secrets would grab.
public func starterHoneytokenFiles() -> [(name: String, contents: String)] {
    [
        (".env.production", """
        # production secrets — DO NOT COMMIT
        DATABASE_URL=postgres://svc:S3cr3t@db.internal:5432/app
        STRIPE_SECRET_KEY=sk_live_HONEYTOKEN_do_not_use_bait
        JWT_SIGNING_SECRET=6f1c9b2e4a7d8c05f3e21a9048bd77e2
        """),
        ("aws_credentials", """
        [default]
        aws_access_key_id = AKIAIOSFODNN7EXAMPLE
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
        """),
        ("id_ed25519_backup", """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDECOYDECOYDECOYDECOYDECOYDECOYDECOYDECOYDECOYDA
        -----END OPENSSH PRIVATE KEY-----
        """),
    ]
}
