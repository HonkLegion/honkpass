import Foundation

/// A key with its modifier keys: a shortcut that works while another app is in front.
public struct BWKeyShortcut: Codable, Sendable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// The number macOS gives the key, whatever the keyboard layout prints on it.
    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// What the key types on the keyboard of the user, to show it. It is no part of what the
    /// shortcut is: the same key with the same modifiers is the same shortcut.
    public var keyName: String

    public init(keyCode: UInt16, modifiers: Modifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Shift-Command-Space: the shortcut of quick access unless the user chooses another.
    public static let quickAccess = BWKeyShortcut(keyCode: 49, modifiers: [.shift, .command], keyName: " ")
    /// Control, Option and B: the autotype shortcut the reference starts with
    /// (`DEFAULT_KEYBOARD_SHORTCUT` of main-autotype-keyboard-shortcut.ts).
    public static let fill = BWKeyShortcut(keyCode: 11, modifiers: [.control, .option], keyName: "b")

    /// A shortcut holds Command, Control or Option, so that it takes no key of plain typing
    /// from the other apps; Shift alone is typing. A function key may stand alone.
    public var isValid: Bool {
        guard keyCode < 128, !Self.modifierKeys.contains(keyCode) else { return false }
        return !modifiers.isDisjoint(with: [.command, .control, .option]) || Self.functionKeys[keyCode] != nil
    }

    /// The shortcut as macOS writes one: the modifiers in the order Control, Option, Shift,
    /// Command, then the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.namedKeys[keyCode] ?? Self.functionKeys[keyCode] ?? keyName.uppercased())
    }

    /// The keys that type no character of their own, by the name or the sign macOS shows for them.
    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Command, Shift, Caps Lock, Option, Control, their right-hand twins and Fn.
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}

extension BWKeyShortcut: Equatable {
    public static func == (left: BWKeyShortcut, right: BWKeyShortcut) -> Bool {
        left.keyCode == right.keyCode && left.modifiers == right.modifiers
    }
}
