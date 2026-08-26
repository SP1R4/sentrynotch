import Foundation
import SentryNotchCore

/// A pending tool-permission request delivered by the hook over the socket.
/// Exactly one of `respond` fires; further calls are ignored.
final class PermissionRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let cwd: String
    let toolName: String
    let toolInput: [String: Any]
    let terminal: String?
    let terminalPID: Int32?
    let claudePID: Int32?
    let receivedAt = Date()
    /// Auto-defer a little before the hook's own socket wait (280s) elapses.
    let deadline = Date().addingTimeInterval(255)

    private let fd: Int32
    private let lock = NSLock()
    private var answered = false

    let isDemo: Bool

    init(fd: Int32, json: [String: Any]) {
        self.fd = fd
        self.isDemo = false
        self.sessionID = json["session_id"] as? String ?? ""
        self.cwd = json["cwd"] as? String ?? ""
        self.toolName = json["tool_name"] as? String ?? "?"
        self.toolInput = json["tool_input"] as? [String: Any] ?? [:]
        self.terminal = json["terminal"] as? String
        if let pid = json["terminal_pid"] as? Int { self.terminalPID = Int32(pid) }
        else { self.terminalPID = nil }
        if let pid = json["claude_pid"] as? Int { self.claudePID = Int32(pid) }
        else { self.claudePID = nil }
    }

    /// A synthetic prompt (no real socket) so the approval UI can be seen and
    /// clicked without waiting for a live session. `respond` is a harmless no-op.
    init(demoToolName: String, input: [String: Any], cwd: String, terminal: String?) {
        self.fd = -1
        self.isDemo = true
        self.sessionID = "demo"
        self.cwd = cwd
        self.toolName = demoToolName
        self.toolInput = input
        self.terminal = terminal
        self.terminalPID = nil
        self.claudePID = nil
        self.answered = true   // nothing to write back
    }

    // Computed once, not per access. These were plain computed properties, but
    // the collapsed-notch mascot re-reads `risk` inside a TimelineView that
    // ticks every 0.09s — so a full risk analysis (and, via scopeFlags, two
    // regex compilations) ran ~11x a second per pending prompt. The inputs are
    // immutable, so caching is safe. Main-thread access only, which is where
    // both the UI and the decision path live.
    lazy var detail: ToolDetail = toolDetail(toolName: toolName, input: toolInput)
    lazy var risk: RiskReport = analyzeRisk(toolName: toolName, input: toolInput, cwd: cwd)
    /// Read-only "what will this actually do" preview for a Bash command: the
    /// pure classification notes plus a real filesystem expansion of any `rm`
    /// targets. Lazy — the FileManager walk is skipped until the card shows it.
    lazy var preflight: [PreflightNote] = computePreflight()

    /// Human-readable one-liner for the tool call (command, file path, etc.).
    /// Lazy because the fallback branch serialises the whole input to JSON.
    lazy var summary: String = {
        if let cmd = toolInput["command"] as? String { return cmd }
        if let path = toolInput["file_path"] as? String { return path }
        if let url = toolInput["url"] as? String { return url }
        if let data = try? JSONSerialization.data(withJSONObject: toolInput),
           let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }()

    // MARK: - Pre-flight

    private func computePreflight() -> [PreflightNote] {
        guard toolName == "Bash", let cmd = toolInput["command"] as? String else { return [] }
        var notes = preflightNotes(command: cmd)
        let targets = removalTargets(command: cmd)
        if !targets.isEmpty { notes += removalPreview(targets: targets, cwd: cwd) }
        return notes
    }

    /// Expand rm targets against the filesystem (read-only) and summarise what a
    /// deletion would remove — count, a few sample paths, and whether any land
    /// outside the working directory or in a sensitive location. Bounded so a
    /// glob over a huge tree can't stall the card.
    private func removalPreview(targets: [String], cwd: String) -> [PreflightNote] {
        let fm = FileManager.default
        let cap = 5000
        var total = 0, capped = false, outside = 0, sensitive = 0
        var sample: [String] = []

        for t in targets {
            if capped { break }
            for path in resolveTarget(t, cwd: cwd, fm: fm) {
                if total >= cap { capped = true; break }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue, let en = fm.enumerator(atPath: path) {
                    var n = 1
                    while en.nextObject() != nil { n += 1; if total + n >= cap { capped = true; break } }
                    total += n
                } else {
                    total += 1
                }
                if sample.count < 4 { sample.append(abbrevPath(path)) }
                if !isInsideDir(path, cwd) { outside += 1 }
                if pathLooksSensitive(path) { sensitive += 1 }
            }
        }

        guard total > 0 else { return [] }
        var notes: [PreflightNote] = []
        let count = capped ? "\(cap)+ items" : "\(total) item\(total == 1 ? "" : "s")"
        let more = sample.count < total ? ", …" : ""
        notes.append(.init(total > 50 ? .caution : .info,
            "would delete \(count): \(sample.joined(separator: ", "))\(more)"))
        if outside > 0 {
            notes.append(.init(.danger, "\(outside) target\(outside == 1 ? "" : "s") outside the working directory"))
        }
        if sensitive > 0 {
            notes.append(.init(.danger, "\(sensitive) target\(sensitive == 1 ? "" : "s") in a sensitive location"))
        }
        return notes
    }

    private func resolveTarget(_ t: String, cwd: String, fm: FileManager) -> [String] {
        var p = (t as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
        if p.contains("*") || p.contains("?") {
            // Expand only the final component's glob via a directory scan (no
            // shell). Fancier patterns fall through as a literal, which still
            // counts correctly when the path happens to exist.
            let dir = (p as NSString).deletingLastPathComponent
            let base = (p as NSString).lastPathComponent
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
            return entries.filter { globMatch(pattern: base, path: $0) }
                .map { (dir as NSString).appendingPathComponent($0) }
        }
        return fm.fileExists(atPath: p) ? [p] : []
    }

    private func isInsideDir(_ path: String, _ dir: String) -> Bool {
        guard !dir.isEmpty else { return true }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let d = URL(fileURLWithPath: dir).standardizedFileURL.path
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    private func pathLooksSensitive(_ p: String) -> Bool {
        let l = (p as NSString).expandingTildeInPath
        return ["/.ssh/", "/.aws/", "/.gnupg/", "/.config/gcloud/", "/etc/",
                "id_rsa", ".env", "credentials", "/.claude/"].contains { l.contains($0) }
    }

    private func abbrevPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// decision ∈ {"allow","deny","ask"}. Writes the reply and closes the fd.
    func respond(_ decision: String, reason: String = "") {
        lock.lock()
        defer { lock.unlock() }
        guard !answered else { return }
        answered = true
        let payload: [String: Any] = ["decision": decision, "reason": reason]
        if var data = try? JSONSerialization.data(withJSONObject: payload) {
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                _ = write(fd, raw.baseAddress, raw.count)
            }
        }
        close(fd)
    }

    /// Last-resort backstop.
    ///
    /// The hook blocks on this socket for 280 seconds. Every code path today
    /// answers or abandons, but if one ever fails to, the agent stalls for the
    /// full timeout with no indication why. Closing on deallocation turns that
    /// worst case into an immediate fail-open, which is the behaviour the whole
    /// design promises.
    deinit {
        if !answered { close(fd) }
    }

    /// Close without answering (e.g. app shutting down) — hook fails open.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        guard !answered else { return }
        answered = true
        close(fd)
    }
}

/// A lifecycle event (session finished / needs input) from the Stop or
/// Notification hook. Fire-and-forget — no response expected.
struct SessionEvent {
    let kind: String        // "stop" | "notification"
    let sessionID: String
    let cwd: String
    let message: String
}

/// Unix-domain socket server. A connection carries either a permission request
/// (fd held open until answered) or a fire-and-forget lifecycle event.
final class IPCServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "sentrynotch.ipc", attributes: .concurrent)

    /// Both delivered on the main queue.
    var onRequest: ((PermissionRequest) -> Void)?
    var onEvent: ((SessionEvent) -> Void)?

    init(path: String) { self.path = path }

    func start() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { NSLog("sentrynotch: socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in strncpy(dst, src, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, size)
            }
        }
        guard bound == 0 else { NSLog("sentrynotch: bind() failed"); close(listenFD); return }
        chmod(path, 0o600)
        listen(listenFD, 16)
        queue.async { [weak self] in self?.acceptLoop() }
        NSLog("sentrynotch: listening on \(path)")
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { close(fd); return }
            buf.append(contentsOf: tmp[0..<n])
            if buf.count > 1 << 20 { close(fd); return }   // sanity cap
        }
        guard let nl = buf.firstIndex(of: 0x0A) else { close(fd); return }
        let line = buf.subdata(in: buf.startIndex..<nl)
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            close(fd); return
        }

        if obj["kind"] as? String == "event" {
            let event = SessionEvent(
                kind: obj["event"] as? String ?? "notification",
                sessionID: obj["session_id"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                message: obj["message"] as? String ?? "")
            close(fd)   // fire-and-forget
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            return
        }

        let request = PermissionRequest(fd: fd, json: obj)
        DispatchQueue.main.async { [weak self] in self?.onRequest?(request) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}
