import Foundation
import SentryNotchCore

/// Reads `git status` for the directories your sessions are working in.
///
/// The failure mode this exists to catch: an agent edits half a dozen files you
/// never looked at, and you only find out when something breaks later. Seeing
/// "12 changed" next to a session while it works is the cheapest possible
/// warning.
///
/// Deliberately throttled and off the main thread. `git status` on a large
/// repository is not free, and this runs for every active project — polling it
/// on the 1s app tick would burn CPU continuously for information that changes
/// slowly.
@MainActor
final class RepoMonitor: ObservableObject {
    @Published private(set) var states: [String: RepoState] = [:]   // cwd → state

    /// How stale a reading may get before it is refreshed.
    private let ttl: TimeInterval = 12
    private var lastRead: [String: Date] = [:]
    private var inFlight: Set<String> = []

    /// Refresh anything stale among the given working directories. Safe to call
    /// on every tick — it does nothing until a reading actually ages out.
    func refresh(cwds: [String]) {
        let now = Date()
        // Drop directories we no longer track, so the dictionary doesn't grow
        // for the lifetime of the process.
        let live = Set(cwds)
        states = states.filter { live.contains($0.key) }
        lastRead = lastRead.filter { live.contains($0.key) }

        for cwd in live where !inFlight.contains(cwd) {
            if let last = lastRead[cwd], now.timeIntervalSince(last) < ttl { continue }
            inFlight.insert(cwd)
            lastRead[cwd] = now
            Self.read(cwd) { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.inFlight.remove(cwd)
                    if let state { self.states[cwd] = state }
                    else { self.states.removeValue(forKey: cwd) }
                }
            }
        }
    }

    func state(for cwd: String) -> RepoState? { states[cwd] }

    /// One `git status --porcelain -b`, parsed. Returns nil when the path isn't
    /// a repository, which is the common case for scratch directories.
    private static func read(_ cwd: String, _ done: @escaping (RepoState?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
                  isDir.boolValue else { done(nil); return }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // --porcelain=v1 keeps the format stable across git versions;
            // -b puts the branch on the first line so this is a single call.
            p.arguments = ["git", "-C", cwd, "status", "--porcelain=v1", "-b",
                           "--untracked-files=normal"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            // Inherit no environment beyond PATH: a repo-local hook or alias
            // shouldn't be able to influence a status read we run in the
            // background.
            p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

            do { try p.run() } catch { done(nil); return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { done(nil); return }   // not a repo
            done(parseGitStatus(String(decoding: data, as: UTF8.self)))
        }
    }

}
