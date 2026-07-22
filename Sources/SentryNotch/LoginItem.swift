import Foundation
import AppKit
import ServiceManagement
import SentryNotchCore

/// "Start when I log in", backed by `SMAppService`.
///
/// The system owns this setting, not us. It is deliberately *not* mirrored into
/// `AppSettings`: the user can turn a login item off in System Settings at any
/// time, and a cached copy would then disagree with reality and show a switch
/// that lies. Every read goes through to `SMAppService.mainApp.status`.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// Set when a register/unregister actually failed, so the UI can say what
    /// went wrong instead of silently snapping the switch back.
    @Published private(set) var failure: String?

    private var service: SMAppService { .mainApp }

    init() { refresh() }

    /// Re-read the real state. Called whenever the tab appears and when the app
    /// reactivates, because the user may have changed it in System Settings
    /// while we were in the background.
    func refresh() {
        status = service.status
    }

    var isOn: Bool { status == .enabled }

    /// macOS lets the user block login items per-app. In that state the switch
    /// must not read as "off" — off implies flipping it on would work, and it
    /// won't until the block is lifted in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        failure = nil
        do {
            if on {
                // Registering while already enabled throws; treat it as success.
                if service.status != .enabled { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    /// `SMAppService.Status` prints as a raw integer, which is no use in a
    /// support reply. Spell it out, including what the user should do about it.
    var statusDescription: String {
        switch status {
        case .enabled: return "enabled — starts at login"
        case .notRegistered: return "not registered — does not start at login"
        case .requiresApproval: return "blocked — allow it in System Settings › General › Login Items"
        case .notFound: return "not found — macOS can't see this bundle where it is"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// Non-nil when the app isn't somewhere macOS can relaunch it from.
    var locationWarning: String? {
        launchAtLoginWarning(bundlePath: Bundle.main.bundlePath,
                             home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Open the Login Items pane so an approval block can actually be cleared.
    /// Falls back to the System Settings app if the deep link ever stops
    /// resolving, which is better than a dead button.
    func openSystemSettings() {
        let deepLink = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        if let url = URL(string: deepLink), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
