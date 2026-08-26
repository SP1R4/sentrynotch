import Foundation
import SentryNotchCore

/// Fire-and-forget webhook alerting. This is a best-effort off-box ping, never
/// a control path: it runs on a background URLSession, times out fast, and
/// swallows failures so it can't slow or block a permission decision.
struct AlertNotifier: Sendable {
    let url: String

    func send(_ event: AlertEvent) {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http",
              let body = event.jsonData() else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req).resume()
    }
}
