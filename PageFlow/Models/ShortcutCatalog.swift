//
//  ShortcutCatalog.swift
//  PageFlow
//
//  The single source of truth for every keyboard shortcut: its id, display
//  title, category, scope and default binding. `ShortcutModel.defaults`, the
//  Settings list, the menus and the Markdown editor's own chords are all
//  DERIVED from `ShortcutCatalog.all`, so a command can never have a key in
//  one place but not the other. Every shortcut is rebindable. Adding one =
//  one entry here + `.keyboardShortcut(for: id)` on the command (or an
//  `editorCommand` for one the Markdown editor handles itself).
//

import Foundation
import MarkdownEngine

/// One user-rebindable command: a stable `id` (the key into `customShortcuts`),
/// a human title for Settings, the Settings section it belongs to, and its
/// factory-default binding (`.none` for a command that starts with no key).
struct ShortcutAction: Identifiable, Equatable {
    let id: String
    let title: String
    let category: Category
    let defaultShortcut: ShortcutModel
    /// Where the command acts. Commands of different content types may share
    /// a key: ⌘U underlines Markdown text and annotates a PDF selection.
    var scope: Scope = .app
    /// A key without ⌘ or ⌃ is allowed: a function key, or a command that
    /// acts only outside the text (so a typed character is never taken).
    var allowsPlainKeys = false
    /// The Markdown editor's own command this row binds, when the focused
    /// editor handles it before the menus (MarkdownEditorConfiguration.keyBindings).
    var editorCommand: MarkdownEditorKeyCommand?

    enum Scope: Hashable {
        /// `pages`: any paged document, PDF or EPUB (page turns, bookmarks, fit).
        case app, pdf, epub, markdown, pages, pdfAndMarkdown

        func overlaps(_ other: Scope) -> Bool {
            !contentTypes.isDisjoint(with: other.contentTypes)
        }

        private var contentTypes: Set<Scope> {
            switch self {
            case .app: return [.pdf, .epub, .markdown]
            case .pages: return [.pdf, .epub]
            case .pdfAndMarkdown: return [.pdf, .markdown]
            case .pdf, .epub, .markdown: return [self]
            }
        }
    }

    /// Settings sections, rendered in declaration order.
    enum Category: String, CaseIterable {
        case file = "File"
        case edit = "Edit"
        case format = "Format (Markdown)"
        case comments = "Comments (Markdown)"
        case view = "View"
        case zoom = "Zoom"
        case navigation = "Navigation"
        case annotations = "Annotations"
        case markdown = "PDF to Markdown"
        case tabs = "Tabs"
    }
}

enum ShortcutCatalog {
    /// Every command with a shortcut. Order within a category is the Settings
    /// order. NOTE: the `ShortcutModel` initializer defaults `command: true`,
    /// so a "bare" key like `"t"` is ⌘T; pass `command: false` explicitly for
    /// a combo without Command.
    static let all: [ShortcutAction] = [
        // File
        ShortcutAction(id: "newTab", title: "New Tab", category: .file, defaultShortcut: ShortcutModel(key: "t")),
        ShortcutAction(id: "newMarkdownDocument", title: "New Markdown Document", category: .file, defaultShortcut: ShortcutModel(key: "n")),
        ShortcutAction(id: "newWindow", title: "New Window", category: .file, defaultShortcut: ShortcutModel(key: "n", shift: true)),
        ShortcutAction(id: "openFile", title: "Open", category: .file, defaultShortcut: ShortcutModel(key: "o")),
        ShortcutAction(id: "closeTab", title: "Close Tab", category: .file, defaultShortcut: ShortcutModel(key: "w")),
        ShortcutAction(id: "save", title: "Save", category: .file, defaultShortcut: ShortcutModel(key: "s"), scope: .pdfAndMarkdown),
        ShortcutAction(id: "saveAs", title: "Save As", category: .file, defaultShortcut: ShortcutModel(key: "s", shift: true)),
        ShortcutAction(id: "print", title: "Print", category: .file, defaultShortcut: ShortcutModel(key: "p")),

        // Edit
        ShortcutAction(id: "undo", title: "Undo", category: .edit, defaultShortcut: ShortcutModel(key: "z")),
        ShortcutAction(id: "redo", title: "Redo", category: .edit, defaultShortcut: ShortcutModel(key: "z", shift: true)),
        ShortcutAction(id: "search", title: "Find", category: .edit, defaultShortcut: ShortcutModel(key: "f")),
        // ⌥⌘F: the macOS convention (Xcode, Pages).
        ShortcutAction(id: "findAndReplace", title: "Find and Replace", category: .edit, defaultShortcut: ShortcutModel(key: "f", option: true), scope: .markdown),
        ShortcutAction(id: "findNext", title: "Find Next", category: .edit, defaultShortcut: ShortcutModel(key: "g")),
        ShortcutAction(id: "findPrevious", title: "Find Previous", category: .edit, defaultShortcut: ShortcutModel(key: "g", shift: true)),
        ShortcutAction(id: "copyPage", title: "Copy Page", category: .edit, defaultShortcut: ShortcutModel(key: "c"), scope: .pdf),
        ShortcutAction(id: "cutPage", title: "Cut Page", category: .edit, defaultShortcut: ShortcutModel(key: "x"), scope: .pdf),
        ShortcutAction(id: "pastePage", title: "Paste Page", category: .edit, defaultShortcut: ShortcutModel(key: "v"), scope: .pdf),
        ShortcutAction(id: "deletePage", title: "Delete Page", category: .edit, defaultShortcut: ShortcutModel(key: "⌫"), scope: .pdf),
        // ⌥⌘N: a new page, beside ⌘N / ⇧⌘N; ⇧ adds the file variant, as ⇧⌘R does for rotation.
        ShortcutAction(id: "insertBlankPage", title: "Insert Blank Page", category: .edit, defaultShortcut: ShortcutModel(key: "n", option: true), scope: .pdf),
        ShortcutAction(id: "insertPagesFromFile", title: "Insert Pages from File", category: .edit, defaultShortcut: ShortcutModel(key: "n", shift: true, option: true), scope: .pdf),
        ShortcutAction(id: "rotateClockwise", title: "Rotate Clockwise", category: .edit, defaultShortcut: ShortcutModel(key: "r"), scope: .pdf),
        ShortcutAction(id: "rotateCounterClockwise", title: "Rotate Counter-Clockwise", category: .edit, defaultShortcut: ShortcutModel(key: "r", shift: true), scope: .pdf),

        // Format (Markdown): the Format menu and the focused editor share these.
        format("bold", "Bold", ShortcutModel(key: "b"), .bold),
        format("italic", "Italic", ShortcutModel(key: "i"), .italic),
        format("strikethrough", "Strikethrough", ShortcutModel(key: "x", shift: true), .strikethrough),
        // ⌘E is Center, so Code takes ⇧⌘C.
        format("code", "Code", ShortcutModel(key: "c", shift: true), .inlineCode),
        format("link", "Link", ShortcutModel(key: "k"), .link),
        // ⌥⌘7 after the heading run: the ⌘0 family is zoom in every tab (⌥⌘0 is Zoom to Fit).
        format("text", "Normal Text", ShortcutModel(key: "7", option: true), .paragraph),
        format("heading", "Heading 1", ShortcutModel(key: "1", option: true), .heading1),
        format("heading2", "Heading 2", ShortcutModel(key: "2", option: true), .heading2),
        format("heading3", "Heading 3", ShortcutModel(key: "3", option: true), .heading3),
        format("heading4", "Heading 4", ShortcutModel(key: "4", option: true), .heading4),
        format("heading5", "Heading 5", ShortcutModel(key: "5", option: true), .heading5),
        format("heading6", "Heading 6", ShortcutModel(key: "6", option: true), .heading6),
        // ⇧⌘8 / ⇧⌘7: the word processor list chords.
        format("bulletedList", "Bulleted List", ShortcutModel(key: "8", shift: true), .bulletedList),
        format("numberedList", "Numbered List", ShortcutModel(key: "7", shift: true), .numberedList),
        format("checklist", "Checklist", ShortcutModel(key: "l", shift: true), .checklist),
        format("quote", "Quote", ShortcutModel(key: "9", shift: true), .quote),
        format("codeBlock", "Code Block", ShortcutModel(key: "c", option: true), .codeBlock),
        format("table", "Table", ShortcutModel(key: "t", option: true), .insertTable),
        format("divider", "Divider", .none, nil),
        // Word-processor alignment; ⌘E / ⌘R keep their PDF meanings in PDF tabs.
        format("alignLeft", "Align Left", ShortcutModel(key: "l"), .alignLeft),
        format("alignCenter", "Center", ShortcutModel(key: "e"), .alignCenter),
        format("alignRight", "Align Right", ShortcutModel(key: "r"), .alignRight),
        format("alignJustify", "Justify", ShortcutModel(key: "j"), .alignJustify),
        format("clearFormatting", "Clear Formatting", ShortcutModel(key: "\\"), .clearFormatting),
        format("moveLineUp", "Move Line Up", ShortcutModel(key: "↑", control: true), .moveLinesUp),
        format("moveLineDown", "Move Line Down", ShortcutModel(key: "↓", control: true), .moveLinesDown),
        format("toggleChecked", "Check or Uncheck Item", ShortcutModel(key: "↩"), .toggleChecked),
        ShortcutAction(id: "format.focusSelectionBar", title: "Move to the Selection Bar", category: .format,
                       defaultShortcut: ShortcutModel(key: "F6", command: false), scope: .markdown, allowsPlainKeys: true,
                       editorCommand: .focusSelectionBar),
        ShortcutAction(id: "format.tableCellActions", title: "Cell Actions (in a table)", category: .format,
                       defaultShortcut: ShortcutModel(key: "F10", command: false, shift: true), scope: .markdown,
                       allowsPlainKeys: true, editorCommand: .tableCellActions),

        // View
        ShortcutAction(id: "toggleSidebar", title: "Toggle Sidebar", category: .view, defaultShortcut: ShortcutModel(key: "s", option: true)),
        // One key for every tab: PDF's comments panel, a book's notes and Markdown's comments
        // (the editor takes it too, so it also works from a comment card).
        // Upgrades retain a custom Markdown panel key until the shared row is edited.
        ShortcutAction(id: "toggleComments", title: "Toggle Comments or Notes", category: .view, defaultShortcut: ShortcutModel(key: "e", option: true),
                       editorCommand: .toggleComments),
        ShortcutAction(id: "toggleTopBar", title: "Toggle Top Bar", category: .view, defaultShortcut: ShortcutModel(key: "b", shift: true)),
        // ⌃⌘T: ⇧⌘T went to Reopen Closed Tab, and ⌥⌘T is Table in a note.
        ShortcutAction(id: "toggleToolbar", title: "Toggle Toolbar", category: .view, defaultShortcut: ShortcutModel(key: "t", control: true)),
        ShortcutAction(id: "togglePageIndicator", title: "Toggle Page Number", category: .view, defaultShortcut: ShortcutModel(key: "p", shift: true)),
        // A book's Read Aloud (View ▸ Start Speaking, Pause Speaking).
        ShortcutAction(id: "readAloud", title: "Start or Stop Speaking", category: .view,
                       defaultShortcut: ShortcutModel(key: "r", option: true), scope: .epub),
        ShortcutAction(id: "pauseReadAloud", title: "Pause or Resume Speaking", category: .view,
                       defaultShortcut: ShortcutModel(key: "p", option: true), scope: .epub),

        ShortcutAction(id: "markdown.toggleFold", title: "Toggle Section", category: .view,
                       defaultShortcut: ShortcutModel(key: "↩", option: true), scope: .markdown, editorCommand: .toggleFold),
        ShortcutAction(id: "markdown.collapseAll", title: "Collapse All Sections", category: .view,
                       defaultShortcut: .none, scope: .markdown, editorCommand: .collapseAll),
        ShortcutAction(id: "markdown.expandAll", title: "Expand All Sections", category: .view,
                       defaultShortcut: .none, scope: .markdown, editorCommand: .expandAll),

        // Zoom
        ShortcutAction(id: "zoomIn", title: "Zoom In", category: .zoom, defaultShortcut: ShortcutModel(key: "+")),
        ShortcutAction(id: "zoomOut", title: "Zoom Out", category: .zoom, defaultShortcut: ShortcutModel(key: "-")),
        ShortcutAction(id: "actualSize", title: "Actual Size", category: .zoom, defaultShortcut: ShortcutModel(key: "0")),
        ShortcutAction(id: "zoomToFit", title: "Zoom to Fit", category: .zoom, defaultShortcut: ShortcutModel(key: "0", option: true), scope: .app),

        // Navigation
        ShortcutAction(id: "goBack", title: "Back", category: .navigation, defaultShortcut: ShortcutModel(key: "[")),
        ShortcutAction(id: "goForward", title: "Forward", category: .navigation, defaultShortcut: ShortcutModel(key: "]")),
        ShortcutAction(id: "nextPage", title: "Next Page", category: .navigation, defaultShortcut: ShortcutModel(key: "↓"), scope: .pages),
        ShortcutAction(id: "previousPage", title: "Previous Page", category: .navigation, defaultShortcut: ShortcutModel(key: "↑"), scope: .pages),
        ShortcutAction(id: "firstPage", title: "First Page", category: .navigation, defaultShortcut: ShortcutModel(key: "←", option: true), scope: .pages),
        ShortcutAction(id: "lastPage", title: "Last Page", category: .navigation, defaultShortcut: ShortcutModel(key: "→", option: true), scope: .pages),
        ShortcutAction(id: "bookmark", title: "Toggle Bookmark", category: .navigation, defaultShortcut: ShortcutModel(key: "d"), scope: .pages),
        ShortcutAction(id: "goToPage", title: "Go to Page or Line", category: .navigation, defaultShortcut: ShortcutModel(key: "g", option: true)),

        // One Settings row across readers and the focused Markdown editor.
        ShortcutAction(id: "highlight", title: "Highlight", category: .annotations,
                       defaultShortcut: ShortcutModel(key: "h", shift: true), editorCommand: .highlight),
        ShortcutAction(id: "underline", title: "Underline", category: .annotations,
                       defaultShortcut: ShortcutModel(key: "u"), editorCommand: .underline),
        ShortcutAction(id: "comment", title: "Add Comment or Note", category: .annotations,
                       defaultShortcut: ShortcutModel(key: "k", shift: true), editorCommand: .comment),


        // PDF to Markdown
        ShortcutAction(id: "copyPageAsMarkdown", title: "Copy Page as Markdown", category: .markdown, defaultShortcut: ShortcutModel(key: "m", shift: true), scope: .pdf),
        ShortcutAction(id: "copyDocumentAsMarkdown", title: "Copy Document as Markdown", category: .markdown, defaultShortcut: ShortcutModel(key: "m", shift: true, option: true), scope: .pdf),

        // Tabs
        ShortcutAction(id: "searchTabs", title: "Search Tabs", category: .tabs, defaultShortcut: ShortcutModel(key: "a", shift: true)),
        ShortcutAction(id: "reopenClosedTab", title: "Reopen Closed Tab", category: .tabs, defaultShortcut: ShortcutModel(key: "t", shift: true)),
        ShortcutAction(id: "moveTabToNewWindow", title: "Move Tab to New Window", category: .tabs, defaultShortcut: .none),
        ShortcutAction(id: "mergeAllWindows", title: "Merge All Windows", category: .tabs, defaultShortcut: .none),
        ShortcutAction(id: "selectNextTab", title: "Select Next Tab", category: .tabs, defaultShortcut: ShortcutModel(key: "]", shift: true)),
        ShortcutAction(id: "selectPreviousTab", title: "Select Previous Tab", category: .tabs, defaultShortcut: ShortcutModel(key: "[", shift: true)),
        // Handled ahead of the focused view (TabCycleKeyboard), so an editor never types them.
        ShortcutAction(id: "selectRecentTab", title: "Select Previously Used Tab", category: .tabs,
                       defaultShortcut: ShortcutModel(key: "⇥", command: false, control: true)),
        ShortcutAction(id: "selectRecentTabReversed", title: "Select Previously Used Tab, Reversed", category: .tabs,
                       defaultShortcut: ShortcutModel(key: "⇥", command: false, shift: true, control: true)),
    ] + (1...9).map { number in
        ShortcutAction(id: selectTabID(number), title: "Select Tab \(number)", category: .tabs, defaultShortcut: ShortcutModel(key: "\(number)"))
    }

    /// A Format (Markdown) row: `format.‹command›`, bound in the Format menu and the editor.
    private static func format(_ name: String, _ title: String, _ shortcut: ShortcutModel,
                               _ command: MarkdownEditorKeyCommand?) -> ShortcutAction {
        ShortcutAction(id: "format.\(name)", title: title, category: .format, defaultShortcut: shortcut,
                       scope: .markdown, editorCommand: command)
    }

    static func selectTabID(_ number: Int) -> String { "selectTab\(number)" }

    /// These IDs may still be present in saved preferences. They are lookup
    /// aliases, never a second visible Settings registration.
    static let legacyMarkdownIDs = ["comment": "markdownComment", "highlight": "format.highlight",
                                    "underline": "format.underline", "toggleComments": "markdownToggleComments"]

    static func canonicalID(for id: String) -> String {
        legacyMarkdownIDs.first { $0.value == id }?.key ?? id
    }

    /// Reading an old preference must not rewrite it. If two explicit values
    /// differ, each original context keeps its value until a common save.
    static func shortcut(for id: String, saved: [String: ShortcutModel]) -> ShortcutModel {
        if let own = saved[id] { return own }
        let canonical = canonicalID(for: id)
        if let common = saved[canonical] { return common }
        // The old Markdown panel accepted typing keys outside prose. Keep that
        // override in its editor so upgrading cannot install it as an app-wide key.
        if canonical != "toggleComments", let legacyID = legacyMarkdownIDs[canonical], let legacy = saved[legacyID] { return legacy }
        let fallback = defaults[canonical] ?? .none
        if newDefaultIDs.contains(canonical), let owner = action(for: canonical), saved.contains(where: { otherID, shortcut in
            canonicalID(for: otherID) != canonical && shortcut.hasSameChord(as: fallback)
                && (action(for: otherID)?.scope.overlaps(owner.scope) ?? false)
        }) { return .none }
        return fallback
    }

    /// Commands that gained or changed a default after people had saved bindings.
    private static let newDefaultIDs = ["reopenClosedTab", "toggleToolbar", "selectRecentTab", "selectRecentTabReversed"]

    /// id → default binding, consumed by `ShortcutModel.current(for:)`.
    static let defaults: [String: ShortcutModel] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0.defaultShortcut) }
    )

    static func action(for id: String) -> ShortcutAction? {
        all.first { $0.id == canonicalID(for: id) }
    }

    /// Actions grouped by category in declaration order — drives the Settings list.
    static func grouped() -> [(ShortcutAction.Category, [ShortcutAction])] {
        ShortcutAction.Category.allCases.compactMap { category in
            let actions = all.filter { $0.category == category }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    // MARK: - Search

    /// Whether `action` answers a Settings search: its title or section holds
    /// the text, or its key does. Keys may be typed as symbols or words in any
    /// order: "⌘B", "cmd b", "shift cmd n", "⌥⌘M".
    static func matches(_ action: ShortcutAction, query: String,
                        current lookup: (String) -> ShortcutModel = ShortcutModel.current(for:)) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        if action.title.lowercased().contains(text) || action.category.rawValue.lowercased().contains(text) { return true }
        // A key search names at least one modifier.
        let symbols: [Character: WritableKeyPath<ShortcutModel, Bool>] = ["⌘": \.command, "⇧": \.shift, "⌥": \.option, "⌃": \.control]
        let words: [String: WritableKeyPath<ShortcutModel, Bool>] = [
            "cmd": \.command, "command": \.command, "shift": \.shift, "opt": \.option, "option": \.option,
            "alt": \.option, "ctrl": \.control, "control": \.control,
        ]
        var wanted = ShortcutModel(key: "", command: false)
        var rest: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "+" }) {
            if let modifier = words[String(token)] { wanted[keyPath: modifier] = true; continue }
            let keys = token.filter { symbols[$0] == nil }
            for character in token where symbols[character] != nil { wanted[keyPath: symbols[character]!] = true }
            if !keys.isEmpty { rest.append(String(keys)) }
        }
        guard wanted.hasModifier, rest.count <= 1 else { return false }
        return effectiveBindings(for: action, current: lookup).contains { binding in
            let shortcut = binding.shortcut
            guard !shortcut.isNone else { return false }
            if let key = rest.first {
                return key == shortcut.key.lowercased() && wanted.command == shortcut.command && wanted.shift == shortcut.shift
                    && wanted.option == shortcut.option && wanted.control == shortcut.control
            }
            return (!wanted.command || shortcut.command) && (!wanted.shift || shortcut.shift)
                && (!wanted.option || shortcut.option) && (!wanted.control || shortcut.control)
        }
    }

    // MARK: - The Markdown editor's chords

    /// The focused Markdown editor prefers its retained legacy value only when
    /// an older build saved different values for the two content contexts.
    static func editorKeyBindings(current lookup: (String) -> ShortcutModel = ShortcutModel.currentForMarkdown(for:)) -> MarkdownKeyBindings {
        var bindings = MarkdownKeyBindings([:])
        for action in all {
            guard let command = action.editorCommand else { continue }
            let current = lookup(action.id)
            bindings[command] = ([current] + alternateShortcuts(for: action, current: current)).compactMap(\.editorChord)
        }
        return bindings
    }

    // MARK: - Validation

    /// Alternate keys are live only while the primary retains its default.
    /// Both the editor and conflict validation consume this derivation.
    static func alternateShortcuts(for action: ShortcutAction, current: ShortcutModel) -> [ShortcutModel] {
        guard action.editorCommand == .focusSelectionBar, current.hasSameChord(as: action.defaultShortcut) else { return [] }
        return [ShortcutModel(key: "F6"), ShortcutModel(key: "F10", command: false, option: true)]
    }

    struct EffectiveBinding {
        let id: String
        let scope: ShortcutAction.Scope
        let shortcut: ShortcutModel
    }

    /// Legacy annotation values can differ across content types. Each retains
    /// its scope, so replacement never removes a disjoint context's choice.
    private static func effectiveBindings(for action: ShortcutAction, current lookup: (String) -> ShortcutModel) -> [EffectiveBinding] {
        if let legacy = legacyMarkdownIDs[action.id] {
            return [EffectiveBinding(id: action.id, scope: .pages, shortcut: lookup(action.id)),
                    EffectiveBinding(id: legacy, scope: .markdown, shortcut: lookup(legacy))]
        }
        let current = lookup(action.id)
        return ([current] + alternateShortcuts(for: action, current: current)).map {
            EffectiveBinding(id: action.id, scope: action.scope, shortcut: $0)
        }
    }

    static func conflictingBindings(forCombo shortcut: ShortcutModel, excluding actionID: String,
                                    saved: [String: ShortcutModel]) -> [(action: ShortcutAction, binding: EffectiveBinding)] {
        guard !shortcut.isNone else { return [] }
        let canonical = canonicalID(for: actionID)
        let scope = action(for: canonical)?.scope ?? .app
        return all.filter { $0.id != canonical }.flatMap { action in
            effectiveBindings(for: action, current: { self.shortcut(for: $0, saved: saved) }).filter {
                $0.scope.overlaps(scope) && $0.shortcut.hasSameChord(as: shortcut)
            }.map { (action: action, binding: $0) }
        }
    }

    static func conflictingActions(forCombo shortcut: ShortcutModel, excluding actionID: String) -> [ShortcutAction] {
        let conflicts = conflictingBindings(forCombo: shortcut, excluding: actionID, saved: SettingsManager.shared.customShortcuts)
        return all.filter { action in conflicts.contains { $0.action.id == action.id } }
    }

    /// The first owner supplies the inline warning; confirmation lists all owners.
    static func conflictingAction(forCombo shortcut: ShortcutModel, excluding actionID: String) -> ShortcutAction? {
        conflictingActions(forCombo: shortcut, excluding: actionID).first
    }

    /// Whether a candidate shortcut may be assigned to `actionID`.
    static func validate(_ shortcut: ShortcutModel, for actionID: String) -> ShortcutValidation {
        if shortcut.isNone { return .ok }
        if shortcut.isReserved { return .reserved }
        let allowsPlainKeys = action(for: actionID)?.allowsPlainKeys ?? false
        if !shortcut.hasCommandOrControl, !(allowsPlainKeys && (shortcut.isFunctionKey || shortcut.hasModifier)) {
            return .needsCommand
        }
        if let other = conflictingAction(forCombo: shortcut, excluding: actionID) {
            return .conflict(other.title)
        }
        return .ok
    }
}

/// Result of vetting a candidate shortcut. `reserved` and `needsCommand`
/// block assignment; `conflict` requires a deliberate Replace confirmation.
enum ShortcutValidation: Equatable {
    case ok
    case reserved
    case needsCommand
    case conflict(String)

    /// Hard problems the recorder must not let the user confirm.
    var blocksConfirm: Bool {
        switch self {
        case .reserved, .needsCommand: return true
        case .ok, .conflict: return false
        }
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
