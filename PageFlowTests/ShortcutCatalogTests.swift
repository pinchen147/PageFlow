//
//  ShortcutCatalogTests.swift
//  PageFlowTests
//
//  Pins the shortcut registry's invariants: unique ids, collision-free default
//  bindings, the catalog ↔ defaults ↔ Settings-grouping derivation, and the
//  recorder's validation (reserved / too-weak / conflicting combos).
//

import AppKit
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
struct ShortcutCatalogTests {
    // MARK: - Registry integrity

    @Test
    func everyActionIdIsUnique() {
        let ids = ShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test
    func defaultBindingsDoNotCollideWhereBothCanAct() {
        // Two commands sharing a default combo where both act would make one
        // silently dead; a PDF command and a Markdown one may share (⌘U).
        let bound = ShortcutCatalog.all.filter { !$0.defaultShortcut.isNone }
        for (index, action) in bound.enumerated() {
            for other in bound[(index + 1)...] where action.scope.overlaps(other.scope) {
                #expect(action.defaultShortcut.displayString != other.defaultShortcut.displayString,
                        "\(action.title) and \(other.title)")
            }
        }
    }

    @Test
    func everyMenuAndEditorCommandHasExactlyOneRow() {
        let ids = Set(ShortcutCatalog.all.map(\.id))
        for command in MarkdownFormatCommand.allCases {
            #expect(ids.contains(command.shortcutID), "Format > \(command.title)")
        }
        for command in MarkdownEditorKeyCommand.allCases {
            #expect(ShortcutCatalog.all.filter { $0.editorCommand == command }.count == 1, "\(command)")
        }
        for id in ["undo", "redo", "findAndReplace", "findNext", "findPrevious"] + (1...9).map(ShortcutCatalog.selectTabID) {
            #expect(ids.contains(id), "\(id) is rebindable")
        }
    }

    @Test
    func theEditorsDefaultsAreTheCatalogs() {
        // The engine's own defaults and Settings' must agree, or the menu and
        // the focused editor would answer different keys.
        let bindings = ShortcutCatalog.editorKeyBindings(current: { ShortcutCatalog.defaults[$0] ?? .none })
        for command in MarkdownEditorKeyCommand.allCases where !MarkdownKeyBindings.default[command].isEmpty {
            #expect(bindings[command] == MarkdownKeyBindings.default[command], "\(command)")
        }
    }

    @Test
    func theEditorFollowsARebinding() {
        let custom = ["format.bold": ShortcutModel(key: "b", control: true), "markdownComment": ShortcutModel(key: "j", option: true),
                      "format.strikethrough": ShortcutModel.none]
        let bindings = ShortcutCatalog.editorKeyBindings(current: { custom[$0] ?? ShortcutCatalog.defaults[$0] ?? .none })
        #expect(bindings[.bold] == [MarkdownKeyChord("b", command: true, control: true)])
        #expect(bindings[.comment] == [MarkdownKeyChord("j", command: true, option: true)], "⌃⌥M goes with the default")
        #expect(bindings[.strikethrough].isEmpty)
        #expect(bindings[.toggleChecked] == [MarkdownKeyChord("return", command: true)])
    }

    @Test
    func findAndReplaceOwnsOptionCommandFAndZoomToFitMovesToOptionCommandZero() {
        #expect(ShortcutCatalog.defaults["findAndReplace"] == ShortcutModel(key: "f", option: true))
        #expect(ShortcutCatalog.defaults["zoomToFit"] == ShortcutModel(key: "0", option: true))
    }

    @Test
    func validateWarnsOnlyWhereBothCanAct() {
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "g"), for: "newTab") == .conflict("Find Next"))
        #expect(!ShortcutCatalog.validate(ShortcutModel(key: "g"), for: "newTab").blocksConfirm)
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "u"), for: "format.underline") == .ok, "PDF's Underline acts elsewhere")
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "s"), for: "format.bold") == .conflict("Save"))
    }

    @Test
    func defaultsDictMirrorsCatalog() {
        #expect(ShortcutCatalog.defaults.count == ShortcutCatalog.all.count)
        for action in ShortcutCatalog.all {
            #expect(ShortcutCatalog.defaults[action.id] == action.defaultShortcut)
        }
    }

    @Test
    func groupingCoversEveryActionExactlyOnce() {
        let grouped = ShortcutCatalog.grouped().flatMap { $0.1 }
        #expect(grouped.count == ShortcutCatalog.all.count)
        #expect(Set(grouped.map(\.id)) == Set(ShortcutCatalog.all.map(\.id)))
    }

    @Test
    func migratedDefaultsKeepTheirConventionalBindings() {
        // The migration must be behavior-preserving: the default equals the
        // shortcut the menu hard-coded before.
        let expected: [String: String] = [
            "newTab": "⌘T", "newMarkdownDocument": "⌘N", "newWindow": "⇧⌘N",
            "openFile": "⌘O", "closeTab": "⌘W",
            "save": "⌘S", "saveAs": "⇧⌘S", "print": "⌘P", "search": "⌘F",
            "toggleSidebar": "⌥⌘S", "toggleComments": "⌥⌘E",
            "firstPage": "⌥⌘←", "lastPage": "⌥⌘→", "selectNextTab": "⇧⌘]", "selectPreviousTab": "⇧⌘[",
            "undo": "⌘Z", "redo": "⇧⌘Z", "findNext": "⌘G", "findPrevious": "⇧⌘G", "selectTab1": "⌘1",
            "format.bold": "⌘B", "format.link": "⌘K", "format.heading": "⌥⌘1", "format.bulletedList": "⇧⌘8",
            "format.quote": "⇧⌘9", "markdownComment": "⌥⌘M", "markdownToggleComments": "⌥⇧C",
        ]
        for (id, combo) in expected {
            #expect(ShortcutCatalog.defaults[id]?.displayString == combo, "\(id)")
        }
    }

    // MARK: - Validation

    @Test
    func validateBlocksReservedSystemCombo() {
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "q"), for: "newTab") == .reserved)
    }

    @Test
    func validateBlocksCombosWithoutCommandOrControl() {
        // ⇧J carries a modifier but no ⌘/⌃ — it would shadow plain typing.
        let weak = ShortcutModel(key: "j", command: false, shift: true)
        #expect(ShortcutCatalog.validate(weak, for: "newTab") == .needsCommand)
    }

    @Test
    func validatePassesAFreeControlCombo() {
        // ⌃J: a real modifier, unused by any command.
        let free = ShortcutModel(key: "j", command: false, control: true)
        #expect(ShortcutCatalog.validate(free, for: "newTab") == .ok)
    }

    @Test
    func validateDetectsConflictWithAnotherCommand() {
        // Assumes a clean install (no custom overrides), so `current` == default.
        let saveCombo = ShortcutCatalog.defaults["save"]!
        #expect(ShortcutCatalog.validate(saveCombo, for: "newTab") == .conflict("Save"))
    }

    @Test
    func plainKeysAreForFunctionKeysAndCommandsOutsideTheText() {
        let f6 = ShortcutModel(key: "F6", command: false)
        #expect(ShortcutCatalog.validate(f6, for: "format.focusSelectionBar") == .ok)
        #expect(ShortcutCatalog.validate(f6, for: "newTab") == .needsCommand)
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "h", command: false, shift: true, option: true),
                                         for: "markdownToggleComments") == .ok)
        #expect(ShortcutCatalog.validate(ShortcutModel(key: "h", command: false), for: "markdownToggleComments") == .needsCommand)
        #expect(ShortcutCatalog.validate(.none, for: "save") == .ok, "a shortcut can always be cleared")
        #expect(ShortcutModel.none.displayString == "None")
    }

    // MARK: - Search

    private func found(_ query: String) -> Set<String> {
        Set(ShortcutCatalog.all.filter { ShortcutCatalog.matches($0, query: query, current: { ShortcutCatalog.defaults[$0] ?? .none }) }
            .map(\.id))
    }

    @Test
    func searchFindsByNameSectionOrKeys() {
        #expect(found("").count == ShortcutCatalog.all.count)
        #expect(found("bold") == ["format.bold"])
        #expect(found("Find").isSuperset(of: ["search", "findAndReplace", "findNext", "findPrevious"]))
        #expect(found("comments (markdown)") == ["markdownComment", "markdownToggleComments"], "a section")
        #expect(found("⌘B") == ["format.bold"], "the whole chord: not ⇧⌘B")
        #expect(found("cmd b") == ["format.bold"])
        #expect(found("shift cmd n") == ["newWindow"], "modifiers in any order")
        #expect(found("⇧⌘N") == ["newWindow"])
        #expect(found("⌥⌘M") == ["markdownComment"])
        #expect(!found("ctrl").contains("format.bold"), "a modifier the key lacks")
        #expect(found("⌃").contains("format.focusSelectionBar") == false && found("shift").contains("newWindow"),
                "modifiers alone find every key that has them")
        #expect(found("zzz").isEmpty)
    }

    // MARK: - Recording

    private func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test
    func theRecorderKeepsTheKeyNotTheShiftedCharacter() throws {
        let recorded = try #require(ShortcutModel.from(event: try key("*", 28, [.command, .shift])))
        #expect(recorded == ShortcutModel(key: "8", shift: true))
        #expect(recorded.displayString == "⇧⌘8")
        let f6 = try #require(ShortcutModel.from(event: try key("\u{F709}", 97, [.function])))
        #expect(f6 == ShortcutModel(key: "F6", command: false), "a function key needs no modifier")
        #expect(ShortcutModel.from(event: try key("j", 38, [])) == nil, "a plain letter is typing, not a shortcut")
    }

    @Test
    func validateAllowsReassigningACommandToItsOwnCombo() {
        // Re-recording a command's existing combo is not a self-conflict.
        let saveCombo = ShortcutCatalog.defaults["save"]!
        #expect(ShortcutCatalog.validate(saveCombo, for: "save") == .ok)
    }
}
