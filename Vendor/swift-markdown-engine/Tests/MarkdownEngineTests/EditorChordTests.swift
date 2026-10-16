import AppKit
import Testing
@testable import MarkdownEngine

/// The editor's chords: the reference editor's where the owner kept them, PageFlow's
/// app commands for ⌘E, ⌘Y, ⇧⌘B and ⇧⌘9 (owner decision, 2026-10-14).
@MainActor
@Suite("Editor chords", .serialized)
struct EditorChordTests {
    private func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test("⌘E, ⌘Y, ⇧⌘B and ⇧⌘9 reach the app's menus; ⇧⌘X still strikes through")
    func chords() async throws {
        let editor = try MountedTableEditor(source: "Some words here\n")
        defer { editor.close() }
        editor.window.makeFirstResponder(editor.main)
        editor.main.setSelectedRange(NSRange(location: 5, length: 5))
        for (characters, code, flags) in [("e", UInt16(14), NSEvent.ModifierFlags.command), ("y", 16, .command),
                                          ("b", 11, [.command, .shift]), ("9", 25, [.command, .shift])] {
            #expect(!editor.main.performKeyEquivalent(with: try key(characters, code, flags, window: editor.window)),
                    "the editor leaves \(characters) to the app")
        }
        #expect(editor.main.string == "Some words here\n")
        editor.state.undo.beginUndoGrouping()
        #expect(editor.main.performKeyEquivalent(with: try key("x", 7, [.command, .shift], window: editor.window)))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == "Some ~~words~~ here\n")
    }

    @Test("a rebound chord works and the old one no longer does; a command can be left with no key")
    func rebinding() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.keyBindings[.bold] = [MarkdownKeyChord("b", command: true, control: true)]
        configuration.keyBindings[.inlineCode] = [MarkdownKeyChord("e", command: true, option: true)]
        configuration.keyBindings[.strikethrough] = []
        let editor = try MountedTableEditor(source: "Some words here\n", configuration: configuration)
        defer { editor.close() }
        editor.window.makeFirstResponder(editor.main)
        editor.main.setSelectedRange(NSRange(location: 5, length: 5))
        #expect(!editor.main.performKeyEquivalent(with: try key("b", 11, .command, window: editor.window)), "⌘B is free now")
        #expect(!editor.main.performKeyEquivalent(with: try key("x", 7, [.command, .shift], window: editor.window)), "no key")
        #expect(editor.main.string == "Some words here\n")
        editor.state.undo.beginUndoGrouping()
        #expect(editor.main.performKeyEquivalent(with: try key("b", 11, [.command, .control], window: editor.window)))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == "Some **words** here\n")
        editor.main.setSelectedRange(NSRange(location: 0, length: 4))
        editor.state.undo.beginUndoGrouping()
        #expect(editor.main.performKeyEquivalent(with: try key("´", 14, [.command, .option], window: editor.window)),
                "matched by the key, not the character ⌥ types")
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string.hasPrefix("`Some`"))
    }

    @Test("⇧⌘8 is the 8 key with Shift, not \"*\"; a named key matches by its code")
    func chordMatching() throws {
        let window = NSWindow()
        let star = try key("*", 28, [.command, .shift], window: window)
        #expect(MarkdownKeyChord("8", command: true, shift: true).matches(star))
        #expect(!MarkdownKeyChord("8", command: true).matches(star))
        let enter = try key("\r", 76, .command, window: window)
        #expect(MarkdownKeyChord("return", command: true).matches(enter), "keypad Enter is Return")
        #expect(MarkdownKeyBindings.default.command(for: enter) == .toggleChecked)
    }
}
