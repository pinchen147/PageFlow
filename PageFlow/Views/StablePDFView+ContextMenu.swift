//
//  StablePDFView+ContextMenu.swift
//  PageFlow
//
//  Context menu building for annotations, comments, and page-level actions.
//

import PDFKit
import AppKit

extension StablePDFView {

    // MARK: - Context Menu Dispatch

    func buildContextMenu(for event: NSEvent, at viewPoint: NSPoint) -> NSMenu {
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)

            if let annotation = findCommentAnnotation(at: pagePoint, on: page) {
                pendingCommentAnnotation = annotation
                return buildCommentContextMenu(for: annotation)
            }

            if let annotation = findMarkupAnnotation(at: pagePoint, on: page) {
                pendingRemovalAnnotation = annotation
                return buildAnnotationContextMenu(for: annotation)
            }
        }

        return buildFilteredDefaultMenu(for: event)
    }

    // MARK: - Default Page Menu

    private func buildFilteredDefaultMenu(for event: NSEvent) -> NSMenu {
        guard let defaultMenu = super.menu(for: event) else {
            return buildFallbackPageMenu()
        }

        let filteredItems = defaultMenu.items.filter { item in
            if item.submenu?.identifier?.rawValue == "NSServicesSubmenu" {
                return false
            }
            if item.title == "Services" {
                return false
            }
            return true
        }

        let menu = NSMenu()
        for item in filteredItems {
            if let copy = item.copy() as? NSMenuItem {
                menu.addItem(copy)
            }
        }

        applyKeyboardShortcuts(to: menu)

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        appendPageMenuItems(to: menu)

        return menu
    }

    // MARK: - Annotation Hit Testing

    private func findMarkupAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        if let annotation = page.annotation(at: point),
           isRemovableMarkup(annotation) {
            return annotation
        }

        let tolerance: CGFloat = 10.0
        let searchRect = CGRect(
            x: point.x - tolerance,
            y: point.y - tolerance,
            width: tolerance * 2,
            height: tolerance * 2
        )

        for annotation in page.annotations {
            guard isRemovableMarkup(annotation) else { continue }
            if annotation.bounds.intersects(searchRect) {
                return annotation
            }
        }

        return nil
    }

    private func findCommentAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        if let annotation = page.annotation(at: point),
           isCommentAnnotation(annotation) {
            return annotation
        }

        let tolerance: CGFloat = 10.0
        let searchRect = CGRect(
            x: point.x - tolerance,
            y: point.y - tolerance,
            width: tolerance * 2,
            height: tolerance * 2
        )

        for annotation in page.annotations {
            guard isCommentAnnotation(annotation) else { continue }
            if annotation.bounds.intersects(searchRect) {
                return annotation
            }
        }

        return nil
    }

    // MARK: - Annotation Type Checks

    private func isRemovableMarkup(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }

        let typeLower = type.lowercased()
        let isMarkup = typeLower.contains("highlight") || typeLower.contains("underline")

        guard isMarkup else { return false }

        if let userName = annotation.userName,
           UUID(uuidString: userName) != nil {
            return false
        }

        return true
    }

    private func isHighlightAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.type?.lowercased().contains("highlight") ?? false
    }

    private func isCommentAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName.flatMap { UUID(uuidString: $0) } != nil
    }

    // MARK: - Annotation Context Menu

    private func buildAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let isHighlight = isHighlightAnnotation(annotation)
        let menu = NSMenu()

        let removeTitle = isHighlight ? "Remove Highlight" : "Remove Underline"
        let removeItem = NSMenuItem(title: removeTitle, action: #selector(removeAnnotationAction(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = annotation
        menu.addItem(removeItem)

        let colorSubmenu = NSMenu()
        let colors: [(String, NSColor)] = isHighlight
            ? SettingsManager.shared.highlightPresets.map { ($0.name, $0.color) }
            : SettingsManager.shared.underlinePresets.map { ($0.name, $0.color) }

        for (name, color) in colors {
            let colorItem = NSMenuItem(title: name, action: #selector(changeColorAction(_:)), keyEquivalent: "")
            colorItem.target = self
            colorItem.representedObject = (annotation, color)
            if annotation.color.isEqual(to: color) {
                colorItem.state = .on
            }
            colorSubmenu.addItem(colorItem)
        }

        let colorMenuItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        colorMenuItem.submenu = colorSubmenu
        menu.addItem(colorMenuItem)

        return menu
    }

    @objc func removeAnnotationAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onAnnotationRemove?(annotation)
    }

    @objc func changeColorAction(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (PDFAnnotation, NSColor) else { return }
        onAnnotationColorChange?(tuple.0, tuple.1)
    }

    // MARK: - Comment Context Menu

    private func buildCommentContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()

        let removeItem = NSMenuItem(title: "Remove Comment", action: #selector(removeCommentAction(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = annotation
        menu.addItem(removeItem)

        let colorSubmenu = NSMenu()
        let colors = SettingsManager.shared.commentPresets.map { ($0.name, $0.color) }

        for (name, color) in colors {
            let colorItem = NSMenuItem(title: name, action: #selector(changeCommentColorAction(_:)), keyEquivalent: "")
            colorItem.target = self
            colorItem.representedObject = (annotation, color)
            if annotation.color.isEqual(to: color) {
                colorItem.state = .on
            }
            colorSubmenu.addItem(colorItem)
        }

        let colorMenuItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        colorMenuItem.submenu = colorSubmenu
        menu.addItem(colorMenuItem)

        return menu
    }

    @objc func removeCommentAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onAnnotationRemove?(annotation)
    }

    @objc func changeCommentColorAction(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (PDFAnnotation, NSColor) else { return }
        onCommentColorChange?(tuple.0, tuple.1)
    }

    // MARK: - Page Context Menu Actions

    @objc func toggleBookmarkAction() {
        onToggleBookmark?()
    }

    @objc func copyPageAsMarkdownAction() {
        onCopyPageAsMarkdown?()
    }

    @objc func copyDocumentAsMarkdownAction() {
        onCopyDocumentAsMarkdown?()
    }

    // MARK: - Private Helpers

    private func applyKeyboardShortcuts(to menu: NSMenu) {
        let shortcutMap: [String: String] = [
            "Zoom In": "zoomIn",
            "Zoom Out": "zoomOut",
            "Actual Size": "actualSize",
            "Next Page": "nextPage",
            "Previous Page": "previousPage"
        ]

        for item in menu.items {
            if let actionID = shortcutMap[item.title] {
                let shortcut = ShortcutModel.current(for: actionID)
                item.keyEquivalent = shortcut.nsKeyEquivalent
                item.keyEquivalentModifierMask = shortcut.nsModifierFlags
            }
        }
    }

    private func buildFallbackPageMenu() -> NSMenu {
        let menu = NSMenu()
        appendPageMenuItems(to: menu)
        return menu
    }

    private func appendPageMenuItems(to menu: NSMenu) {
        let bookmarkShortcut = ShortcutModel.current(for: "bookmark")
        let bookmarkItem = NSMenuItem(
            title: "Bookmark Page",
            action: #selector(toggleBookmarkAction),
            keyEquivalent: bookmarkShortcut.nsKeyEquivalent
        )
        bookmarkItem.keyEquivalentModifierMask = bookmarkShortcut.nsModifierFlags
        bookmarkItem.target = self
        menu.addItem(bookmarkItem)

        menu.addItem(.separator())

        let copyPageShortcut = ShortcutModel.current(for: "copyPageAsMarkdown")
        let copyPageItem = NSMenuItem(
            title: "Copy Page as Markdown",
            action: #selector(copyPageAsMarkdownAction),
            keyEquivalent: copyPageShortcut.nsKeyEquivalent
        )
        copyPageItem.keyEquivalentModifierMask = copyPageShortcut.nsModifierFlags
        copyPageItem.target = self
        menu.addItem(copyPageItem)

        let copyDocShortcut = ShortcutModel.current(for: "copyDocumentAsMarkdown")
        let copyDocItem = NSMenuItem(
            title: "Copy Document as Markdown",
            action: #selector(copyDocumentAsMarkdownAction),
            keyEquivalent: copyDocShortcut.nsKeyEquivalent
        )
        copyDocItem.keyEquivalentModifierMask = copyDocShortcut.nsModifierFlags
        copyDocItem.target = self
        menu.addItem(copyDocItem)
    }
}
