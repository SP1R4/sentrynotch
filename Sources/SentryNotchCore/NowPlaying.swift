import Foundation

/// A music app the widget can drive.
///
/// Both are controlled over AppleScript, but their dictionaries disagree in
/// four places: Spotify has `shuffling`/`repeating` booleans where Music has
/// `shuffle enabled` and a three-valued `song repeat`; Music reports durations
/// in seconds where Spotify uses milliseconds; and Music exposes no artwork URL
/// at all. The scripts below normalise all of that *in AppleScript*, so exactly
/// one parser handles both and the difference can't leak into the UI.
public enum MusicSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case spotify, appleMusic, youtube
    public var id: String { rawValue }

    public var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        // YouTube is not an app. Availability is decided by whether a
        // supported browser is open with a YouTube tab, which the controller
        // resolves against `Browser` rather than a single bundle id.
        case .youtube: return ""
        }
    }

    /// The name used in `tell application "..."`. Must match the app's own
    /// AppleScript name, which for Apple Music is "Music", not "Apple Music".
    public var appName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        case .youtube: return "YouTube"
        }
    }

    public var label: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .youtube: return "YouTube"
        }
    }

    /// Spotify serves artwork from a CDN URL; Music holds the image inside the
    /// library and has to be asked to hand over the bytes. The controller needs
    /// to know which, because one is a network fetch and one is not.
    public var artworkIsRemote: Bool { self == .spotify }
}

/// One poll's worth of player state, already normalised.
public struct NowPlaying: Equatable, Sendable {
    public var playing = false
    public var track = ""
    public var album = ""
    public var artist = ""
    public var positionMs = 0.0
    public var durationMs = 0.0
    public var volume = 70.0
    public var shuffling = false
    public var repeating = false
    /// Spotify: the artwork URL. Music: the track's persistent ID, which is
    /// stable and cheap to compare, so artwork is only re-extracted when the
    /// track actually changes.
    public var artKey = ""
    /// False when we can read what is playing but cannot drive it — a browser
    /// tab with the JavaScript bridge switched off. The UI hides transport and
    /// the scrubber rather than showing controls that quietly do nothing.
    public var controllable = true

    public init() {}
}

/// Parse the normalised ten-field reply both scripts emit.
///
/// Returns nil rather than a half-filled struct when the shape is wrong: a
/// short reply means the script didn't run properly, and showing a widget with
/// a blank title and a zeroed scrubber looks like a bug in the player rather
/// than a failed query.
///
/// Everything numeric arrives as whole milliseconds. Reals would be formatted
/// for the user's locale — a Greek or German system yields `14,70`, which
/// `Double(_:)` rejects, and every progress bar would sit at zero.
/// Parse a number, mapping NaN and infinity to zero.
private func finite(_ s: String) -> Double {
    guard let d = Double(s), d.isFinite else { return 0 }
    return d
}

public func parseNowPlaying(_ raw: String) -> NowPlaying? {
    let f = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 10 else { return nil }
    var n = NowPlaying()
    // "unknown" means the source could not report play state at all.
    n.controllable = f[0] != "unknown"
    n.playing = f[0] == "playing"
    n.track = f[1]
    n.album = f[2]
    n.artist = f[3]
    // A YouTube livestream reports duration NaN, and Double("NaN") parses
    // happily rather than failing — so a non-finite value would reach the
    // scrubber's progress division and hand SwiftUI a NaN frame, which
    // CoreGraphics rejects. Treat anything non-finite as unknown.
    n.positionMs = finite(f[4])
    n.durationMs = finite(f[5])
    n.artKey = f[6]
    n.volume = Double(f[7]).flatMap { $0.isFinite ? $0 : nil } ?? 70
    n.shuffling = f[8] == "true"
    n.repeating = f[9] == "true"
    return n
}

/// The AppleScript that produces that reply.
///
/// Variable names are deliberately unlike either app's own terminology. Short
/// names such as `st`, `ps` or `du` collide with Spotify's dictionary and fail
/// to parse inside the tell block — the script simply never runs.
public func nowPlayingScript(_ source: MusicSource) -> String {
    switch source {
    // Browser sources have no single app to tell; callers use youTubeScript,
    // which needs to know which browser holds the tab.
    case .youtube: return ""
    case .spotify:
        return """
        tell application "Spotify"
            set aTrack to current track
            set playerState to player state as string
            set posMs to (round (player position * 1000))
            return playerState & "\\n" & (name of aTrack) & "\\n" & (album of aTrack) ¬
                & "\\n" & (artist of aTrack) & "\\n" & posMs & "\\n" & (duration of aTrack) ¬
                & "\\n" & (artwork url of aTrack) & "\\n" & (sound volume as string) ¬
                & "\\n" & (shuffling as string) & "\\n" & (repeating as string)
        end tell
        """
    case .appleMusic:
        // Both times are multiplied to milliseconds here so the parser stays
        // shared; `song repeat` collapses to a boolean because the widget only
        // draws on/off, and `persistent ID` stands in for the missing art URL.
        return """
        tell application "Music"
            set aTrack to current track
            set playerState to player state as string
            set posMs to (round (player position * 1000))
            set durMs to (round ((duration of aTrack) * 1000))
            set rep to "false"
            if (song repeat is not off) then set rep to "true"
            set shuf to "false"
            if shuffle enabled then set shuf to "true"
            return playerState & "\\n" & (name of aTrack) & "\\n" & (album of aTrack) ¬
                & "\\n" & (artist of aTrack) & "\\n" & posMs & "\\n" & durMs ¬
                & "\\n" & (persistent ID of aTrack) & "\\n" & (sound volume as string) ¬
                & "\\n" & shuf & "\\n" & rep
        end tell
        """
    }
}

/// Write the current track's artwork to `path`, for sources with no art URL.
///
/// Guarded on the artwork actually existing: asking for `artwork 1` of a track
/// that has none is a script error, which would otherwise be reported as a
/// failed query and blank the whole widget over a missing image.
public func artworkDumpScript(_ source: MusicSource, path: String) -> String? {
    guard source == .appleMusic else { return nil }
    return """
    tell application "Music"
        if (count of artworks of current track) is 0 then return "none"
        set d to raw data of artwork 1 of current track
    end tell
    set p to POSIX file "\(appleScriptQuote(path))"
    set fh to open for access p with write permission
    set eof fh to 0
    write d to fh
    close access fh
    return "ok"
    """
}

/// Escape a string for embedding in an AppleScript double-quoted literal.
///
/// The artwork path comes from `NSTemporaryDirectory()`, which honours the
/// `TMPDIR` environment variable — so it is not fully under our control. A
/// quote in that path would close the literal early and let the remainder be
/// read as AppleScript. Same class of defect as interpolating an unquoted path
/// into a shell command, which took the hook down; worth closing here rather
/// than relying on temp paths staying well-behaved.
public func appleScriptQuote(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Transport verbs, which also differ between the two dictionaries.
public func transportScript(_ source: MusicSource, _ verb: TransportVerb) -> String {
    let body: String
    switch (source, verb) {
    case (_, .playPause):        body = "playpause"
    case (_, .next):             body = "next track"
    case (_, .previous):         body = "previous track"
    case (.spotify, .setShuffle(let on)):   body = "set shuffling to \(on)"
    case (.appleMusic, .setShuffle(let on)): body = "set shuffle enabled to \(on)"
    case (.spotify, .setRepeat(let on)):    body = "set repeating to \(on)"
    // Music has no boolean here; "all" is the sane counterpart to off.
    case (.appleMusic, .setRepeat(let on)): body = "set song repeat to \(on ? "all" : "off")"
    case (_, .seek(let seconds)):
        body = "set player position to \(String(format: "%.3f", seconds))"
    case (_, .setVolume(let v)):
        body = "set sound volume to \(Int(v))"
    case (.youtube, _):
        return ""   // driven by youTubeTransportScript
    }
    return "tell application \"\(source.appName)\" to \(body)"
}

public enum TransportVerb: Equatable, Sendable {
    case playPause, next, previous
    case setShuffle(Bool), setRepeat(Bool)
    case seek(Double), setVolume(Double)
}

/// Which player the widget should follow.
///
/// Someone with both installed usually has one actually playing and the other
/// merely open, so "is playing" beats "is running". `preference` pins a choice
/// and skips the guessing entirely; `last` keeps a paused player selected
/// rather than flipping to whichever other app happens to be open, which would
/// make the widget change identity while the user is looking at it.
public func pickSource(preference: MusicSource?,
                       running: Set<MusicSource>,
                       playing: Set<MusicSource>,
                       last: MusicSource?) -> MusicSource? {
    if let preference { return running.contains(preference) ? preference : nil }
    if let last, playing.contains(last) { return last }
    // Deterministic order so two idle-but-playing apps don't alternate between
    // polls; Spotify first only because it is the more common pairing.
    for s in MusicSource.allCases where playing.contains(s) { return s }
    if let last, running.contains(last) { return last }
    for s in MusicSource.allCases where running.contains(s) { return s }
    return nil
}

/// Just the transport state, for deciding which app to follow.
///
/// A full query only reports the app we already chose, so with both players
/// open and the selected one paused the widget would never notice the other
/// one start. This is the cheap probe that closes that gap — one word back,
/// run only while the current source isn't playing.
public func playerStateScript(_ source: MusicSource) -> String {
    "tell application \"\(source.appName)\" to return player state as string"
}

// MARK: - YouTube in a browser

/// A browser we can ask about a YouTube tab.
///
/// YouTube has no native app, so "what's playing" means "which browser has a
/// YouTube tab". Each browser is driven over AppleScript in one of two
/// dialects: Safari's, and the Chromium one shared by Chrome and its forks.
public enum Browser: String, CaseIterable, Sendable, Identifiable {
    case safari, chrome, brave, edge, arc, vivaldi, opera
    public var id: String { rawValue }

    public var bundleID: String {
        switch self {
        case .safari:  return "com.apple.Safari"
        case .chrome:  return "com.google.Chrome"
        case .brave:   return "com.brave.Browser"
        case .edge:    return "com.microsoft.edgemac"
        case .arc:     return "company.thebrowser.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera:   return "com.operasoftware.Opera"
        }
    }

    /// Name used in `tell application "…"`.
    public var appName: String {
        switch self {
        case .safari:  return "Safari"
        case .chrome:  return "Google Chrome"
        case .brave:   return "Brave Browser"
        case .edge:    return "Microsoft Edge"
        case .arc:     return "Arc"
        case .vivaldi: return "Vivaldi"
        case .opera:   return "Opera"
        }
    }

    /// Chromium forks share Chrome's scripting dictionary; Safari's differs.
    public var isChromium: Bool { self != .safari }
}

/// Reading a *page* rather than an app means the browser decides how much it
/// will tell us, and by default that is very little.
public enum YouTubeFidelity: Equatable, Sendable {
    /// The tab title only. Always available. No play state, position, or
    /// transport control — the browser exposes none of that to AppleScript.
    case titleOnly
    /// Full state via injected JavaScript. Requires the user to switch on
    /// "Allow JavaScript from Apple Events", which ships off in every browser.
    case full
}

/// Find a YouTube tab and report what is playing in it.
///
/// Deliberately narrow: the script matches YouTube URLs and returns only that
/// tab's title. It never enumerates, returns, or logs any other tab — reading
/// someone's whole browsing session would be indefensible in a tool sold on
/// keeping your work private.
///
/// The emitted shape is the same ten-field record the native players produce,
/// so `parseNowPlaying` handles all three sources without branching.
public func youTubeScript(_ browser: Browser, fidelity: YouTubeFidelity) -> String {
    // Every AppleScript property access is a separate IPC round trip, so
    // reading tabs one at a time costs 2 events per tab — unusable at a 3s poll
    // for anyone with a lot of tabs open. Fetching all URLs of a window in one
    // event and only then touching the matching tab keeps this at roughly one
    // round trip per window.
    func matchOn(_ v: String) -> String {
        "(\(v) contains \"youtube.com/watch\" or \(v) contains \"music.youtube.com\")"
    }

    switch fidelity {
    case .titleOnly:
        // Position and duration are unknown, not zero — the caller marks the
        // result uncontrollable so the UI hides the scrubber rather than
        // drawing a bar stuck at the start.
        let titleOfIndexed = browser.isChromium ? "title of tab i of w" : "name of tab i of w"
        return """
        tell application "\(browser.appName)"
            repeat with w in windows
                set us to URL of tabs of w
                repeat with i from 1 to (count of us)
                    set u to item i of us
                    if \(matchOn("u")) then
                        return "unknown" & linefeed & (\(titleOfIndexed)) & linefeed & "" ¬
                            & linefeed & "" & linefeed & "0" & linefeed & "0" ¬
                            & linefeed & u & linefeed & "70" ¬
                            & linefeed & "false" & linefeed & "false"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """

    case .full:
        // Single quotes and String.fromCharCode(10) throughout: a backslash
        // escape inside an AppleScript string literal is consumed by
        // AppleScript, so the JavaScript would arrive malformed.
        let js = "(function(){var v=document.querySelector('video');if(!v)return '';"
               + "return [v.paused?'paused':'playing',document.title,'','',"
               + "Math.round(v.currentTime*1000),Math.round(v.duration*1000),"
               + "location.href,Math.round(v.volume*100),'false',v.loop?'true':'false']"
               + ".join(String.fromCharCode(10));})()"
        let run = browser.isChromium
            ? "return execute tab i of w javascript \"\(js)\""
            : "return do JavaScript \"\(js)\" in tab i of w"
        return """
        tell application "\(browser.appName)"
            repeat with w in windows
                set us to URL of tabs of w
                repeat with i from 1 to (count of us)
                    set u to item i of us
                    if \(matchOn("u")) then
                        \(run)
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
    }
}

/// Drive playback in the YouTube tab. Only possible at `.full` fidelity —
/// without the JavaScript bridge a browser tab is read-only to us.
public func youTubeTransportScript(_ browser: Browser, _ verb: TransportVerb) -> String? {
    let body: String
    switch verb {
    case .playPause:
        body = "var v=document.querySelector('video');if(v){v.paused?v.play():v.pause();}"
    case .next:
        body = "var b=document.querySelector('.ytp-next-button');if(b)b.click();"
    case .previous:
        body = "var b=document.querySelector('.ytp-prev-button');if(b)b.click();"
    case .seek(let seconds):
        body = "var v=document.querySelector('video');if(v)v.currentTime=\(Int(seconds));"
    case .setVolume(let v):
        body = "var e=document.querySelector('video');if(e)e.volume=\(min(1, max(0, v / 100)));"
    // YouTube has no shuffle/repeat we can drive generically; the UI hides both.
    case .setShuffle, .setRepeat:
        return nil
    }
    let js = "(function(){\(body)})()"
    let run = browser.isChromium
        ? "execute t javascript \"\(js)\""
        : "do JavaScript \"\(js)\" in t"
    return """
    tell application "\(browser.appName)"
        repeat with w in windows
            repeat with t in tabs of w
                if (URL of t contains "youtube.com/watch" or URL of t contains "music.youtube.com") then
                    \(run)
                    return "ok"
                end if
            end repeat
        end repeat
    end tell
    return ""
    """
}

/// Split a YouTube page title into artist and track.
///
/// Best-effort by nature: a YouTube title is free text an uploader chose, not
/// structured metadata. The rules below cover the dominant conventions and
/// otherwise fall back to showing the whole title as the track, which is never
/// wrong — only less specific.
public func parseYouTubeTitle(_ raw: String) -> (track: String, artist: String) {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Unread-notification counter the browser prepends: "(3) Real Title".
    if s.hasPrefix("("), let close = s.firstIndex(of: ")") {
        let inside = s[s.index(after: s.startIndex)..<close]
        if !inside.isEmpty, inside.allSatisfy(\.isNumber) {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    for suffix in [" - YouTube Music", " - YouTube"] where s.hasSuffix(suffix) {
        s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        break
    }
    guard !s.isEmpty else { return ("", "") }

    // "Artist - Track" only when there is exactly one separator. More than one
    // means a title like "lofi - beats to study to - mix", where guessing which
    // half is the artist would be worse than not guessing.
    let parts = s.components(separatedBy: " - ")
    if parts.count == 2 {
        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let track = parts[1].trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty && !track.isEmpty { return (track, artist) }
    }
    return (s, "")
}

/// Whether to read a browser at reduced (title-only) fidelity right now.
///
/// A browser found to have its JavaScript bridge off is remembered as
/// title-only, but only for a while: the user may turn the bridge on at any
/// time, and the widget must pick that up without waiting for the browser to
/// quit or the app to restart. `downgradedUntil` is when that memory expires;
/// past it, full fidelity is retried. Per browser, so a bridge-off Brave never
/// forces a bridge-on Safari down to title-only.
public func useTitleOnly(downgradedUntil: Date?, now: Date) -> Bool {
    guard let until = downgradedUntil else { return false }
    return until > now
}
