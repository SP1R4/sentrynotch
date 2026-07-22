import Foundation
import CoreGraphics

/// The minimal shape of an `NSScreen` this decision needs — kept separate from
/// AppKit so the choice itself can run and be tested without a real display.
public struct ScreenInfo: Equatable, Sendable {
    public let id: Int
    public let frame: CGRect
    public let hasNotch: Bool

    public init(id: Int, frame: CGRect, hasNotch: Bool) {
        self.id = id; self.frame = frame; self.hasNotch = hasNotch
    }
}

/// Which screen the island should live on.
///
/// Default (`followPointer == false`): pin to the display with a physical
/// notch, if one is connected. The island's shape is drawn to visually hug a
/// notch — rounded corners closing around a camera housing — so showing it on
/// a plain external monitor reads as a rendering bug, not a feature. This is
/// re-decided on every call rather than cached, since displays can be plugged
/// or unplugged while the app is running.
///
/// `followPointer == true` restores pointer-follow: whichever screen the
/// mouse is currently over, falling back to the panel's last screen and then
/// the system's main screen. That was the original design, changed to
/// pointer-follow specifically to stop the island being stranded on a laptop
/// screen while the user worked on an external monitor — a real need for
/// someone with no notch anywhere, which is why it stays available as an
/// opt-in rather than being removed outright.
///
/// Returns nil only when `screens` is empty, which does not happen in
/// practice — `NSScreen.screens` always has at least one entry — but the
/// caller should not force-unwrap a display list it does not control.
public func chooseActiveScreen(
    screens: [ScreenInfo],
    mouse: CGPoint,
    followPointer: Bool,
    panelScreenID: Int?,
    mainScreenID: Int?
) -> Int? {
    if !followPointer, let notched = screens.first(where: { $0.hasNotch }) {
        return notched.id
    }
    if let hit = screens.first(where: { $0.frame.contains(mouse) }) {
        return hit.id
    }
    if let panelScreenID, screens.contains(where: { $0.id == panelScreenID }) {
        return panelScreenID
    }
    if let mainScreenID, screens.contains(where: { $0.id == mainScreenID }) {
        return mainScreenID
    }
    return screens.first?.id
}
