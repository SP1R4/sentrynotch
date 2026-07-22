import Foundation

/// Every user-visible name, identifier, and URL in one place.
///
/// The product name carries trademark risk (see README ▸ Trademark), so a
/// rename has to stay cheap: change these constants and the whole app, its
/// hook scripts, its state directory, and its update feed follow. Nothing
/// elsewhere in the codebase should hardcode the product name.
///
/// `slug` is the machine-safe form used for paths, the socket, the hook
/// filenames, and the settings.json marker. Changing `slug` orphans an existing
/// install's state directory — see `Brand.legacySlugs` for the migration path.
public enum Brand {
    /// Human-readable product name (menus, window titles, notifications).
    public static let name = "Sentry Notch"
    /// Machine-safe identifier: paths, socket, hook filenames, settings marker.
    public static let slug = "sentrynotch"
    /// Reverse-DNS bundle identifier. Must match the signed .app and the
    /// Developer ID cert's team, or notarization staples to nothing.
    public static let bundleID = "com.sp1r4.sentrynotch"
    /// Vendor name for copyright strings and the license issuer field.
    public static let vendor = "sp1r4"

    /// Slugs this product shipped under previously. State directories for these
    /// are migrated on first launch so an update doesn't silently lose a user's
    /// rules and license.
    /// NOTE: these are *historical* names and must never be swept up by a
    /// project-wide rename — that would silently break upgrades for every
    /// existing install. Keep them as literals, spelled out.
    public static let legacySlugs = ["xisland", "claude-notch"]

    // MARK: - URLs
    //
    // No custom domain: the site is hosted on a static host and the build is
    // served from GitHub Releases. Set `host` once and the rest follow.
    //
    // NOTE: GitHub Pages' terms prohibit sites "primarily directed at
    // facilitating commercial transactions", which a landing page with a Buy
    // button is. Cloudflare Pages is free, permits commerce, and can host the
    // licence-issuing Worker on the same account. Release binaries on GitHub
    // Releases are fine either way.
    //
    // TODO(before launch): replace with the real host and support address.
    private static let host = "sentrynotch.pages.dev"
    private static let repo = "https://github.com/sp1r4/sentrynotch"

    /// Appcast feed polled for updates. Must be HTTPS — the updater refuses
    /// plaintext so a hostile network can't offer a downgrade.
    public static let appcastURL = "https://\(host)/appcast.json"
    public static let siteURL = "https://\(host)"
    public static let privacyURL = "https://\(host)/privacy"
    /// Where the notarized DMG lives. Releases are versioned, free, and within
    /// GitHub's terms even when the storefront is elsewhere.
    public static let downloadURL = "\(repo)/releases/latest"
    /// Where the app's Support button goes. Public issue tracker: bug reports
    /// get triaged in the open, and no personal mailbox is published inside a
    /// shipped binary where it can be scraped.
    public static let supportURL = "\(repo)/issues"

    /// Private contact, used only for things that must not be public: data
    /// requests under privacy law, and licence recovery (which involves an
    /// email address and an order number). Asking someone to file a *public*
    /// issue to have their data deleted would defeat the point. Referenced by
    /// PRIVACY.md and the EULA, not surfaced in the app's UI.
    public static let contactEmail = "sp1r4.work@gmail.com"

    // MARK: - Derived paths

    /// True when state has been relocated by `SENTRYNOTCH_STATE_DIR`.
    ///
    /// Callers use this to stay out of anything *global*. The hook
    /// configuration in particular lives in ~/.claude/settings.json and is
    /// shared with the user's real install, so a throwaway instance that
    /// rewrites it points the live hook at a temporary directory and takes
    /// Claude Code down.
    public static var usingCustomStateDir: Bool {
        !(ProcessInfo.processInfo.environment["SENTRYNOTCH_STATE_DIR"] ?? "").isEmpty
    }

    /// Where rules, the decision log, and the hook scripts live.
    ///
    /// Application Support, not `~/.claude/` — that directory belongs to Claude
    /// Code and its layout is not ours to depend on. Application Support is
    /// also not iCloud-synced, which matters because the decision log records
    /// commands and paths from real engagements.
    ///
    /// `SENTRYNOTCH_STATE_DIR` relocates it. The log holds real commands and
    /// project names, so screenshots and demos must not be taken against the
    /// real one — a single marketing image can publish a client's
    /// infrastructure.
    public static var stateDir: String {
        if let override = ProcessInfo.processInfo.environment["SENTRYNOTCH_STATE_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let root = base?.path ?? NSString(string: "~/Library/Application Support").expandingTildeInPath
        return "\(root)/\(displayDirName)"
    }

    /// Directory name inside Application Support.
    ///
    /// NOTE: the full path contains a space ("Application Support"), so any
    /// path derived from it must be `shellQuote`d before being embedded in a
    /// hook command. Assuming otherwise shipped a total outage once already.
    public static let displayDirName = "SentryNotch"

    public static var socketPath: String { "\(stateDir)/broker.sock" }
    public static var hookScriptPath: String { "\(stateDir)/\(slug)-hook.py" }
    public static var notifyScriptPath: String { "\(stateDir)/\(slug)-notify.py" }

    /// Substring identifying our entries in the user's settings.json, so
    /// uninstall removes exactly ours and leaves their other hooks alone.
    public static var hookMarker: String { slug }
}
