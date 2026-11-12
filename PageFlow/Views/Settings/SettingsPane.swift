//
//  SettingsPane.swift
//  PageFlow
//
//  The Settings window's panes and what its search finds in them.
//

import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case notes
    case books
    case annotations
    case shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .notes: "Notes"
        case .books: "Books"
        case .annotations: "Highlights & Comments"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notes: "doc.text"
        case .books: "book"
        case .annotations: "highlighter"
        case .shortcuts: "keyboard"
        }
    }

    /// The settings a pane holds, as a search reads them. A new control adds its
    /// label here, with the other words someone might look for it by.
    fileprivate var entries: [(title: String, keywords: String)] {
        switch self {
        case .general:
            [("Always show top bar", "tabs chrome hide"),
             ("Always show toolbar", "chrome hide"),
             ("Always show page number", "status chip indicator word count"),
             ("Compact tabs", "deck"),
             ("Keep this window on top", "float always"),
             ("Toolbar size", "scale bigger smaller"),
             ("Magnify toolbar icons on hover", "dock zoom"),
             ("Show button tooltips on hover", "help"),
             ("Show navigation rail", "thumbnails markers previews"),
             ("Show the rail only at the edge", "hover pointer"),
             ("Version", "about")]
        case .notes:
            [("Color scheme", "markdown theme light dark appearance"),
             ("Font", "markdown typeface family"),
             ("Font size", "markdown text bigger smaller"),
             ("Side margins", "markdown width whitespace"),
             ("Page look", "markdown centered reading column"),
             ("Center when zoomed out", "markdown"),
             ("Show hidden-content row", "markdown folding comments")]
        case .books:
            [("Book theme", "epub light dark sepia system appearance color scheme"),
             ("Book font", "epub typeface family serif")]
        case .annotations:
            [("Highlight colors", "presets markup"),
             ("Underline colors", "presets markup"),
             ("Comment colors", "presets notes"),
             ("Reset colors", "defaults")]
        case .shortcuts:
            [("Reset all shortcuts", "defaults keyboard")]
        }
    }
}

/// One thing the Settings search found.
struct SettingsSearchResult: Identifiable, Equatable {
    let pane: SettingsPane
    let title: String
    /// Set when the result is a shortcut: the Shortcuts pane opens searching for it.
    var shortcutQuery: String?
    /// Two commands of different types can share a title, so a shortcut goes by its id.
    var shortcutID: String?

    var id: String { "\(pane.rawValue)/\(shortcutID ?? title)" }
}

enum SettingsSearch {
    /// Settings first, by pane order, then shortcuts. Every word of the query must match.
    static func results(for query: String) -> [SettingsSearchResult] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        let settings = SettingsPane.allCases.flatMap { pane in
            pane.entries
                .filter { entry in
                    let text = "\(pane.title) \(entry.title) \(entry.keywords)".lowercased()
                    return words.allSatisfy(text.contains)
                }
                .map { SettingsSearchResult(pane: pane, title: $0.title) }
        }
        let shortcuts = ShortcutCatalog.all
            .filter { ShortcutCatalog.matches($0, query: query) }
            .map { SettingsSearchResult(pane: .shortcuts, title: $0.title, shortcutQuery: $0.title, shortcutID: $0.id) }
        return settings + shortcuts
    }
}
