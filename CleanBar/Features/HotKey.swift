import AppKit
import Carbon.HIToolbox

/// Registers CleanBar's global keyboard shortcut. Carbon hot keys work without any extra permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Set while the shortcut recorder is listening, so the old shortcut doesn't fire.
    var isPaused = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ combo: HotKeyCombo?, action: @escaping () -> Void) {
        unregister()
        self.action = action
        guard let combo else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x434C_4252), id: 1) // "CLBR"
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    fileprivate func handlePress() {
        guard !isPaused else { return }
        action?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &handlerRef)
    }
}

// Carbon calls this on the main thread.
private nonisolated func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handlePress()
    }
    return OSStatus(noErr)
}

extension NSEvent.ModifierFlags {
    /// ⌘ ⌥ ⌃ ⇧: the keys a shortcut is made with, and that make a click more than a plain click.
    nonisolated static let shortcutKeys: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}

extension HotKeyCombo {
    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func label(forKeyCode keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: (characters ?? "?").uppercased()
        }
    }
}
