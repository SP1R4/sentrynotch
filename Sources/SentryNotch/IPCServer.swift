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
