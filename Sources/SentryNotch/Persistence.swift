import Foundation
import CryptoKit
import SentryNotchCore

/// Persisted Always-Allow rules and bypassed sessions, so they survive an app
/// restart instead of silently re-prompting.
struct RuleStore {
    private let path: String

    init(dir: String) { self.path = "\(dir)/rules.json" }

    struct State: Codable {
        var alwaysAllow: [String] = []
        var bypassSessions: [String] = []
        var autoAllowReadOnly: Bool? = true
        var failClosedRisky: Bool? = true
        /// Persisted so a deliberate "off" survives a restart. Previously this
        /// lived only in memory, so the switch silently reset on every launch.
        var interceptEnabled: Bool? = true
        /// cwd → ProjectPolicy.rawValue for the non-default entries only.
        var projectPolicy: [String: String]? = nil
        var interceptNewSessions: Bool? = true
        /// sessionID → SessionArming.rawValue for the non-default entries only.
        var sessionArming: [String: String]? = nil

        init() {}

        init(alwaysAllow: [String], bypassSessions: [String], autoAllowReadOnly: Bool?,
             failClosedRisky: Bool?, projectPolicy: [String: String]?,
             interceptEnabled: Bool?, interceptNewSessions: Bool?,
             sessionArming: [String: String]?) {
            self.alwaysAllow = alwaysAllow
            self.bypassSessions = bypassSessions
            self.autoAllowReadOnly = autoAllowReadOnly
            self.failClosedRisky = failClosedRisky
            self.projectPolicy = projectPolicy
            self.interceptEnabled = interceptEnabled
            self.interceptNewSessions = interceptNewSessions
            self.sessionArming = sessionArming
        }

        /// Field by field, so one malformed entry doesn't discard every standing
        /// rule and posture setting. The security-relevant defaults all fail
        /// safe (armed, fail-closed), but silently dropping a user's entire
        /// rule set is still the wrong way to handle a bad byte.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alwaysAllow = (try? c.decode([String].self, forKey: .alwaysAllow)) ?? []
            bypassSessions = (try? c.decode([String].self, forKey: .bypassSessions)) ?? []
            autoAllowReadOnly = (try? c.decode(Bool.self, forKey: .autoAllowReadOnly)) ?? true
            failClosedRisky = (try? c.decode(Bool.self, forKey: .failClosedRisky)) ?? true
            interceptEnabled = (try? c.decode(Bool.self, forKey: .interceptEnabled)) ?? true
            interceptNewSessions = (try? c.decode(Bool.self, forKey: .interceptNewSessions)) ?? true
            projectPolicy = (try? c.decode([String: String].self, forKey: .projectPolicy)) ?? [:]
            sessionArming = (try? c.decode([String: String].self, forKey: .sessionArming)) ?? [:]
        }
    }

    func load() -> State {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Reconstruct a rule key for rows written before it was recorded. Mirrors
/// `ruleKey`: tool name, plus the first command token for Bash.
private func derivedKey(tool: String, summary: String) -> String {
    guard tool == "Bash" else { return tool }
    let head = summary.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
    return "Bash|\(head)"
}

/// Daily peak context tokens per session, so analytics can show a trend rather
/// than only the current instant. One line per session per day, rewritten in
/// place — the file stays small (a handful of lines a day) and needs no pruning.
struct TokenLog {
    private let path: String
    init(dir: String) { self.path = "\(dir)/tokens.jsonl" }

    /// day → session → peak tokens seen that day.
    typealias Table = [String: [String: Int]]

    func load() -> Table {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var table = Table()
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let day = o["day"] as? String, let sid = o["session"] as? String,
                  let peak = o["peak"] as? Int else { continue }
            table[day, default: [:]][sid] = peak
        }
        return table
    }

    func save(_ table: Table) {
        var lines: [String] = []
        for (day, sessions) in table.sorted(by: { $0.key < $1.key }) {
            for (sid, peak) in sessions.sorted(by: { $0.key < $1.key }) {
                let obj: [String: Any] = ["day": day, "session": sid, "peak": peak]
                if let d = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: d, encoding: .utf8) { lines.append(s) }
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(
            toFile: path, atomically: true, encoding: .utf8)
    }

    /// Per-day totals: the sum of each session's peak that day.
    static func dailyTotals(_ table: Table) -> [Tally] {
        table.map { Tally(name: $0.key, count: $0.value.values.reduce(0, +)) }
            .sorted { $0.name < $1.name }
    }
}

/// Append-only audit trail of every permission decision. One JSON object per
/// line — greppable, and aligned with the user's audit-first hook setup.
/// `Sendable` so the dashboard can read it off the main actor. Every stored
/// property is immutable and the file work is done through the FileManager,
/// which is safe to call from any thread.
struct AuditLog: Sendable {
    private let path: String
    private let dir: String
    private let queue = DispatchQueue(label: "sentrynotch.audit")
    /// Per-install HMAC key for the tamper-evidence chain, and the running MAC
    /// of the most recent record. Both are only ever touched on `queue`.
    private let key: SymmetricKey
    private let chain: ChainState

    /// Running chain head. A reference type so the value-type `AuditLog` can
    /// update it from the write queue; guarded by that queue, hence unchecked.
    final class ChainState: @unchecked Sendable {
        var lastMAC: String
        init(_ v: String) { lastMAC = v }
    }

    /// Rotate once the live file passes this. At roughly 530 bytes a decision
    /// that is ~9,000 records per file — enough that most users never rotate,
    /// small enough that reading one file is never slow.
    static let maxBytes = 5 * 1024 * 1024
    static let stem = "decisions"

    init(dir: String) {
        self.dir = dir
        self.path = "\(dir)/\(Self.stem).jsonl"
        self.key = Self.loadOrCreateKey(dir: dir)
        // Resume the chain from the most recent MAC on disk so appends after a
        // restart link to the prior record rather than restarting the chain.
        self.chain = ChainState(auditGenesis)
        self.chain.lastMAC = lastMACOnDisk() ?? auditGenesis
    }

    /// Load the per-install MAC key, or mint one and store it 0600. A key file
    /// beside the log is the pragmatic choice for an unsigned app with no
    /// Keychain entitlement; the threat model in AuditChain.swift says what that
    /// does and doesn't buy.
    private static func loadOrCreateKey(dir: String) -> SymmetricKey {
        let path = "\(dir)/audit.key"
        if let data = FileManager.default.contents(atPath: path), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        FileManager.default.createFile(atPath: path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        return key
    }

    /// The MAC of the newest record on disk, scanning newest file first, or nil
    /// for a fresh or pre-chain log.
    private func lastMACOnDisk() -> String? {
        for file in logPaths() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let mac = o["mac"] as? String, !mac.isEmpty {
                    return mac
                }
            }
        }
        return nil
    }

    /// Archive filenames present on disk, newest-first order applied by caller.
    private func archiveNames() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return all.filter { logArchiveIndex($0, stem: Self.stem) != nil }
    }

    /// Every log file, newest-first, live file included.
    private func logPaths() -> [String] {
        orderedLogFiles(stem: Self.stem, archives: archiveNames()).map { "\(dir)/\($0)" }
    }

    /// Move the live file aside once it grows past the cap.
    ///
    /// Archives are never deleted. This is an audit trail: a tool that quietly
    /// discards the record of what an agent was allowed to do — precisely the
    /// evidence someone would go looking for after an incident — is worse than
    /// one that uses disk. Rotation exists to bound how much has to be *read*,
    /// not to bound what is kept. Old archives are plain files the user can
    /// archive or delete on their own terms.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size >= Self.maxBytes else { return }
        let index = nextArchiveIndex(stem: Self.stem, archives: archiveNames())
        let dest = "\(dir)/\(Self.stem).\(index).jsonl"
        do {
            try fm.moveItem(atPath: path, toPath: dest)
            NSLog("\(Brand.name): rotated decision log to \(Self.stem).\(index).jsonl")
        } catch {
            // Appending to an oversized file beats losing the record.
            NSLog("\(Brand.name): could not rotate decision log: \(error)")
        }
    }

    /// The island history view and the dashboard activity list read the same
    /// rows; the type lives in Core so the filtering over it can be tested.
    typealias Entry = ActivityEntry

    /// Every recorded decision, flattened for the analytics summariser.
    ///
    /// Bounded: reads newest-first across rotated files and stops once `limit`
    /// rows are in hand. Without a cap this grew with the log forever, on the
    /// main thread, on every dashboard open.
    func rows(limit: Int = 50_000) -> [DecisionRow] {
        // Read lazily: stop opening files once enough rows are in hand.
        var chunks: [[DecisionRow]] = []
        var have = 0
        for file in logPaths() {
            guard have < limit,
                  let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let rows = parseRows(text)
            chunks.append(rows)
            have += rows.count
        }
        return newestAcrossFiles(chunks, limit: limit)
    }

    private func parseRows(_ text: String) -> [DecisionRow] {
        text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return nil }
            let ts = obj["ts"] as? String ?? ""
            return DecisionRow(
                decision: obj["decision"] as? String ?? "",
                tool: obj["tool"] as? String ?? "",
                project: ((obj["cwd"] as? String ?? "") as NSString).lastPathComponent,
                risk: obj["risk"] as? String ?? "",
                day: String(ts.prefix(10)),   // ISO8601 → yyyy-MM-dd
                // Older rows predate the key; reconstruct it the same way
                // ruleKey does so historical data still groups.
                key: (obj["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                     ?? derivedKey(tool: obj["tool"] as? String ?? "",
                                   summary: obj["summary"] as? String ?? ""))
        }
    }

    /// Read the most recent decisions, newest first, for the history view.
    ///
    /// Walks rotated files only as far as `limit` requires, so a large history
    /// costs the same as a small one.
    func recent(limit: Int = 200) -> [Entry] {
        var out: [Entry] = []
        for file in logPaths() where out.count < limit {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            appendEntries(from: text, into: &out, limit: limit)
        }
        return out
    }

    private func appendEntries(from text: String, into out: inout [Entry], limit: Int) {
        for line in text.split(separator: "\n").reversed() {
            guard out.count < limit,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            out.append(Entry(
                ts: obj["ts"] as? String ?? "",
                decision: obj["decision"] as? String ?? "",
                tool: obj["tool"] as? String ?? "",
                summary: obj["summary"] as? String ?? "",
                project: (cwd as NSString).lastPathComponent,
                cwd: cwd,
                risk: obj["risk"] as? String ?? "",
                key: obj["key"] as? String ?? ""))
        }
    }

    func record(decision: String, toolName: String, summary: String,
                sessionID: String, cwd: String, riskLevel: String, key ruleKey: String = "") {
        let ts = ISO8601DateFormatter().string(from: Date())
        let sum = String(summary.prefix(2000))
        let fields = AuditFields(ts: ts, decision: decision, tool: toolName, summary: sum,
                                 sessionID: sessionID, cwd: cwd, risk: riskLevel, key: ruleKey)
        queue.async {
            // Checked on the write queue so the size test and the append can't
            // interleave with another writer — and so the chain head advances
            // in strict write order.
            rotateIfNeeded()
            let mac = auditMAC(key: self.key, prevMAC: self.chain.lastMAC, fields: fields)
            let entry: [String: Any] = [
                "key": ruleKey, "ts": ts, "decision": decision, "tool": toolName,
                "summary": sum, "session_id": sessionID, "cwd": cwd, "risk": riskLevel,
                "mac": mac,
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
            data.append(0x0A)
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            // Advance the chain head only after the record is on disk.
            self.chain.lastMAC = mac
        }
    }

    /// Verify the tamper-evidence chain over the whole log. Reads oldest→newest
    /// across rotated files and recomputes every MAC. Records without a MAC
    /// (written before the chain existed) are counted separately, not treated as
    /// a break. Off the main thread — the caller hops back for the UI.
    func verify() -> (result: AuditVerification, legacy: Int) {
        var records: [(fields: AuditFields, storedMAC: String)] = []
        var legacy = 0
        for file in logPaths().reversed() {   // oldest file first
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                else { continue }
                guard let mac = o["mac"] as? String, !mac.isEmpty else { legacy += 1; continue }
                let f = AuditFields(
                    ts: o["ts"] as? String ?? "", decision: o["decision"] as? String ?? "",
                    tool: o["tool"] as? String ?? "", summary: o["summary"] as? String ?? "",
                    sessionID: o["session_id"] as? String ?? "", cwd: o["cwd"] as? String ?? "",
                    risk: o["risk"] as? String ?? "", key: o["key"] as? String ?? "")
                records.append((f, mac))
            }
        }
        return (verifyAuditChain(records, key: key), legacy)
    }

    /// The current chain head, for anchoring off-box (an engagement record, a
    /// message to yourself) so adversarial rewrites of the whole log are caught.
    func headMAC() -> String { chain.lastMAC }
}
