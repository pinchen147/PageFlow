//
//  ShortcutModel.swift
//  PageFlow
//
//  Keyboard shortcut data model for customization
//

import SwiftUI
import Carbon.HIToolbox
import MarkdownEngine

// MARK: - View Extension for Dynamic Shortcuts

extension View {
    /// Applies a keyboard shortcut from ShortcutModel for the given action ID.
    /// Reads from user settings, falls back to defaults.
    @ViewBuilder
    func keyboardShortcut(for action: String) -> some View {
        keyboardShortcut(ShortcutModel.current(for: action))
    }

    /// Applies `shortcut`, or none.
    @ViewBuilder
    func keyboardShortcut(_ shortcut: ShortcutModel?) -> some View {
        if let (key, modifiers) = shortcut?.asKeyboardShortcut {
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}

// MARK: - ShortcutModel

struct ShortcutModel: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// No key: the command is left without a shortcut.
    static let none = ShortcutModel(key: "", command: false)

    var isNone: Bool { key.isEmpty }

    /// F1…F12.
    var isFunctionKey: Bool { Self.functionKeyNumber(key) != nil }

    var hasModifier: Bool { command || shift || option || control }

    /// Saved spellings stay intact; consumers compare the semantic key.
    var canonicalKey: String {
        let aliases = ["↑": "up", "↓": "down", "←": "left", "→": "right",
                       "⎋": "escape", "esc": "escape", "↩": "return", "enter": "return",
                       "⇥": "tab", "⌫": "delete", "backspace": "delete", " ": "space",
                       "⌦": "deleteforward", "forwarddelete": "deleteforward"]
        let lower = key.lowercased()
        return aliases[lower] ?? lower
    }

    func hasSameChord(as other: ShortcutModel) -> Bool {
        guard let chord = editorChord, let otherChord = other.editorChord else { return false }
        if chord == otherChord { return true }
        guard shift, other.shift, command == other.command, option == other.option, control == other.control,
              canonicalKey.count == 1, other.canonicalKey.count == 1 else { return false }
        // Older saved values may name the shifted glyph. The matcher accepts
        // both that glyph and its base key, so collision checks must too. Ask
        // AppKit for their relationship in the current layout, never an ANSI map.
        for code in UInt16(0)..<UInt16(128) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code),
                let base = event.characters(byApplyingModifiers: [])?.lowercased(),
                let shifted = event.characters(byApplyingModifiers: [.shift])?.lowercased() else { continue }
            if (base == canonicalKey && shifted == other.canonicalKey)
                || (base == other.canonicalKey && shifted == canonicalKey) { return true }
        }
        return false
    }

    private static func functionKeyNumber(_ key: String) -> Int? {
        let lower = key.lowercased()
        guard lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...12).contains(number) else { return nil }
        return number
    }

    // MARK: - Display String

    var displayString: String {
        guard !isNone else { return "None" }
        return editorChord?.displayString ?? key.uppercased()
    }

    // MARK: - SwiftUI KeyboardShortcut

    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquiv = keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquiv, modifiers: modifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch canonicalKey {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "escape": return .escape
        case "return": return .return
        case "tab": return .tab
        case "delete": return .delete
        case "deleteforward": return .deleteForward
        case "space": return .space
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if let number = Self.functionKeyNumber(key), let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
                return KeyEquivalent(Character(scalar))
            }
            guard canonicalKey.count == 1, let char = canonicalKey.first else { return nil }
            return KeyEquivalent(char)
        }
    }

    /// The same chord for the Markdown editor's own key handling.
    var editorChord: MarkdownKeyChord? {
        guard keyEquivalent != nil else { return nil }
        return MarkdownKeyChord(canonicalKey, command: command, shift: shift, option: option, control: control)
    }

    private var modifiers: SwiftUI.EventModifiers {
        var mods: SwiftUI.EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        return mods
    }

    // MARK: - NSMenu KeyEquivalent

    var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var nsKeyEquivalent: String {
        switch canonicalKey {
        // NSMenu documents different Delete characters from NSEvent/SwiftUI.
        case "delete": return "\u{08}"
        case "deleteforward": return "\u{7F}"
        default: return keyEquivalent.map { String($0.character) } ?? ""
        }
    }

    // MARK: - Resolution

    /// The active binding for `action`: the user's override, else the factory
    /// default from `ShortcutCatalog`, else an empty (no-op) shortcut.
    static func current(for action: String) -> ShortcutModel {
        ShortcutCatalog.shortcut(for: action, saved: SettingsManager.shared.customShortcuts)
    }

    static func currentForMarkdown(for action: String) -> ShortcutModel {
        let canonical = ShortcutCatalog.canonicalID(for: action)
        return current(for: ShortcutCatalog.legacyMarkdownIDs[canonical] ?? canonical)
    }

    static func commentsPanelMenuShortcut(isMarkdown: Bool) -> ShortcutModel? {
        guard isMarkdown, let shortcut = SettingsManager.shared.customShortcuts["markdownToggleComments"] else {
            return current(for: "toggleComments")
        }
        // The editor already routes non-command/control keys outside text.
        // Registering them in the View menu would also intercept typing.
        return shortcut.command || shortcut.control ? shortcut : nil
    }

    /// Returns KeyEquivalent and modifiers tuple for use with .keyboardShortcut()
    var asKeyboardShortcut: (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard let keyEquiv = keyEquivalent else { return nil }
        return (keyEquiv, modifiers)
    }

    // MARK: - NSEvent Matching

    /// Checks if the given NSEvent matches this shortcut
    func matches(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return editorChord?.matches(event) == true
    }

    // MARK: - Create from NSEvent

    /// F1…F12 by key code.
    private static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
    ]

    static func from(event: NSEvent) -> ShortcutModel? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags
        let hasModifier = flags.contains(.command) || flags.contains(.option) ||
                          flags.contains(.control) || flags.contains(.shift)
        let functionKey = functionKeys[event.keyCode]

        guard hasModifier || functionKey != nil else { return nil }

        let key: String
        switch event.keyCode {
        case _ where functionKey != nil: key = "F" + String(functionKey ?? 0)
        case UInt16(kVK_UpArrow): key = "↑"
        case UInt16(kVK_DownArrow): key = "↓"
        case UInt16(kVK_LeftArrow): key = "←"
        case UInt16(kVK_RightArrow): key = "→"
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): key = "↩"
        case UInt16(kVK_Tab): key = "⇥"
        case UInt16(kVK_Delete): key = "⌫"
        case UInt16(kVK_ForwardDelete): key = "⌦"
        case UInt16(kVK_Home): key = "Home"
        case UInt16(kVK_End): key = "End"
        case UInt16(kVK_PageUp): key = "PageUp"
        case UInt16(kVK_PageDown): key = "PageDown"
        case UInt16(kVK_Space): key = "Space"
        case UInt16(kVK_Escape): key = "⎋"
        default:
            // AppKit re-translates keyCode using the current input source. ANSI
            // positions must not override what another layout actually types.
            guard let characters = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased(),
                  characters.count == 1 else { return nil }
            key = characters
        }

        return ShortcutModel(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }
}
