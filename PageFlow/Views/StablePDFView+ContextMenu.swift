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

    /// In every content type: what is under the pointer and the document's own
    /// items first, then the system's, with Services among them.
    func buildContextMenu(for event: NSEvent, at viewPoint: NSPoint) -> NSMenu {
        let menu = NSMenu()
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)

            if let annotation = findCommentAnnotation(at: pagePoint, on: page) {
                pendingCommentAnnotation = annotation
                appendCommentItems(for: annotation, to: menu)
            } else if let annotation = findMarkupAnnotation(at: pagePoint, on: page) {
                pendingRemovalAnnotation = annotation
                appendAnnotationItems(for: annotation, to: menu)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }

        appendPageMenuItems(to: menu)
        return composeContextMenu(nativeMenu: super.menu(for: event), appMenu: menu)
    }

    // MARK: - System Items

    private static let appContextMenuPrefixID = NSUserInterfaceItemIdentifier("PageFlow.contextMenuPrefix")

    /// PDFKit's root owns the context of its native items and custom views.
    /// Only fresh app items move between menus; native items stay in place.
    func composeContextMenu(nativeMenu: NSMenu?, appMenu: NSMenu) -> NSMenu {
        guard let nativeMenu else {
            alignContextMenuItems(in: appMenu)
            return appMenu
        }

        // A caller can compose the same root again. Retire only our previous
        // contiguous prefix, including its boundary separator.
        while let first = nativeMenu.items.first, first.identifier == Self.appContextMenuPrefixID {
            nativeMenu.removeItem(first)
        }
        configureNativeSizingActions(in: nativeMenu)
        applyKeyboardShortcuts(to: nativeMenu)

        if !appMenu.items.isEmpty, let first = nativeMenu.items.first, !first.isSeparatorItem {
            appMenu.addItem(.separator())
        }
        let prefix = appMenu.items
        for item in prefix { appMenu.removeItem(item) }
        for item in prefix.reversed() {
            item.identifier = Self.appContextMenuPrefixID
            nativeMenu.insertItem(item, at: 0)
        }
        alignContextMenuItems(in: nativeMenu)
        return nativeMenu
    }

    /// AppKit reserves image space per section; text-only sections otherwise start farther left.
    private func alignContextMenuItems(in menu: NSMenu) {
        let size = menu.items.compactMap(\.image).first?.size ?? NSSize(width: 16, height: 16)
        let space = NSImage(size: size)
        space.isTemplate = true
        for item in menu.items where !item.isSeparatorItem && item.view == nil && item.image == nil {
            item.image = space
        }
    }

    /// Native identifiers come from PDFKit's returned menu metadata. The label
    /// fallback uses keys verified in PDFKit's own Localizable table.
    func configureNativeSizingActions(in menu: NSMenu) {
        let pdfKit = Bundle(for: PDFView.self)
        let resizeTitle = pdfKit.localizedString(forKey: "Auto Size", value: "Automatically Resize", table: "Localizable")
        let actualSizeTitle = pdfKit.localizedString(forKey: "Actual Size", value: "Actual Size", table: "Localizable")
        for item in menu.items {
            if item.identifier?.rawValue == "_setAutoSize:" || item.title == resizeTitle {
                item.target = self
                item.action = #selector(automaticallyResize(_:))
            } else if item.identifier?.rawValue == "_setActualSize:" || item.title == actualSizeTitle {
                item.target = self
                item.action = #selector(actualSize(_:))
                let shortcut = ShortcutModel.current(for: "actualSize")
                item.keyEquivalent = shortcut.nsKeyEquivalent
                item.keyEquivalentModifierMask = shortcut.nsModifierFlags
            }
        }
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

    private func appendAnnotationItems(for annotation: PDFAnnotation, to menu: NSMenu) {
        let isHighlight = isHighlightAnnotation(annotation)

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

        disableIfForbidden([removeItem, colorMenuItem])
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

    private func appendCommentItems(for annotation: PDFAnnotation, to menu: NSMenu) {
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

        disableIfForbidden([removeItem, colorMenuItem])
    }

    @objc func removeCommentAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onAnnotationRemove?(annotation)
    }

    @objc func changeCommentColorAction(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (PDFAnnotation, NSColor) else { return }
        onCommentColorChange?(tuple.0, tuple.1)
    }

    /// A document that forbids commenting shows its annotation commands disabled:
    /// with no action a menu's validation can't enable them, its other items still validate.
    private func disableIfForbidden(_ items: [NSMenuItem]) {
        guard !PDFPermissions(document).annotate else { return }
        for item in items {
            item.action = nil
            item.target = nil
            item.submenu?.items.forEach { $0.action = nil; $0.target = nil }
        }
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

    private func appendPageMenuItems(to menu: NSMenu) {
        let allowsCopying = PDFPermissions(document).copy
        let bookmarkShortcut = ShortcutModel.current(for: "bookmark")
        let bookmarkItem = NSMenuItem(
            title: "Bookmark Page",
            action: #selector(toggleBookmarkAction),
            keyEquivalent: bookmarkShortcut.nsKeyEquivalent
        )
        bookmarkItem.keyEquivalentModifierMask = bookmarkShortcut.nsModifierFlags
        bookmarkItem.target = self
        menu.addItem(bookmarkItem)

        // Markdown export extracts text, which a copy-protected document forbids.
        guard allowsCopying else { return }
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
