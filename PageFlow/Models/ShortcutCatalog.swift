//
//  ShortcutCatalog.swift
//  PageFlow
//
//  The single source of truth for every customizable keyboard shortcut: its id,
//  display title, category, and default binding. `ShortcutModel.defaults` and the
//  Settings list are both DERIVED from `ShortcutCatalog.all`, so an action can
//  never exist in one place but not the other (the prior two-hand-synced-lists
//  footgun). Adding a shortcut = one entry here + `.keyboardShortcut(for: id)` on
//  the command.
//

import Foundation

/// One user-rebindable command: a stable `id` (the key into `customShortcuts`),
/// a human title for Settings, the Settings section it belongs to, and its
/// factory-default binding.
struct ShortcutAction: Identifiable, Equatable {
    let id: String
    let title: String
    let category: Category
    let defaultShortcut: ShortcutModel

    /// Settings sections, rendered in declaration order.
    enum Category: String, CaseIterable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case zoom = "Zoom"
        case navigation = "Navigation"
        case annotations = "Annotations"
        case markdown = "Markdown"
        case tabs = "Tabs"
    }
}

enum ShortcutCatalog {
    /// Every customizable command. Order within a category is the Settings order.
    /// NOTE: the `ShortcutModel` initializer defaults `command: true`, so a "bare"
    /// key like `"t"` is ⌘T; pass `command: false` explicitly if a combo should
    /// omit Command (none here do).
    static let all: [ShortcutAction] = [
        // File
        ShortcutAction(id: "newTab", title: "New Tab", category: .file, defaultShortcut: ShortcutModel(key: "t")),
        ShortcutAction(id: "newWindow", title: "New Window", category: .file, defaultShortcut: ShortcutModel(key: "n")),
        ShortcutAction(id: "openFile", title: "Open", category: .file, defaultShortcut: ShortcutModel(key: "o")),
        ShortcutAction(id: "closeTab", title: "Close Tab", category: .file, defaultShortcut: ShortcutModel(key: "w")),
        ShortcutAction(id: "save", title: "Save", category: .file, defaultShortcut: ShortcutModel(key: "s")),
        ShortcutAction(id: "saveAs", title: "Save As", category: .file, defaultShortcut: ShortcutModel(key: "s", shift: true)),
        ShortcutAction(id: "print", title: "Print", category: .file, defaultShortcut: ShortcutModel(key: "p")),

        // Edit
        ShortcutAction(id: "search", title: "Find", category: .edit, defaultShortcut: ShortcutModel(key: "f")),
        ShortcutAction(id: "copyPage", title: "Copy Page", category: .edit, defaultShortcut: ShortcutModel(key: "c")),
        ShortcutAction(id: "cutPage", title: "Cut Page", category: .edit, defaultShortcut: ShortcutModel(key: "x")),
        ShortcutAction(id: "pastePage", title: "Paste Page", category: .edit, defaultShortcut: ShortcutModel(key: "v")),
        ShortcutAction(id: "deletePage", title: "Delete Page", category: .edit, defaultShortcut: ShortcutModel(key: "⌫")),
        ShortcutAction(id: "rotateClockwise", title: "Rotate Clockwise", category: .edit, defaultShortcut: ShortcutModel(key: "r")),
        ShortcutAction(id: "rotateCounterClockwise", title: "Rotate Counter-Clockwise", category: .edit, defaultShortcut: ShortcutModel(key: "r", shift: true)),

        // View
        ShortcutAction(id: "toggleSidebar", title: "Toggle Sidebar", category: .view, defaultShortcut: ShortcutModel(key: "s", option: true)),
        ShortcutAction(id: "toggleComments", title: "Toggle Comments", category: .view, defaultShortcut: ShortcutModel(key: "e", option: true)),
        ShortcutAction(id: "toggleTopBar", title: "Toggle Top Bar", category: .view, defaultShortcut: ShortcutModel(key: "b", shift: true)),
        ShortcutAction(id: "toggleToolbar", title: "Toggle Toolbar", category: .view, defaultShortcut: ShortcutModel(key: "t", shift: true)),
        ShortcutAction(id: "togglePageIndicator", title: "Toggle Page Number", category: .view, defaultShortcut: ShortcutModel(key: "p", shift: true)),
        ShortcutAction(id: "enterFullScreen", title: "Enter Full Screen", category: .view, defaultShortcut: ShortcutModel(key: "f", control: true)),

        // Zoom
        ShortcutAction(id: "zoomIn", title: "Zoom In", category: .zoom, defaultShortcut: ShortcutModel(key: "+")),
        ShortcutAction(id: "zoomOut", title: "Zoom Out", category: .zoom, defaultShortcut: ShortcutModel(key: "-")),
        ShortcutAction(id: "actualSize", title: "Actual Size", category: .zoom, defaultShortcut: ShortcutModel(key: "0")),
        ShortcutAction(id: "zoomToFit", title: "Zoom to Fit", category: .zoom, defaultShortcut: ShortcutModel(key: "f", option: true)),

        // Navigation
        ShortcutAction(id: "goBack", title: "Back", category: .navigation, defaultShortcut: ShortcutModel(key: "[")),
        ShortcutAction(id: "goForward", title: "Forward", category: .navigation, defaultShortcut: ShortcutModel(key: "]")),
        ShortcutAction(id: "nextPage", title: "Next Page", category: .navigation, defaultShortcut: ShortcutModel(key: "↓")),
        ShortcutAction(id: "previousPage", title: "Previous Page", category: .navigation, defaultShortcut: ShortcutModel(key: "↑")),
        ShortcutAction(id: "firstPage", title: "First Page", category: .navigation, defaultShortcut: ShortcutModel(key: "←", option: true)),
        ShortcutAction(id: "lastPage", title: "Last Page", category: .navigation, defaultShortcut: ShortcutModel(key: "→", option: true)),
        ShortcutAction(id: "goToPage", title: "Go to Page", category: .navigation, defaultShortcut: ShortcutModel(key: "g", option: true)),

        // Annotations
        ShortcutAction(id: "highlight", title: "Highlight", category: .annotations, defaultShortcut: ShortcutModel(key: "y")),
        ShortcutAction(id: "underline", title: "Underline", category: .annotations, defaultShortcut: ShortcutModel(key: "u")),
        ShortcutAction(id: "comment", title: "Add Comment", category: .annotations, defaultShortcut: ShortcutModel(key: "e")),
        ShortcutAction(id: "bookmark", title: "Toggle Bookmark", category: .annotations, defaultShortcut: ShortcutModel(key: "d")),

        // Markdown
        ShortcutAction(id: "copyPageAsMarkdown", title: "Copy Page as Markdown", category: .markdown, defaultShortcut: ShortcutModel(key: "m", shift: true)),
        ShortcutAction(id: "copyDocumentAsMarkdown", title: "Copy Document as Markdown", category: .markdown, defaultShortcut: ShortcutModel(key: "m", shift: true, option: true)),

        // Tabs
        ShortcutAction(id: "searchTabs", title: "Search Tabs", category: .tabs, defaultShortcut: ShortcutModel(key: "a", shift: true)),
        ShortcutAction(id: "selectNextTab", title: "Select Next Tab", category: .tabs, defaultShortcut: ShortcutModel(key: "]", shift: true)),
        ShortcutAction(id: "selectPreviousTab", title: "Select Previous Tab", category: .tabs, defaultShortcut: ShortcutModel(key: "[", shift: true))
    ]

    /// id → default binding, consumed by `ShortcutModel.current(for:)`.
    static let defaults: [String: ShortcutModel] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0.defaultShortcut) }
    )

    static func action(for id: String) -> ShortcutAction? {
        all.first { $0.id == id }
    }

    /// Actions grouped by category in declaration order — drives the Settings list.
    static func grouped() -> [(ShortcutAction.Category, [ShortcutAction])] {
        ShortcutAction.Category.allCases.compactMap { category in
            let actions = all.filter { $0.category == category }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    // MARK: - Validation

    /// The action currently bound to the same combo as `shortcut`, excluding
    /// `actionID` — used to warn the user before they create a dead shortcut.
    static func conflictingAction(forCombo shortcut: ShortcutModel, excluding actionID: String) -> ShortcutAction? {
        let combo = shortcut.displayString
        return all.first { $0.id != actionID && ShortcutModel.current(for: $0.id).displayString == combo }
    }

    /// Whether a candidate shortcut may be assigned to `actionID`.
    static func validate(_ shortcut: ShortcutModel, for actionID: String) -> ShortcutValidation {
        if shortcut.isReserved { return .reserved }
        if !shortcut.hasCommandOrControl { return .needsCommand }
        if let other = conflictingAction(forCombo: shortcut, excluding: actionID) {
            return .conflict(other.title)
        }
        return .ok
    }
}

/// Result of vetting a candidate shortcut. `reserved` and `needsCommand` block
/// assignment; `conflict` only warns (the user may deliberately reassign).
enum ShortcutValidation: Equatable {
    case ok
    case reserved
    case needsCommand
    case conflict(String)

    /// Hard problems the recorder must not let the user confirm.
    var blocksConfirm: Bool {
        self == .reserved || self == .needsCommand
    }

    var warning: String? {
        switch self {
        case .ok: return nil
        case .reserved: return "Reserved by macOS"
        case .needsCommand: return "Needs ⌘ or ⌃"
        case .conflict(let title): return "Used by \(title)"
        }
    }
}

extension ShortcutModel {
    /// System / standard combos a user must not reassign (Apple HIG). Limited to
    /// plain-⌘ combos the app can actually receive (⌘Space, ⌘Tab, ⌃-arrows are
    /// swallowed by the OS before they reach the recorder).
    var isReserved: Bool {
        command && !shift && !option && !control && ["q", "h", "m", ",", "`"].contains(key.lowercased())
    }

    /// A shortcut must carry ⌘ or ⌃ so it can't shadow plain typing (⇧/⌥ alone
    /// produce characters).
    var hasCommandOrControl: Bool {
        command || control
    }
}
