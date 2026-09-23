import Foundation

/// A global keyboard shortcut. Key codes are the Carbon virtual key codes, which are plain
/// numbers here so the core never imports Carbon.
public struct Hotkey: Equatable, Codable, Sendable, Hashable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥D, as the spec asks (not ⌘Space).
    public static let `default` = Hotkey(keyCode: 2, modifiers: [.control, .option])

    /// Carbon virtual key codes for the keys a user can pick.
    public static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
        "escape": 53,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105,
        "f14": 107, "f10": 109, "f12": 111, "f15": 113, "f4": 118, "f2": 120, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    public static func keyName(for code: UInt32) -> String? {
        keyCodes.first { $0.value == code }?.key
    }

    /// "⌃⌥D"
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let key = Self.keyName(for: keyCode) ?? "key\(keyCode)"
        switch key {
        case "space": text += "Space"
        case "return": text += "↩"
        case "tab": text += "⇥"
        case "delete": text += "⌫"
        case "escape": text += "⎋"
        case "left": text += "←"
        case "right": text += "→"
        case "up": text += "↑"
        case "down": text += "↓"
        default: text += key.uppercased()
        }
        return text
    }

    /// "ctrl+alt+d"; the text form used by the CLI and the bridge.
    public var commandLine: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.keyName(for: keyCode) ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// Parses "ctrl+alt+d", "cmd+shift+space", "control+option+f5".
    public static func parse(_ text: String) -> Hotkey? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "alt", "option", "opt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            default: return nil
            }
        }
        guard let code = keyCodes[last] else { return nil }
        // A global hotkey with no modifier would steal plain typing.
        guard !modifiers.isEmpty else { return nil }
        return Hotkey(keyCode: code, modifiers: modifiers)
    }
}
