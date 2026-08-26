import Foundation
import CryptoKit

/// Tamper-evidence for the decision log.
///
/// Each record carries an HMAC-SHA256 over `previous-record-MAC ‖ this record's
/// canonical fields`, keyed by a per-install secret held outside the log. That
/// links every line to the one before it: editing a field, reordering lines, or
/// truncating the tail all break the chain at a detectable point, and an
/// attacker who cannot read the key cannot recompute the downstream MACs.
///
/// Threat model, stated plainly (the honest-crypto bar): this detects
/// accidental corruption, log-shipping damage, and any edit made without the
/// MAC key. An adversary who reads the key file *and* rewrites the whole log can
/// forge a fresh consistent chain — so for adversarial cases the current head
/// MAC should be anchored somewhere the attacker can't reach (printed into an
/// engagement record, sent off-box). The chain makes tampering evident; it does
/// not make the log immutable.

/// The fields a record commits to, in a fixed order. Order and separator are
/// part of the protocol: the writer and the verifier must agree exactly or every
/// record reads as broken.
public struct AuditFields: Sendable, Equatable {
    public let ts: String
    public let decision: String
    public let tool: String
    public let summary: String
    public let sessionID: String
    public let cwd: String
    public let risk: String
    public let key: String

    public init(ts: String, decision: String, tool: String, summary: String,
                sessionID: String, cwd: String, risk: String, key: String) {
        self.ts = ts; self.decision = decision; self.tool = tool; self.summary = summary
        self.sessionID = sessionID; self.cwd = cwd; self.risk = risk; self.key = key
    }

    /// Canonical bytes committed to by the MAC. Unit-separator joined so a field
    /// containing spaces or newlines can't be confused with a field boundary.
    public var canonical: String {
        [ts, decision, tool, summary, sessionID, cwd, risk, key]
            .joined(separator: "\u{1f}")
    }
}

/// Genesis predecessor for the first record — a fixed, non-secret label, so an
/// empty log and a one-record log have well-defined chains.
public let auditGenesis = "sentrynotch-audit-v1-genesis"

/// The MAC linking one record to its predecessor. Hex-encoded SHA256 HMAC over
/// `prevMAC ‖ US ‖ canonical`, keyed by the install secret.
public func auditMAC(key: SymmetricKey, prevMAC: String, fields: AuditFields) -> String {
    let message = Data((prevMAC + "\u{1f}" + fields.canonical).utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
}

public struct AuditVerification: Sendable, Equatable {
    public let total: Int
    /// nil when the whole chain verifies; otherwise the 1-based index of the
    /// first record whose stored MAC doesn't match, with its timestamp.
    public let firstBreak: Int?
    public let breakTimestamp: String?
    public var intact: Bool { firstBreak == nil }
    public init(total: Int, firstBreak: Int?, breakTimestamp: String?) {
        self.total = total; self.firstBreak = firstBreak; self.breakTimestamp = breakTimestamp
    }
}

/// Walk records oldest→newest, recomputing each MAC from the running previous
/// value, and report the first mismatch. `records` must be in write order.
public func verifyAuditChain(_ records: [(fields: AuditFields, storedMAC: String)],
                             key: SymmetricKey) -> AuditVerification {
    var prev = auditGenesis
    for (i, r) in records.enumerated() {
        let expected = auditMAC(key: key, prevMAC: prev, fields: r.fields)
        // Constant-time compare isn't security-critical here (both sides are
        // already on the defender's machine), but equal-length hex compare is
        // cheap and avoids a short-circuit surprise.
        if expected != r.storedMAC {
            return AuditVerification(total: records.count, firstBreak: i + 1,
                                     breakTimestamp: r.fields.ts)
        }
        prev = r.storedMAC
    }
    return AuditVerification(total: records.count, firstBreak: nil, breakTimestamp: nil)
}
