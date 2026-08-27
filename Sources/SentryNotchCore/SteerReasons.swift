import Foundation

/// Instructive denial reasons. A bare "denied" tells an agent nothing; a reason
/// steers it toward the safe path and saves a round-trip. These are surfaced as
/// quick picks on the deny button — the relevant ones first, based on why the
/// call was flagged.

/// Always-available generic steers.
public let genericSteerReasons: [String] = [
    "Denied — explain what this does and why it's needed before I approve.",
    "Denied — do this a safer way and show me the diff first.",
    "Denied — this is out of scope for the engagement; leave it alone.",
]

/// Steers matched to the risk reasons on the call, most specific first. Falls
/// back to the generic set so there's always something to pick.
public func steerReasons(for riskReasons: [String], outOfScope: Bool) -> [String] {
    var out: [String] = []
    let joined = riskReasons.joined(separator: " ").lowercased()

    if outOfScope {
        out.append("Denied — that host is out of engagement scope. Do not contact it.")
    }
    if joined.contains("shell") || joined.contains("curl") || joined.contains("download") {
        out.append("Denied — don't pipe a download into a shell. Fetch it, show me the script and a checksum, then run it locally.")
    }
    if joined.contains("sudo") {
        out.append("Denied — don't use sudo. If it truly needs elevation, tell me exactly which step and why.")
    }
    if joined.contains("ssh") || joined.contains("credential") || joined.contains("sensitive") {
        out.append("Denied — leave credential and key files alone. Use environment variables or a secrets manager instead.")
    }
    if joined.contains("dependency") {
        out.append("Denied — don't add a dependency without asking. Justify it and pin the exact version first.")
    }
    if joined.contains("delete") || joined.contains("rm ") || joined.contains("force") {
        out.append("Denied — don't run destructive commands. Move to trash or stage the change so it's reversible.")
    }
    if joined.contains("upload") || joined.contains("exfil") || joined.contains("socket") {
        out.append("Denied — don't send local files off the machine.")
    }

    out.append(contentsOf: genericSteerReasons)
    // De-dup, keep order, cap for the menu.
    var seen = Set<String>()
    return out.filter { seen.insert($0).inserted }.prefix(6).map { $0 }
}
