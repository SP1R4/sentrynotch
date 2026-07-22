import Foundation
import SwiftUI
import AppKit
import SentryNotchCore

/// Polls a JSON appcast and reports whether a newer build exists.
///
/// Deliberately does *not* download or install anything — it surfaces a banner
/// and opens the release page in the browser. An app that brokers permission
/// decisions should not also be a silent self-replacing binary; the user
/// re-downloads a notarized build and sees Gatekeeper verify it. Sparkle is the
/// upgrade path if silent updates are wanted later, at the cost of embedding
/// and signing another framework.
///
/// The check sends no identifiers — a plain GET, no query string, no licence
/// key, so the request reveals nothing beyond "someone fetched a public file".
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date?

    struct Release: Equatable {
        let version: String
        let url: String
        let notes: String
    }

    private var timer: Timer?

    func start() {
        check()
        // Daily is plenty for a paid desktop tool and keeps the log quiet.
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func check() {
        // Refuse plaintext: a hostile network must not be able to advertise a
        // "newer" build that points at an attacker-controlled download.
        guard let url = URL(string: Brand.appcastURL), url.scheme == "https" else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String,
                  let link = obj["url"] as? String,
                  URL(string: link)?.scheme == "https" else { return }
            let notes = obj["notes"] as? String ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.lastChecked = Date()
                self.available = isNewer(version, than: Self.currentVersion)
                    ? Release(version: version, url: link, notes: notes) : nil
            }
        }.resume()
    }

    /// nonisolated: reads only `Bundle.main`, which is immutable and
    /// thread-safe. Needed from the crash handler and the diagnostics dump,
    /// neither of which runs on the main actor.
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func openReleasePage() {
        guard let r = available, let url = URL(string: r.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Numeric dotted-version comparison. `"1.10.0"` is newer than `"1.9.9"`, which
/// a string compare would get wrong.
func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
