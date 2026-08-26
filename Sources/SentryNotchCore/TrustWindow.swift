import Foundation

/// A time-boxed auto-approval — "trust reads in this repo for the next 5
/// minutes" — that expires on its own. It cuts approval fatigue during a focused
/// stretch without leaving a permanent grant behind: unlike an Always-Allow
/// rule or a session bypass, it evaporates when the clock runs out.
///
/// Scope still outranks it, exactly like the other convenience grants: the
/// caller only consults a trust window when the call is in scope, so a window
/// can never wave through an out-of-scope host.
public struct TrustWindow: Identifiable, Sendable, Equatable {
    public enum Tier: String, Sendable, Codable { case readOnly, all }

    public let id: UUID
    /// The project directory this applies to; empty means every project.
    public let cwd: String
    public let tier: Tier
    public let expiresAt: Date
    /// Project name for display.
    public let label: String

    public init(id: UUID = UUID(), cwd: String, tier: Tier, expiresAt: Date, label: String) {
        self.id = id
        self.cwd = cwd
        self.tier = tier
        self.expiresAt = expiresAt
        self.label = label
    }

    public func active(now: Date) -> Bool { now < expiresAt }
    public func remaining(now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    /// Whether this window auto-approves the given call right now. A read-only
    /// window covers only read-only tools; an `.all` window covers any tool.
    public func covers(cwd: String, tool: String, now: Date) -> Bool {
        guard active(now: now) else { return false }
        if !self.cwd.isEmpty && self.cwd != cwd { return false }
        switch tier {
        case .all:      return true
        case .readOnly: return toolTier(tool) == .readOnly
        }
    }
}
