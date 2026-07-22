import Foundation

/// A single line in a rendered diff/preview.
public struct DiffLine: Identifiable, Sendable {
    public enum Kind: Sendable { case added, removed, context }
    public let id = UUID()
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Structured view of a tool call for the permission card.
public enum ToolDetail: Sendable {
    case command(String)
    case diff(path: String, lines: [DiffLine])
    case write(path: String, content: String)
    case text(String)
}

/// Turn a tool name + raw input into something worth showing before approval.
public func toolDetail(toolName: String, input: [String: Any]) -> ToolDetail {
    switch toolName {
    case "Bash":
        return .command((input["command"] as? String) ?? "")

    case "Write":
        let path = (input["file_path"] as? String) ?? ""
        let content = (input["content"] as? String) ?? ""
        return .write(path: path, content: content)

    case "Edit":
        let path = (input["file_path"] as? String) ?? ""
        let old = (input["old_string"] as? String) ?? ""
        let new = (input["new_string"] as? String) ?? ""
        return .diff(path: path, lines: lineDiff(old: old, new: new))

    case "MultiEdit":
        let path = (input["file_path"] as? String) ?? ""
        var lines: [DiffLine] = []
        if let edits = input["edits"] as? [[String: Any]] {
            for (i, e) in edits.enumerated() {
                if i > 0 { lines.append(DiffLine(kind: .context, text: "…")) }
                lines += lineDiff(old: (e["old_string"] as? String) ?? "",
                                  new: (e["new_string"] as? String) ?? "")
            }
        }
        return .diff(path: path, lines: lines)

    case "NotebookEdit":
        let path = (input["notebook_path"] as? String) ?? ""
        return .diff(path: path, lines: lineDiff(old: (input["old_source"] as? String) ?? "",
                                                 new: (input["new_source"] as? String) ?? ""))

    default:
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            return .text(s)
        }
        return .text("")
    }
}

/// Naive block diff: removed old lines, then added new lines. Not an LCS — for
/// a permission preview, showing exactly what's being swapped is enough.
public func lineDiff(old: String, new: String) -> [DiffLine] {
    let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

    // Trim a shared prefix/suffix so unchanged context isn't shown as churn.
    var lo = 0
    while lo < oldLines.count, lo < newLines.count, oldLines[lo] == newLines[lo] { lo += 1 }
    var ho = oldLines.count, hn = newLines.count
    while ho > lo, hn > lo, oldLines[ho - 1] == newLines[hn - 1] { ho -= 1; hn -= 1 }

    var lines: [DiffLine] = []
    if lo > 0 { lines.append(DiffLine(kind: .context, text: "…")) }
    for i in lo..<ho { lines.append(DiffLine(kind: .removed, text: oldLines[i])) }
    for i in lo..<hn { lines.append(DiffLine(kind: .added, text: newLines[i])) }
    if ho < oldLines.count || hn < newLines.count {
        lines.append(DiffLine(kind: .context, text: "…"))
    }
    return lines
}
