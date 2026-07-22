import Foundation
import SentryNotchCore

struct SessionCard: Identifiable, Equatable {
    let id: String          // sessionId (transcript filename stem)
    let project: String     // human-readable project/dir name
    let cwd: String
    let transcriptPath: String
    var lastText: String    // preview of the most recent message
    var lastActivity: Date
    var isActive: Bool      // touched within the "active" window
    var terminal: String? = nil
    var bypassed: Bool = false
    var tokens: Int = 0     // approx context tokens in the last turn
    var lastTool: String? = nil
}

/// Builds the session-card list from `~/.claude/projects/**/*.jsonl`, driven by
/// FSEvents (immediate on change) plus a caller-side timer for elapsed-time.
@MainActor
final class SessionMonitor {
    var onUpdate: (([SessionCard]) -> Void)?

    private let root: String
    private let activeWindow: TimeInterval = 15 * 60
    private var watcher: FSWatcher?
    private var pending = false

    init(root: String = NSString(string: "~/.claude/projects").expandingTildeInPath) {
        self.root = root
    }

    func start() {
        scan()
        watcher = FSWatcher(path: root) { [weak self] in
            // Called on the FSEvents queue; coalesce onto main.
            Task { @MainActor in self?.coalescedScan() }
        }
        watcher?.start()
    }

    func stop() { watcher?.stop(); watcher = nil }

    /// Coalesce at 1s, not 0.2s. An agent writes its transcript continuously,
    /// so FSEvents fires constantly; at 200ms this rescanned every project up
    /// to five times a second. Session cards do not need sub-second freshness.
    private func coalescedScan() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pending = false
            self?.scan()
        }
    }

    /// Deliberately synchronous on the main thread.
    ///
    /// Moving this to a background queue and delivering via
    /// `Task { @MainActor }` was measured at 13% CPU versus 5% here: the async
    /// hop lands outside the run loop's normal batching, so every scan drove
    /// its own display cycle instead of coalescing with the 1s tick. The file
    /// reads are cheap; the redraws they triggered were not.
    private func scan() {
        onUpdate?(buildCards())
    }

    /// Parsed tail of one transcript, keyed by the file state it was read from.
    /// A transcript is append-only and typically only one of them is being
    /// written at a time, so re-parsing every file on every FSEvents burst was
    /// almost entirely wasted work: with N sessions open, N-1 of the reads
    /// returned exactly what the previous scan returned.
    private struct CachedPreview {
        let mtime: Date
        let size: UInt64
        let preview: Preview
    }
    private var previewCache: [String: CachedPreview] = [:]

    private func buildCards() -> [SessionCard] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var cards: [SessionCard] = []
        let now = Date()

        for dir in projectDirs {
            let dirPath = "\(root)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if now.timeIntervalSince(mtime) > activeWindow { continue }

                let sessionID = (file as NSString).deletingPathExtension
                let size = (attrs[.size] as? UInt64) ?? 0

                // Reuse the parse when neither the timestamp nor the length has
                // moved. Both are checked: a same-second rewrite that changes
                // length still invalidates, and so does a length-preserving
                // touch.
                let preview: Preview
                if let hit = previewCache[filePath], hit.mtime == mtime, hit.size == size {
                    preview = hit.preview
                } else {
                    preview = Self.tailPreview(path: filePath)
                    previewCache[filePath] = CachedPreview(mtime: mtime, size: size, preview: preview)
                }
                cards.append(SessionCard(
                    id: sessionID,
                    project: ProjectPath.displayName(cwd: preview.cwd, encodedDir: dir),
                    cwd: ProjectPath.displayCwd(cwd: preview.cwd, encodedDir: dir),
                    transcriptPath: filePath,
                    lastText: preview.text,
                    lastActivity: mtime,
                    isActive: now.timeIntervalSince(mtime) < 60,
                    tokens: preview.tokens,
                    lastTool: preview.lastTool
                ))
            }
        }

        cards.sort { $0.lastActivity > $1.lastActivity }

        // Forget transcripts that aged out of the window, so the cache tracks
        // the session list rather than growing for the process lifetime.
        let live = Set(cards.map(\.transcriptPath))
        previewCache = previewCache.filter { live.contains($0.key) }
        return cards
    }

    struct Preview { var text = ""; var cwd: String?; var tokens = 0; var lastTool: String? }

    /// Read the tail of a transcript for preview text, cwd, token count, and the
    /// most recent tool call.
    private static func tailPreview(path: String, maxBytes: Int = 64 * 1024) -> Preview {
        var out = Preview()
        guard let handle = FileHandle(forReadingAtPath: path) else { return out }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return out }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            if out.cwd == nil, let c = obj["cwd"] as? String { out.cwd = c }
            if out.tokens == 0, let usage = usage(obj) { out.tokens = usage }
            if out.lastTool == nil, let tool = lastToolName(obj) { out.lastTool = tool }
            if out.text.isEmpty, let t = obj["type"] as? String, t == "user" || t == "assistant",
               let extracted = extractText(obj), !extracted.isEmpty {
                out.text = extracted
            }
            if !out.text.isEmpty && out.cwd != nil && out.tokens != 0 { break }
        }
        return out
    }

    private static func usage(_ obj: [String: Any]) -> Int? {
        guard let message = obj["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any] else { return nil }
        let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
        let total = keys.reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
        return total > 0 ? total : nil
    }

    private static func lastToolName(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        for b in blocks where (b["type"] as? String) == "tool_use" {
            return b["name"] as? String
        }
        return nil
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks {
            switch block["type"] as? String {
            case "text": if let t = block["text"] as? String { return t }
            case "tool_use": if let n = block["name"] as? String { return "⚙ \(n)" }
            default: break
            }
        }
        return nil
    }
}
