//
//  ShortcutModel.swift
//  PageFlow
//
//  Keyboard shortcut data model for customization
//

import SwiftUI
import Carbon.HIToolbox

// MARK: - View Extension for Dynamic Shortcuts

extension View {
    /// Applies a keyboard shortcut from ShortcutModel for the given action ID.
    /// Reads from user settings, falls back to defaults.
    @ViewBuilder
    func keyboardShortcut(for action: String) -> some View {
        if let (key, modifiers) = ShortcutModel.current(for: action).asKeyboardShortcut {
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

    // MARK: - Display String

    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    // MARK: - SwiftUI KeyboardShortcut

    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquiv = keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquiv, modifiers: modifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key.lowercased() {
        case "↑", "up": return .upArrow
        case "↓", "down": return .downArrow
        case "←", "left": return .leftArrow
        case "→", "right": return .rightArrow
        case "⎋", "escape", "esc": return .escape
        case "↩", "return", "enter": return .return
        case "⇥", "tab": return .tab
        case "⌫", "delete", "backspace": return .delete
        case " ", "space": return .space
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            guard let char = key.lowercased().first else { return nil }
            return KeyEquivalent(char)
        }
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
        switch key.lowercased() {
        case "↑", "up": return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "↓", "down": return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "←", "left": return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "→", "right": return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        default: return key.lowercased()
        }
    }

    // MARK: - Defaults

    static let defaults: [String: ShortcutModel] = [
        // Navigation
        "nextPage": ShortcutModel(key: "↓"),
        "previousPage": ShortcutModel(key: "↑"),
        "goBack": ShortcutModel(key: "["),
        "goForward": ShortcutModel(key: "]"),
        "goToPage": ShortcutModel(key: "g", option: true),
        // Zoom
        "zoomIn": ShortcutModel(key: "+"),
        "zoomOut": ShortcutModel(key: "-"),
        "actualSize": ShortcutModel(key: "0"),
        "zoomToFit": ShortcutModel(key: "f", option: true),
        // Annotations
        "highlight": ShortcutModel(key: "y"),
        "underline": ShortcutModel(key: "u"),
        "comment": ShortcutModel(key: "e"),
        "bookmark": ShortcutModel(key: "d"),
        // Edit (page operations)
        "copyPage": ShortcutModel(key: "c"),
        "cutPage": ShortcutModel(key: "x"),
        "pastePage": ShortcutModel(key: "v"),
        "deletePage": ShortcutModel(key: "⌫"),
        "rotateClockwise": ShortcutModel(key: "r"),
        "rotateCounterClockwise": ShortcutModel(key: "r", shift: true),
        // Other
        "search": ShortcutModel(key: "f"),
        "save": ShortcutModel(key: "s"),
        "toggleSidebar": ShortcutModel(key: "s", option: true),
        "copyPageAsMarkdown": ShortcutModel(key: "m", shift: true),
        "copyDocumentAsMarkdown": ShortcutModel(key: "m", shift: true, option: true)
    ]

    static func current(for action: String) -> ShortcutModel {
        SettingsManager.shared.customShortcuts[action] ?? defaults[action] ?? ShortcutModel(key: "")
    }

    /// Returns KeyEquivalent and modifiers tuple for use with .keyboardShortcut()
    var asKeyboardShortcut: (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard let keyEquiv = keyEquivalent else { return nil }
        return (keyEquiv, modifiers)
    }

    // MARK: - NSEvent Matching

    /// Checks if the given NSEvent matches this shortcut
    func matches(event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard command == flags.contains(.command),
              shift == flags.contains(.shift),
              option == flags.contains(.option),
              control == flags.contains(.control) else {
            return false
        }

        // Check key match via keyCode or character
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        let normalizedKey = key.lowercased()
        if normalizedKey == characters { return true }

        // Handle special keys by keyCode
        switch event.keyCode {
        case UInt16(kVK_Delete) where normalizedKey == "⌫" || normalizedKey == "delete" || normalizedKey == "backspace":
            return true
        case UInt16(kVK_UpArrow) where normalizedKey == "↑" || normalizedKey == "up":
            return true
        case UInt16(kVK_DownArrow) where normalizedKey == "↓" || normalizedKey == "down":
            return true
        case UInt16(kVK_LeftArrow) where normalizedKey == "←" || normalizedKey == "left":
            return true
        case UInt16(kVK_RightArrow) where normalizedKey == "→" || normalizedKey == "right":
            return true
        case UInt16(kVK_Return) where normalizedKey == "↩" || normalizedKey == "return" || normalizedKey == "enter":
            return true
        case UInt16(kVK_Tab) where normalizedKey == "⇥" || normalizedKey == "tab":
            return true
        case UInt16(kVK_Space) where normalizedKey == " " || normalizedKey == "space":
            return true
        case UInt16(kVK_Escape) where normalizedKey == "⎋" || normalizedKey == "escape" || normalizedKey == "esc":
            return true
        default:
            return false
        }
    }

    // MARK: - Create from NSEvent

    static func from(event: NSEvent) -> ShortcutModel? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              !characters.isEmpty else { return nil }

        let flags = event.modifierFlags
        let hasModifier = flags.contains(.command) || flags.contains(.option) ||
                          flags.contains(.control) || flags.contains(.shift)

        guard hasModifier else { return nil }

        let key: String
        switch event.keyCode {
        case UInt16(kVK_UpArrow): key = "↑"
        case UInt16(kVK_DownArrow): key = "↓"
        case UInt16(kVK_LeftArrow): key = "←"
        case UInt16(kVK_RightArrow): key = "→"
        case UInt16(kVK_Return): key = "↩"
        case UInt16(kVK_Tab): key = "⇥"
        case UInt16(kVK_Delete): key = "⌫"
        case UInt16(kVK_Space): key = "Space"
        case UInt16(kVK_Escape): key = "⎋"
        default: key = characters
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
