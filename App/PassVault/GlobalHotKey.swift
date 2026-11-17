import AppKit
import Carbon.HIToolbox
import DesignKit

/// A shortcut that works while another app is in front. It is a hot key of Carbon, which
/// needs no permission of the user: PassVault sees this one key combination and no other key.
@MainActor
final class GlobalHotKey {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var lastID: UInt32 = 0

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// nil when the system does not give the shortcut, for example because another app has it.
    init?(_ shortcut: BWKeyShortcut, action: @escaping @MainActor () -> Void) {
        Self.installHandler()
        Self.lastID += 1
        id = Self.lastID
        // "PVQA"
        let hotKeyID = EventHotKeyID(signature: 0x5056_5141, id: id)
        // The modifiers as Carbon names them.
        var modifiers = 0
        if shortcut.modifiers.contains(.command) { modifiers |= cmdKey }
        if shortcut.modifiers.contains(.shift) { modifiers |= shiftKey }
        if shortcut.modifiers.contains(.option) { modifiers |= optionKey }
        if shortcut.modifiers.contains(.control) { modifiers |= controlKey }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0,
                                         &reference)
        guard status == noErr, reference != nil else { return nil }
        Self.actions[id] = action
    }

    /// Gives the shortcut back to the system.
    func release() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return status }
            let id = pressed.id
            // Carbon sends its events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &kind, nil, &handler)
    }
}
