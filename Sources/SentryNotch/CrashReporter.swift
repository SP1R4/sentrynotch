import Foundation
import Darwin
import SentryNotchCore

/// Writes a local crash record so a customer can attach one to an issue.
///
/// Deliberately *not* telemetry. Nothing is transmitted: the file is written
/// beside the app's other state and stays there until the user sends it or
/// deletes it. A product sold on "your work never leaves your Mac" cannot
/// quietly start posting stack traces home the moment something breaks.
///
/// The record holds a signal number and a symbolicated backtrace — function
/// names and offsets. No command text, no file paths from the decision log, no
/// licence key. A crash in the permission broker must not become a leak of the
/// engagement it was brokering.
enum CrashReporter {
    /// Path is resolved once, at install time, and kept as a C string.
    ///
    /// A signal handler may only call async-signal-safe functions. Building a
    /// path, formatting a date, or touching Foundation inside the handler can
    /// deadlock on a lock the crashing thread already holds — turning a
    /// diagnosable crash into a hang. `open`, `write`, and
    /// `backtrace_symbols_fd` are all on the safe list.
    private static var pathBuffer: [CChar] = []
    private static var installed = false

    static var crashLogPath: String { "\(Brand.stateDir)/last-crash.log" }

    static func install() {
        guard !installed else { return }
        installed = true

        let dir = Brand.stateDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        pathBuffer = Array(crashLogPath.utf8CString)

        NSSetUncaughtExceptionHandler { exception in
            // Not a signal context, so Foundation is safe here.
            let text = """
            === \(Brand.name) uncaught exception ===
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "-")
            version: \(UpdateChecker.currentVersion)
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            CrashReporter.appendSafely(text)
        }

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(sig) { received in
                CrashReporter.writeSignal(received)
                // Restore the default handler and re-raise, so the process
                // still dies the way the system expects and macOS records its
                // own report too. Swallowing the signal would leave a wedged
                // app that looks alive but has already lost its stack.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Async-signal-safe: fixed byte writes and `backtrace_symbols_fd` only.
    private static func writeSignal(_ sig: Int32) {
        let fd = pathBuffer.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return open(base, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        guard fd >= 0 else { return }
        let header = "=== crash: signal \(sig) ===\n"
        _ = header.withCString { write(fd, $0, strlen($0)) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        _ = "\n".withCString { write(fd, $0, 1) }
        close(fd)
    }

    private static func appendSafely(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: crashLogPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: crashLogPath))
        }
    }

    /// Most recent crash record, trimmed, for the diagnostics dump.
    static func lastCrash(maxBytes: Int = 4000) -> String? {
        guard let text = try? String(contentsOfFile: crashLogPath, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text.count > maxBytes ? String(text.suffix(maxBytes)) : text
    }

    static func clear() { try? FileManager.default.removeItem(atPath: crashLogPath) }
}
