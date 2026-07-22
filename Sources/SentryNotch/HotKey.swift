import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon RegisterEventHotKey — works without the
/// Accessibility permission that NSEvent global monitors require.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef?] = [:]
    private var installed = false
    private var nextID: UInt32 = 1

    /// Register a global hotkey. Returns a token so the caller can rebind it
    /// later (see `unregister`) — needed for the user-configurable summon.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x58494C44), id: id)  // 'XILD'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] ?? nil { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async { [weak self] in self?.handlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKeyCenter.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeys {
    static let space: UInt32 = 49
    static let cmdShift = UInt32(cmdKey | shiftKey)
}
