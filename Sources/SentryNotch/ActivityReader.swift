import Foundation

/// One line in a session's activity feed.
struct ActivityItem: Identifiable {
    enum Kind { case user, assistant, tool, result }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Reads the recent activity of a single session transcript — what the agent
/// has been saying and doing — for the expanded card view.
enum ActivityReader {
    static func recent(path: String, limit: Int = 20, maxBytes: Int = 256 * 1024) -> [ActivityItem] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // drop partial first line

        var items: [ActivityItem] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any] else { continue }

            switch type {
            case "user":
                if let s = message["content"] as? String, !s.isEmpty {
                    items.append(.init(kind: .user, text: s))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for b in blocks where (b["type"] as? String) == "tool_result" {
                        items.append(.init(kind: .result, text: toolResultText(b)))
                    }
                }
            case "assistant":
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty {
                            items.append(.init(kind: .assistant, text: t))
                        }
                    case "tool_use":
                        items.append(.init(kind: .tool, text: toolUseText(b)))
                    default: break
                    }
                }
            default: break
            }
        }
        return Array(items.suffix(limit))
    }

    private static func toolUseText(_ b: [String: Any]) -> String {
        let name = b["name"] as? String ?? "tool"
        let input = b["input"] as? [String: Any] ?? [:]
        let arg = (input["command"] as? String)
            ?? (input["file_path"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["url"] as? String)
            ?? ""
        return arg.isEmpty ? name : "\(name): \(arg)"
    }

    private static func toolResultText(_ b: [String: Any]) -> String {
        let err = (b["is_error"] as? Bool) == true
        if let s = b["content"] as? String {
            return (err ? "error: " : "") + s.replacingOccurrences(of: "\n", with: " ")
        }
        if let blocks = b["content"] as? [[String: Any]] {
            let t = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            return (err ? "error: " : "") + t.replacingOccurrences(of: "\n", with: " ")
        }
        return err ? "error" : "result"
    }
}
