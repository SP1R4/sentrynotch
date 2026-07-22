import AppKit
import SwiftUI
import Combine
import SentryNotchCore

/// Borderless panel that can take keyboard focus (needed for the toggle/buttons,
/// Esc, and number-key answers). A plain borderless NSPanel refuses key status.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the notch panel: keeps it centered under the notch, expands on hover,
/// collapses when you leave (unless pinned or a prompt is waiting), and pops
/// open with a sound on a new permission prompt. Also owns the menu-bar item.
@MainActor
final class NotchController: NSObject {
    private let panel: KeyablePanel
    private let state = NotchState()
    private let model: AppModel
    private lazy var dashboard = DashboardWindowController(model: model)
    private lazy var onboarding = OnboardingWindowController(model: model)
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?
    /// When the panel last took key status, used to ignore the spurious
    /// resign-key that arrives during focus handoff from another app.
    private var lastFocusAt = Date.distantPast

    // Wider than tall: widgets sit in a strip, so the panel spreads across the
    // notch instead of hanging down the screen.
    private let expandedWidth: CGFloat = 560
    /// Chrome above the scrolling content: notch inset + toolbar + hairline.
    private var chromeHeight: CGFloat { (notch?.height ?? 0) + 42 + 1 }
    private let minContentHeight: CGFloat = 90
    private let maxExpandedHeight: CGFloat = 620

    // The open/close motion. The window frame (AppKit) and the SwiftUI content
    // inside it must ride the *same* curve and duration or they resize out of
    // sync and the pop reads as jittery. A single gentle deceleration — fast
    // out, soft settle, no overshoot — instead of the old mismatched pair (a
    // bouncy SwiftUI spring against a differently-overshooting window bezier).
    private let popDuration: CFTimeInterval = 0.42
    /// easeOutExpo-ish: leaves the notch quickly, then eases to rest.
    private var popTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.28, 1)
    }
    private var popAnimation: Animation {
        .timingCurve(0.22, 1, 0.28, 1, duration: popDuration)
    }

    /// Height follows the content instead of being a fixed rectangle. A fixed
    /// panel left roughly a third of the surface as empty black whenever there
    /// were only a couple of sessions, which read as broken rather than sparse.
    private var expandedSize: NSSize {
        let content = max(minContentHeight, state.contentHeight)
        let height = min(maxExpandedHeight, chromeHeight + content)
        return NSSize(width: expandedWidth, height: height)
    }
    /// Extra width per side for the working-mascot flanks.
    private let flank: CGFloat = 46
    private var collapsedSize: NSSize {
        if let n = notch {
            // Mascot wedges appear only while a session is working, so the
            // notch grows out to hold them then and shrinks back when idle.
            let extra = (model.hasActiveSession && model.settings.mascotEnabled) ? flank * 2 : 0
            return NSSize(width: n.width + extra, height: n.height + 11)
        }
        return NSSize(width: 170, height: 34)
    }

    init(model: AppModel) {
        self.model = model
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 170, height: 34)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the menu bar so the island can sit in/over the notch, not under it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        state.notchHeight = notch?.height ?? 0
        state.notchWidth = notch?.width ?? 0

        let root = IslandView(model: model, state: state,
                              onToggle: { [weak self] in self?.toggle() },
                              onDashboard: { [weak self] in self?.dashboard.show() })
            .onHover { [weak self] hovering in self?.hover(hovering) }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: collapsedSize)
        hosting.autoresizingMask = [.width, .height]
        // The panel's frame is authoritative: we size and centre it ourselves in
        // topCenteredFrame. Left at its default, NSHostingView installs Auto
        // Layout constraints from the SwiftUI content's intrinsic size, which
        // override that frame and stretch the window to fit its widest content —
        // the panel then grew rightward past 560pt and drifted off-centre. Empty
        // options make the hosting view purely track the window via the mask.
        hosting.sizingOptions = []
        panel.contentView = hosting

        position(for: collapsedSize)
        panel.orderFrontRegardless()
        logGeometry()

        NotificationCenter.default.addObserver(
            self, selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification, object: panel)

        model.onNewPrompt = { [weak self] in self?.setExpanded(true) }
        setupStatusItem()

        // Menu-bar badge reflects the pending-prompt count.
        model.$pending
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                self?.statusItem?.button?.title = count > 0 ? " \(count)" : ""
            }
            .store(in: &cancellables)

        // Global summon toggles the island. The shortcut is user-configurable,
        // so it registers from settings and re-registers whenever it changes.
        registerSummon()
        model.settings.$hotkeyKeyCode.combineLatest(model.settings.$hotkeyModifiers)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.registerSummon() }
            .store(in: &cancellables)

        // Recompute whether the sprite/marquee animate when the motion
        // preference changes, or when macOS's Reduce Motion flips.
        model.settings.$animationMode
            .dropFirst()
            .sink { [weak self] _ in self?.visibilityChanged() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(visibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        // Grow/shrink the collapsed notch as sessions start/stop working.
        model.$sessions
            .map { $0.contains { $0.isActive } }
            .removeDuplicates()
            .sink { [weak self] _ in self?.repositionCollapsed() }
            .store(in: &cancellables)

        // Pass the notch's side width to the view so it can place the flanks.
        state.flankWidth = flank

        // Without the hooks registered the app can watch sessions but never
        // intercept, so a fresh install has to be told what to do next.
        if onboarding.shouldShowAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onboarding.show()
            }
        }

        observeVisibility()
        installKeyMonitor()

        // Development aid: open and pin the island at launch. Driving a
        // borderless panel that sits above the menu bar with synthetic clicks
        // is unreliable, which has repeatedly blocked verifying UI changes.
        if ProcessInfo.processInfo.environment["\(Brand.slug.uppercased())_EXPAND"] == "1" {
            state.pinned = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.setExpanded(true)
            }
        }

        // When a popover closes, re-evaluate: the pointer may have left the
        // panel while it was open, so the island should collapse now rather
        // than hang around until the next hover event.
        state.$popoverOpen
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let self else { return }
                // Generous delay: after choosing a preset the pointer is left
                // where the popover was — below the panel — so a short timeout
                // would slam the island shut before the user sees the timer
                // actually start. Without any re-check though, an island whose
                // hover-exit was swallowed while the popover was open would
                // stay stuck open until the pointer passed over it again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard !self.state.popoverOpen, !self.state.pinned,
                          self.model.pending.isEmpty,
                          !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.setExpanded(false)
                }
            }
            .store(in: &cancellables)

        // Re-fit the panel as content grows or shrinks (a prompt arrives, a
        // session ends, a card is expanded).
        state.$contentHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refitExpanded() }
            .store(in: &cancellables)
    }

    private var keyMonitor: Any?

    /// Keyboard answers, handled at the AppKit level.
    ///
    /// SwiftUI's `.onKeyPress` needs the view to hold focus, which a borderless
    /// `NSPanel` hosting a SwiftUI tree never reliably gives it — the handler
    /// was installed for months and never fired once. A local event monitor
    /// sees key-downs whenever this app is active, which is exactly the right
    /// scope: it can't take keys from another application.
    ///
    /// Two guards, both deliberate:
    ///
    /// - Nothing is answered within `keyGrace` of the panel taking focus. The
    ///   island steals focus when a prompt arrives, so a keystroke already on
    ///   its way to another app must not answer anything.
    /// - Always and Bypass need ⌘. They create standing grants that outlive the
    ///   prompt; a bare digit is too easy to hit by accident for something
    ///   irreversible. Deny and Allow Once affect one call and stay bare keys.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.state.expanded,
                  let req = self.model.pending.first,
                  Date().timeIntervalSince(self.lastFocusAt) > IslandView.keyGrace
            else { return event }

            // Every answer needs ⌘. A bare digit is far too easy to hit by
            // accident — the island steals focus when a prompt arrives, so a
            // keystroke meant for your editor lands here. Requiring the
            // modifier means no stray character can ever answer a prompt, and
            // the hints stay consistent across all four buttons.
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers ?? "" {
            case "1": self.model.deny(req); return nil
            case "2": self.model.allowOnce(req); return nil
            case "3": self.model.alwaysAllow(req, source: "keyboard ⌘3"); return nil
            case "4": self.model.bypass(req); return nil
            default: return event
            }
        }
    }

    /// Stop animating when nothing can see it.
    ///
    /// The sprites and spinner are driven by periodic timelines, which keep
    /// rebuilding the view tree whether or not the panel is visible. Left
    /// ungated that burned >20% CPU for as long as any session was working —
    /// including with the lid shut. Occlusion covers "another window is over
    /// Release everything registered against global centres.
    ///
    /// This is a singleton today, so nothing here leaks in practice — but the
    /// registrations are against process-wide centres (`NotificationCenter`,
    /// `NSWorkspace`) and a global event monitor, none of which are owned by
    /// this object. If a second controller is ever constructed — a second
    /// display, a test, a settings preview — the old one keeps receiving
    /// callbacks and driving a panel that should be gone. Teardown belongs with
    /// the setup regardless of whether it currently runs.
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// it"; the workspace notifications cover display sleep and screen lock,
    /// which do not always change occlusion state.
    private func observeVisibility() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(visibilityChanged),
                       name: NSWindow.didChangeOcclusionStateNotification, object: panel)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(screenWentAway),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screenWentAway),
                        name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screenCameBack),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screenCameBack),
                        name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        visibilityChanged()
    }

    /// Tracked separately from occlusion: a sleeping display or a locked screen
    /// does not necessarily mark the window as occluded, so relying on
    /// occlusion alone left it animating to nobody with the lid shut.
    private var screenAvailable = true

    @objc private func screenWentAway() { screenAvailable = false; visibilityChanged() }
    @objc private func screenCameBack() { screenAvailable = true; visibilityChanged() }

    @objc private func visibilityChanged() {
        let onScreen = screenAvailable && panel.occlusionState.contains(.visible)
        let visible = onScreen && userWantsAnimations
        if state.animate != visible { state.animate = visible }
    }

    /// The user's motion preference, resolving `.system` against macOS's
    /// Reduce Motion accessibility setting.
    private var userWantsAnimations: Bool {
        switch model.settings.animationMode {
        case .always: return true
        case .never:  return false
        case .system: return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private var summonHotKeyID: UInt32?

    /// (Re)bind the global summon shortcut to the current setting.
    private func registerSummon() {
        if let id = summonHotKeyID { HotKeyCenter.shared.unregister(id) }
        summonHotKeyID = HotKeyCenter.shared.register(
            keyCode: model.settings.hotkeyKeyCode,
            modifiers: model.settings.hotkeyModifiers) { [weak self] in self?.toggle() }
    }

    /// Resize an already-open panel to match new content, without re-running
    /// the open animation.
    private func refitExpanded() {
        guard state.expanded, let screen = activeScreen else { return }
        let target = topCenteredFrame(size: expandedSize, in: screen)
        guard abs(target.height - panel.frame.height) > 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func repositionCollapsed() {
        guard !state.expanded, let screen = activeScreen else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.1)
            panel.animator().setFrame(topCenteredFrame(size: collapsedSize, in: screen), display: true)
        }
    }

    // MARK: - Expand / collapse

    func toggle() { setExpanded(!state.expanded) }

    private func hover(_ hovering: Bool) {
        collapseWork?.cancel()
        if hovering {
            setExpanded(true)
        } else if !state.pinned && model.pending.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        // A popover lives in its own window, outside the panel's frame. Opening
        // one makes the panel resign key AND fires onHover(false), so both
        // collapse paths fire the instant the user opens it — the island slid
        // shut and took the popover with it. Never collapse while one is up.
        if !expanded && state.popoverOpen { return }
        guard expanded != state.expanded else { if expanded { focus() }; return }
        let size = expanded ? expandedSize : collapsedSize
        guard let screen = activeScreen else { return }
        withAnimation(popAnimation) {
            state.expanded = expanded
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = popDuration
            ctx.timingFunction = popTimingFunction
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(topCenteredFrame(size: size, in: screen), display: true)
        }
        model.setIslandVisible(expanded)
        if expanded { focus() }
    }

    private func focus() {
        // Activate first, then take key. The reverse order races: a
        // .nonactivatingPanel asking for key status while another app is still
        // frontmost gets it revoked immediately, which fires didResignKey and
        // collapsed the island the instant the global hotkey opened it — i.e.
        // the hotkey never worked from another app, which is the only place
        // anyone presses it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        lastFocusAt = Date()
        state.focusedAt = lastFocusAt
    }

    // MARK: - Geometry

    private func position(for size: NSSize) {
        guard let screen = activeScreen else { return }
        panel.setFrame(topCenteredFrame(size: size, in: screen), display: true)
    }

    private func topCenteredFrame(size: NSSize, in screen: NSScreen) -> NSRect {
        // Anchor to the true top edge (behind the notch) when there's a notch,
        // otherwise just under the menu bar so nothing is clipped.
        let x = screen.frame.midX - size.width / 2
        let top = notch != nil ? screen.frame.maxY : screen.visibleFrame.maxY
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    @objc private func didResignKey() {
        // Ignore the resign that immediately follows opening. Focus handoff
        // from the previously frontmost app produces a spurious resign-key a
        // few milliseconds after we take it; collapsing on that made the island
        // flash open and shut.
        guard Date().timeIntervalSince(lastFocusAt) > 0.6 else { return }
        if state.expanded && !state.pinned && model.pending.isEmpty { setExpanded(false) }
    }

    // MARK: - Menu-bar item

    /// The menu-bar glyph, drawn as a template image so macOS tints it for
    /// light/dark menu bars automatically. Previously an SF "sparkle", which was
    /// both generic and the exact motif removed from the rest of the app.
    private static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            // SwiftUI's Path is y-down; NSImage's context is y-up, so the
            // shield would render upside down without the flip.
            let inset = rect.insetBy(dx: 1, dy: 1)
            let cg = ShieldNotch().path(in: inset).cgPath
            var flip = CGAffineTransform(translationX: 0, y: rect.height)
                .scaledBy(x: 1, y: -1)
            guard let flipped = cg.copy(using: &flip) else { return true }
            let bezier = NSBezierPath(cgPath: flipped)
            NSColor.black.setFill()
            bezier.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Sentry Notch", action: #selector(showIsland), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Dashboard…", action: #selector(openDashboard), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Setup & hooks…", action: #selector(openOnboarding), keyEquivalent: "")
            .target = self
        let intercept = NSMenuItem(title: "Intercept permissions",
                                   action: #selector(toggleIntercept), keyEquivalent: "")
        intercept.target = self
        menu.addItem(intercept)
        menu.addItem(.separator())
        let autoAllow = NSMenuItem(title: "Auto-allow read-only tools",
                                   action: #selector(toggleAutoAllow), keyEquivalent: "")
        autoAllow.target = self
        menu.addItem(autoAllow)
        let newSessions = NSMenuItem(title: "Intercept new sessions",
                                     action: #selector(toggleNewSessions), keyEquivalent: "")
        newSessions.target = self
        menu.addItem(newSessions)
        let failClosed = NSMenuItem(title: "Fail closed on risky prompts",
                                    action: #selector(toggleFailClosed), keyEquivalent: "")
        failClosed.target = self
        menu.addItem(failClosed)
        menu.addItem(withTitle: "Manage rules…", action: #selector(showRules_), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Decision history…", action: #selector(showHistory_), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Refresh usage (1 call)", action: #selector(refreshUsage), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Show demo prompt", action: #selector(demoPrompt), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sentry Notch", action: #selector(quit), keyEquivalent: "q")
            .target = self
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showIsland() { setExpanded(true) }
    @objc private func openDashboard() { dashboard.show() }
    @objc private func openOnboarding() { onboarding.show() }
    @objc private func toggleIntercept() { model.interceptEnabled.toggle() }
    @objc private func toggleAutoAllow() { model.autoAllowReadOnly.toggle() }
    @objc private func toggleFailClosed() { model.failClosedRisky.toggle() }
    @objc private func toggleNewSessions() { model.interceptNewSessions.toggle() }
    @objc private func demoPrompt() { model.injectDemoPrompt() }
    @objc private func refreshUsage() { model.refreshUsage() }
    @objc private func showHistory_() {
        if !model.showHistory { model.toggleHistory() }
        setExpanded(true)
    }
    @objc private func showRules_() {
        if !model.showRules { model.toggleRules() }
        setExpanded(true)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    /// The display the island should live on.
    ///
    /// Default: pin to whichever screen actually has the physical notch. The
    /// island is drawn to visually hug that notch — rounded corners closing
    /// around a camera housing that isn't there — so showing it on a plain
    /// external monitor reads as a rendering bug, not a feature. This is
    /// checked fresh each time rather than cached once, because displays can
    /// be connected or disconnected while the app is running.
    ///
    /// `followPointerAcrossScreens` restores the earlier behaviour: whichever
    /// screen currently has the pointer, so the island travels to an external
    /// monitor the user is actively working on. That was the right call before
    /// this app had a notch-shaped identity to protect, and some users may
    /// still prefer it — it's a Dashboard ▸ Appearance toggle, not a removed
    /// behaviour.
    private var activeScreen: NSScreen? {
        let screens = NSScreen.screens
        let infos = screens.enumerated().map {
            ScreenInfo(id: $0.offset, frame: $0.element.frame, hasNotch: $0.element.safeAreaInsets.top > 0)
        }
        let panelID = screens.firstIndex(where: { $0 == panel.screen })
        let mainID = screens.firstIndex(where: { $0 == NSScreen.main })
        guard let chosen = chooseActiveScreen(
            screens: infos, mouse: NSEvent.mouseLocation,
            followPointer: model.settings.followPointerAcrossScreens,
            panelScreenID: panelID, mainScreenID: mainID)
        else { return nil }
        return screens[chosen]
    }

    /// Physical notch (width, height) if this display has one.
    private var notch: (width: CGFloat, height: CGFloat)? {
        guard let s = activeScreen else { return nil }
        let top = s.safeAreaInsets.top
        guard top > 0 else { return nil }
        let left = s.auxiliaryTopLeftArea?.width ?? 0
        let right = s.auxiliaryTopRightArea?.width ?? 0
        let w = s.frame.width - left - right
        return (w > 0 ? w : 210, top)
    }

    private func logGeometry() {
        let s = NSScreen.main
        NSLog("sentrynotch: screens=\(NSScreen.screens.count) frame=\(s?.frame ?? .zero) " +
              "safeTop=\(s?.safeAreaInsets.top ?? -1) auxL=\(s?.auxiliaryTopLeftArea?.width ?? -1) " +
              "auxR=\(s?.auxiliaryTopRightArea?.width ?? -1) notch=\(String(describing: notch)) " +
              "panel=\(panel.frame)")
    }
}

extension NotchController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(toggleIntercept) }?
            .state = model.interceptEnabled ? .on : .off
        menu.items.first { $0.action == #selector(toggleAutoAllow) }?
            .state = model.autoAllowReadOnly ? .on : .off
        menu.items.first { $0.action == #selector(toggleFailClosed) }?
            .state = model.failClosedRisky ? .on : .off
        menu.items.first { $0.action == #selector(toggleNewSessions) }?
            .state = model.interceptNewSessions ? .on : .off
    }
}
