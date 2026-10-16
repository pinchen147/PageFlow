import AppKit

/// The commands the focused editor handles from the keyboard before the app's
/// menus (doc 24 §6.10, doc 25 §7). A host can rebind every one of them.
public enum MarkdownEditorKeyCommand: String, CaseIterable, Hashable, Sendable {
    case bold, italic, underline, strikethrough, inlineCode, highlight, link
    case paragraph, heading1, heading2, heading3, heading4, heading5, heading6
    case bulletedList, numberedList, checklist, quote, codeBlock
    /// Ticks or clears the checklist item at the caret.
    case toggleChecked
    /// Comments on the selection, or opens the comment at the caret.
    case comment
    /// Hides or shows comments while the keyboard is outside the text (in
    /// text a chord without ⌘ or ⌃ types its character instead).
    case toggleComments
    /// Moves the keyboard into the selection bar (in a cell, else the table's "…").
    case focusSelectionBar
    /// Opens Cell actions at the caret in a table cell.
    case tableCellActions

    /// The format the command applies, for the ones that are formats.
    var format: MarkdownFormat? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .inlineCode: .code
        case .highlight: .highlight
        case .link: .link
        case .paragraph: .paragraph
        case .heading1: .heading(level: 1)
        case .heading2: .heading(level: 2)
        case .heading3: .heading(level: 3)
        case .heading4: .heading(level: 4)
        case .heading5: .heading(level: 5)
        case .heading6: .heading(level: 6)
        case .bulletedList: .bulletedList
        case .numberedList: .numberedList
        case .checklist: .checklist
        case .quote: .quote
        case .codeBlock: .codeBlock
        case .toggleChecked: .toggleChecked
        case .comment, .toggleComments, .focusSelectionBar, .tableCellActions: nil
        }
    }

    /// Commands that change whole lines; in a table cell they do nothing.
    var isBlock: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
             .bulletedList, .numberedList, .checklist, .quote, .codeBlock, .toggleChecked: true
        default: false
        }
    }
}

/// A key and its modifiers. `key` is the character the key types with no
/// modifiers ("b", "8", "["), or a named key: "return", "tab", "space",
/// "delete", "escape", "up", "down", "left", "right", "f1"…"f12".
public struct MarkdownKeyChord: Hashable, Sendable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Whether `event` is this chord: the same modifiers, and the same key by
    /// the character it types with no modifiers (so ⇧⌘8 is "8", not "*") or
    /// without ⌘ and ⌥, or by its key code for a named key.
    public func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) == command, flags.contains(.shift) == shift,
              flags.contains(.option) == option, flags.contains(.control) == control else { return false }
        if let codes = Self.namedKeys[key] { return codes.contains(event.keyCode) }
        guard event.type == .keyDown, !key.isEmpty else { return false }
        return event.characters(byApplyingModifiers: [])?.lowercased() == key
            || event.charactersIgnoringModifiers?.lowercased() == key
    }

    /// Key codes of the named keys (Return and keypad Enter are one key).
    static let namedKeys: [String: Set<UInt16>] = [
        "return": [36, 76], "tab": [48], "space": [49], "delete": [51], "escape": [53],
        "left": [123], "right": [124], "down": [125], "up": [126],
        "f1": [122], "f2": [120], "f3": [99], "f4": [118], "f5": [96], "f6": [97],
        "f7": [98], "f8": [100], "f9": [101], "f10": [109], "f11": [103], "f12": [111],
    ]
}

/// Which chords trigger which editor commands. Several chords may share a
/// command (⌥⌘M and ⌃⌥M); a command with none has no key.
public struct MarkdownKeyBindings: Equatable, Sendable {
    public var chords: [MarkdownEditorKeyCommand: [MarkdownKeyChord]]

    public init(_ chords: [MarkdownEditorKeyCommand: [MarkdownKeyChord]]) {
        self.chords = chords
    }

    public subscript(command: MarkdownEditorKeyCommand) -> [MarkdownKeyChord] {
        get { chords[command] ?? [] }
        set { chords[command] = newValue }
    }

    /// The command `event` triggers, if any.
    public func command(for event: NSEvent) -> MarkdownEditorKeyCommand? {
        MarkdownEditorKeyCommand.allCases.first { command in chords[command]?.contains { $0.matches(event) } == true }
    }

    /// the reference editor's chords as PageFlow keeps them: ⌘E, ⌘Y, ⇧⌘B and ⇧⌘9 stay
    /// the app's (Add Comment, Highlight, Toggle Top Bar, Quote), so inline
    /// code, highlight and checklist start with no key, and Link and Quote
    /// are left to the host's menus unless it binds them here.
    public static let `default` = MarkdownKeyBindings([
        .bold: [MarkdownKeyChord("b", command: true)],
        .italic: [MarkdownKeyChord("i", command: true)],
        .underline: [MarkdownKeyChord("u", command: true)],
        .strikethrough: [MarkdownKeyChord("x", command: true, shift: true)],
        .paragraph: [MarkdownKeyChord("0", command: true, option: true)],
        .heading1: [MarkdownKeyChord("1", command: true, option: true)],
        .heading2: [MarkdownKeyChord("2", command: true, option: true)],
        .heading3: [MarkdownKeyChord("3", command: true, option: true)],
        .heading4: [MarkdownKeyChord("4", command: true, option: true)],
        .heading5: [MarkdownKeyChord("5", command: true, option: true)],
        .heading6: [MarkdownKeyChord("6", command: true, option: true)],
        .bulletedList: [MarkdownKeyChord("8", command: true, shift: true)],
        .numberedList: [MarkdownKeyChord("7", command: true, shift: true)],
        .codeBlock: [MarkdownKeyChord("c", command: true, option: true)],
        .toggleChecked: [MarkdownKeyChord("return", command: true)],
        .comment: [MarkdownKeyChord("m", command: true, option: true), MarkdownKeyChord("m", option: true, control: true)],
        .toggleComments: [MarkdownKeyChord("c", shift: true, option: true)],
        .focusSelectionBar: [MarkdownKeyChord("f6"), MarkdownKeyChord("f6", command: true)],
        .tableCellActions: [MarkdownKeyChord("f10", shift: true)],
    ])
}
