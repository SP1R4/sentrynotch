import Foundation

/// Reconstructing what an agent did, from the audit log — a scrubbable timeline
/// per project. The heavy lifting is UI; these are the pure pieces so the
/// grouping and stats are testable.

public struct TimelineSummary: Sendable, Equatable {
    public let total: Int
    public let denied: Int
    public let highRisk: Int
    public let firstTS: String
    public let lastTS: String
}

/// The distinct projects present in a set of activity entries, for the picker.
public func timelineProjects(_ entries: [ActivityEntry]) -> [String] {
    Array(Set(entries.map(\.project)).subtracting([""])).sorted()
}

/// A project's entries in chronological order — the order things actually
/// happened, which is how you replay them.
public func timeline(for project: String, in entries: [ActivityEntry]) -> [ActivityEntry] {
    entries.filter { $0.project == project }.sorted { $0.ts < $1.ts }
}

/// Headline stats for a project's timeline.
public func summarizeTimeline(_ entries: [ActivityEntry]) -> TimelineSummary {
    let sorted = entries.sorted { $0.ts < $1.ts }
    let denied = entries.filter { $0.decision.hasPrefix("deny") }.count
    let high = entries.filter { isHighRisk($0.risk) }.count
    return TimelineSummary(total: entries.count, denied: denied, highRisk: high,
                           firstTS: sorted.first?.ts ?? "", lastTS: sorted.last?.ts ?? "")
}

/// Indices (into a chronological timeline) of the high-risk moments, so the UI
/// can jump between the parts worth scrutinising.
public func highRiskMarkers(_ entries: [ActivityEntry]) -> [Int] {
    entries.enumerated().compactMap { isHighRisk($0.element.risk) ? $0.offset : nil }
}
