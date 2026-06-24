//
//  ShortcutCatalogTests.swift
//  PageFlowTests
//
//  Pins the shortcut registry's invariants: unique ids, collision-free default
//  bindings, the catalog ↔ defaults ↔ Settings-grouping derivation, and the
//  recorder's validation (reserved / too-weak / conflicting combos).
//

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
    func defaultBindingsDoNotCollide() {
        // Two commands sharing a default combo would make one silently dead.
        let combos = ShortcutCatalog.all.map(\.defaultShortcut.displayString)
        #expect(Set(combos).count == combos.count)
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
            "newTab": "⌘T", "newWindow": "⌘N", "openFile": "⌘O", "closeTab": "⌘W",
            "save": "⌘S", "saveAs": "⇧⌘S", "print": "⌘P", "search": "⌘F",
            "toggleSidebar": "⌥⌘S", "toggleComments": "⌥⌘E", "enterFullScreen": "⌃⌘F",
            "firstPage": "⌥⌘←", "lastPage": "⌥⌘→", "selectNextTab": "⇧⌘]", "selectPreviousTab": "⇧⌘["
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
    func validateAllowsReassigningACommandToItsOwnCombo() {
        // Re-recording a command's existing combo is not a self-conflict.
        let saveCombo = ShortcutCatalog.defaults["save"]!
        #expect(ShortcutCatalog.validate(saveCombo, for: "save") == .ok)
    }
}
