import Foundation

struct UsageWindow: Identifiable {
    let id = UUID()
    let kind: String        // "5h" | "7d" | raw type
    let resetsAt: Date
    let status: String      // allowed | warning | ...
}

/// Fetch the real rate-limit reset windows. Claude Code emits `rate_limit_event`
/// only in a live stream and never persists it, so the only way to read the
/// 5h/7d reset is to make one cheap `claude` call and parse the stream. Uses
/// the Haiku alias to keep the cost minimal; on-demand only.
enum UsageProbe {
    static func run(claudePath: String, timeout: TimeInterval = 30,
                    completion: @escaping ([UsageWindow]) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["-p", "ok", "--model", "haiku",
                          "--output-format", "stream-json", "--verbose"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let handle = out.fileHandleForReading

        // All state below is touched only from the readability handler's serial
        // queue (and the `catch`, before any handler is installed). The previous
        // version appended to `data` on the read queue while the termination
        // handler read it on another — a data race on a Data value, which can
        // corrupt or crash. Detecting EOF here instead keeps every access on one
        // queue, so no lock is needed and nothing races.
        var data = Data()
        var done = false
        func finish() {
            guard !done else { return }
            done = true
            handle.readabilityHandler = nil
            let windows = parse(data)
            DispatchQueue.main.async { completion(windows) }
        }
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { finish() }     // the process closed the pipe
            else { data.append(chunk) }
        }
        do { try proc.run() } catch { finish(); return }

        // Bound it. A hung `claude` — a network stall, an auth prompt, an
        // unavailable model — would otherwise never reach EOF, leaving the
        // refresh spinner stuck forever and the process leaked (and billing).
        // terminate() closes the pipe, which delivers EOF and calls finish().
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }
        }
    }

    private static func parse(_ data: Data) -> [UsageWindow] {
        var byKind: [String: UsageWindow] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "rate_limit_event",
                  let info = obj["rate_limit_info"] as? [String: Any] else { continue }
            let type = info["rateLimitType"] as? String ?? "?"
            let resets: Double = (info["resetsAt"] as? Double) ?? Double(info["resetsAt"] as? Int ?? 0)
            guard resets > 0 else { continue }
            let w = UsageWindow(kind: label(type),
                                resetsAt: Date(timeIntervalSince1970: resets),
                                status: info["status"] as? String ?? "")
            byKind[w.kind] = w
        }
        return byKind.values.sorted { $0.kind < $1.kind }
    }

    private static func label(_ t: String) -> String {
        switch t {
        case "five_hour": return "5h"
        case "seven_day", "seven_day_oauth": return "7d"
        default: return t
        }
    }
}
