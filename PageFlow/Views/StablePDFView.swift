//
//  StablePDFView.swift
//  PageFlow
//
//  PDFView subclass that preserves vertical scroll position during horizontal resize.
//

import PDFKit
import AppKit

final class StablePDFView: PDFView {
    private var lastWidth: CGFloat = 0
    private let widthChangeTolerance: CGFloat = 0.5

    // MARK: - Interaction Mode (Pan vs Select)

    var interactionMode: InteractionMode = .select {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    private var lastPanLocation: NSPoint?
    private var isPanning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
    }

    // Reject all drag operations to allow parent SwiftUI view to handle them
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return false
    }

    override func layout() {
        super.layout()

        // Remove content insets so scroll bar extends to top edge
        if let scrollView = documentScrollView {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.automaticallyAdjustsContentInsets = false
            
            configureScrollers(scrollView)
        }
    }

    // MARK: - Scrollbar Management

    private enum ScrollerType: String {
        case vertical
        case horizontal
    }

    private var verticalTrackingArea: NSTrackingArea?
    private var horizontalTrackingArea: NSTrackingArea?
    private let verticalHoverZoneSize: CGFloat = 120.0 // 3x the original 40.0
    private let horizontalHoverZoneSize: CGFloat = 40.0

    // State tracking to ensure robustness during layout updates
    private var isHoveringVertical = false
    private var isHoveringHorizontal = false
    private weak var observedContentView: NSClipView?

    // MARK: - Callbacks for Click Handling
    var onAnnotationClick: ((PDFAnnotation) -> Void)?
    var onAnnotationDeselect: (() -> Void)?
    var onAnnotationRemove: ((PDFAnnotation) -> Void)?
    var onAnnotationColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onCommentColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onControlScroll: ((NSEvent) -> Bool)?
    var onLinkNavigation: (() -> Void)?
    var onCopyPageAsMarkdown: (() -> Void)?
    var onCopyDocumentAsMarkdown: (() -> Void)?
    var onToggleBookmark: (() -> Void)?

    private var rightClickMonitor: Any?

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setupRightClickMonitor() {
        // Guard against double-registration
        guard rightClickMonitor == nil else { return }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleRightClickEvent(event)
        }
    }

    private func handleRightClickEvent(_ event: NSEvent) -> NSEvent? {
        // Only handle events for our window
        guard let window = self.window,
              event.window === window else {
            return event
        }

        let windowPoint = event.locationInWindow
        let viewPoint = self.convert(windowPoint, from: nil)

        // Only handle clicks within our bounds
        guard self.bounds.contains(viewPoint) else {
            return event
        }

        // Critical: Verify this view is the frontmost at click point (fixes multi-tab bug)
        // Without this, hidden tabs' monitors would also match the bounds check
        guard let hitView = window.contentView?.hitTest(windowPoint),
              hitView === self || hitView.isDescendant(of: self) else {
            return event
        }

        // Check if clicking on a comment or markup annotation - show custom menu
        if let page = self.page(for: viewPoint, nearest: true) {
            let pagePoint = self.convert(viewPoint, to: page)

            // Check comments first (they're also highlights but with UUID userName)
            if let annotation = self.findCommentAnnotation(at: pagePoint, on: page) {
                self.pendingCommentAnnotation = annotation
                let menu = buildCommentContextMenu(for: annotation)
                menu.popUp(positioning: nil, at: viewPoint, in: self)
                return nil
            }

            // Then check regular markup annotations
            if let annotation = self.findMarkupAnnotation(at: pagePoint, on: page) {
                self.pendingRemovalAnnotation = annotation
                let menu = buildAnnotationContextMenu(for: annotation)
                menu.popUp(positioning: nil, at: viewPoint, in: self)
                return nil
            }
        }

        // Build modified default menu (removes Services, adds Copy as Markdown)
        let menu = buildFilteredDefaultMenu(for: event)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
        return nil
    }

    private func configureScrollers(_ scrollView: NSScrollView) {
        // Enforce overlay style and manual visibility control
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .default
        scrollView.autohidesScrollers = false
        
        // Swap vertical scroller with custom GlassScroller if needed
        if !(scrollView.verticalScroller is GlassScroller) {
            let vScroller = GlassScroller()
            scrollView.verticalScroller = vScroller
        }
        
        // Swap horizontal scroller with custom GlassScroller if needed
        if !(scrollView.horizontalScroller is GlassScroller) {
            let hScroller = GlassScroller()
            scrollView.horizontalScroller = hScroller
        }

        // Enforce visibility state
        scrollView.verticalScroller?.alphaValue = isHoveringVertical ? 1.0 : 0.0
        scrollView.horizontalScroller?.alphaValue = isHoveringHorizontal ? 1.0 : 0.0
        
        // Observe scrolling to enforce visibility - track contentView to handle document changes
        let contentView = scrollView.contentView
        if observedContentView !== contentView {
            // Remove old observer if contentView changed (e.g., when document changes)
            if let oldView = observedContentView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: oldView
                )
            }

            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
            observedContentView = contentView
        }
    }

    @objc private func handleScrollChanged(_ notification: Notification) {
        guard let scrollView = documentScrollView else { return }
        // Enforce visibility state during scroll to prevent system override
        // We use animator() proxy to match the active animation state if any, 
        // or just set it directly if we want strict enforcement. 
        // Direct set is safer to fight system "flash" logic.
        scrollView.verticalScroller?.alphaValue = isHoveringVertical ? 1.0 : 0.0
        scrollView.horizontalScroller?.alphaValue = isHoveringHorizontal ? 1.0 : 0.0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let vArea = verticalTrackingArea { removeTrackingArea(vArea) }
        if let hArea = horizontalTrackingArea { removeTrackingArea(hArea) }

        // Right edge (Vertical Scroller)
        let vRect = NSRect(x: bounds.width - verticalHoverZoneSize, y: 0, width: verticalHoverZoneSize, height: bounds.height)
        let vArea = NSTrackingArea(
            rect: vRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .assumeInside],
            owner: self,
            userInfo: ["type": ScrollerType.vertical.rawValue]
        )
        addTrackingArea(vArea)
        verticalTrackingArea = vArea

        // Bottom edge (Horizontal Scroller)
        // Note: PDFView is flipped, so y: bounds.height is the bottom
        let hRect = NSRect(x: 0, y: bounds.height - horizontalHoverZoneSize, width: bounds.width, height: horizontalHoverZoneSize)
        let hArea = NSTrackingArea(
            rect: hRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .assumeInside],
            owner: self,
            userInfo: ["type": ScrollerType.horizontal.rawValue]
        )
        addTrackingArea(hArea)
        horizontalTrackingArea = hArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverState(isEntering: true, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoverState(isEntering: false, event: event)
    }

    private func updateHoverState(isEntering: Bool, event: NSEvent) {
        guard let scrollView = documentScrollView,
              let userInfo = event.trackingArea?.userInfo as? [String: String],
              let typeString = userInfo["type"],
              let type = ScrollerType(rawValue: typeString) else { return }

        let scroller: NSScroller?
        
        switch type {
        case .vertical:
            isHoveringVertical = isEntering
            scroller = scrollView.verticalScroller
        case .horizontal:
            isHoveringHorizontal = isEntering
            scroller = scrollView.horizontalScroller
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scroller?.animator().alphaValue = isEntering ? 1.0 : 0.0
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let widthChanged = lastWidth > 0 && abs(lastWidth - newSize.width) > widthChangeTolerance

        lastWidth = newSize.width
        super.setFrameSize(newSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let currentWidth = superview?.bounds.width ?? oldSize.width
        let widthChanged = abs(oldSize.width - currentWidth) > widthChangeTolerance

        super.resize(withOldSuperviewSize: oldSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    private func restoreVerticalScroll(_ y: CGFloat) {
        guard let scrollView = documentScrollView else { return }

        var origin = scrollView.contentView.bounds.origin
        origin.y = y
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var documentScrollView: NSScrollView? {
        subviews.first { $0 is NSScrollView } as? NSScrollView
    }

    // MARK: - Cursor Management

    override func resetCursorRects() {
        if interactionMode == .pan {
            addCursorRect(bounds, cursor: .openHand)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if interactionMode == .pan {
            (isPanning ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        // Pan mode: initiate panning
        if interactionMode == .pan {
            lastPanLocation = convert(event.locationInWindow, from: nil)
            isPanning = true
            NSCursor.closedHand.push()
            return
        }

        // Select mode handling
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }

        let pagePoint = convert(viewPoint, to: page)

        // Check for internal link clicks - push navigation state before PDFKit handles the link
        if let annotation = page.annotation(at: pagePoint),
           annotation.type == "Link",
           let action = annotation.action {
            // Check if this is a GoTo action (internal navigation)
            if action is PDFActionGoTo {
                onLinkNavigation?()
            }
            // Let PDFView handle the actual navigation
            super.mouseDown(with: event)
            return
        }

        switch event.clickCount {
        case 1:
            // Single click: check for annotation
            if let annotation = page.annotation(at: pagePoint) {
                // Only consume click for comment annotations (have userName with UUID)
                // Regular highlights/underlines should allow text selection through them
                let isCommentAnnotation = annotation.userName.flatMap { UUID(uuidString: $0) } != nil
                if isCommentAnnotation {
                    onAnnotationClick?(annotation)
                    return
                }
                // For regular markup annotations, notify but allow text selection
                onAnnotationClick?(annotation)
            } else {
                onAnnotationDeselect?()
            }
            super.mouseDown(with: event)
        case 2:
            // Double click: select word
            if let selection = page.selectionForWord(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        case 3:
            // Triple click: select line
            if let selection = page.selectionForLine(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        default:
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Give control-scroll zoom handler a chance to consume the event
        if event.modifierFlags.contains(.control),
           onControlScroll?(event) == true {
            return
        }

        super.scrollWheel(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionMode == .pan, let lastLocation = lastPanLocation else {
            super.mouseDragged(with: event)
            return
        }

        guard let scrollView = documentScrollView else { return }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - lastLocation.x
        let dy = currentLocation.y - lastLocation.y

        var origin = scrollView.contentView.bounds.origin
        origin.x -= dx
        origin.y -= dy

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        lastPanLocation = currentLocation
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionMode == .pan else {
            super.mouseUp(with: event)
            return
        }

        lastPanLocation = nil
        isPanning = false
        NSCursor.pop()
    }

    // MARK: - Right-Click Context Menu for Annotations

    private var pendingRemovalAnnotation: PDFAnnotation?
    private var pendingCommentAnnotation: PDFAnnotation?

    override func rightMouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        // Check if clicking on a comment or markup annotation - show custom menu
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)

            // Check comments first (they're also highlights but with UUID userName)
            if let annotation = findCommentAnnotation(at: pagePoint, on: page) {
                pendingCommentAnnotation = annotation
                let menu = buildCommentContextMenu(for: annotation)
                menu.popUp(positioning: nil, at: viewPoint, in: self)
                return
            }

            // Then check regular markup annotations
            if let annotation = findMarkupAnnotation(at: pagePoint, on: page) {
                pendingRemovalAnnotation = annotation
                let menu = buildAnnotationContextMenu(for: annotation)
                menu.popUp(positioning: nil, at: viewPoint, in: self)
                return
            }
        }

        // Build modified default menu (removes Services, adds Copy as Markdown)
        let menu = buildFilteredDefaultMenu(for: event)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
    }

    private func buildFilteredDefaultMenu(for event: NSEvent) -> NSMenu {
        // Get PDFView's default menu
        guard let defaultMenu = super.menu(for: event) else {
            return buildFallbackPageMenu()
        }

        // Filter out Services submenu
        let filteredItems = defaultMenu.items.filter { item in
            // Check by identifier
            if item.submenu?.identifier?.rawValue == "NSServicesSubmenu" {
                return false
            }
            // Check by title as fallback
            if item.title == "Services" {
                return false
            }
            return true
        }

        // Build new menu with filtered items
        let menu = NSMenu()
        for item in filteredItems {
            if let copy = item.copy() as? NSMenuItem {
                menu.addItem(copy)
            }
        }

        // Add keyboard shortcuts to menu items
        applyKeyboardShortcuts(to: menu)

        // Add our custom items
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        // Bookmark current page
        let bookmarkShortcut = ShortcutModel.current(for: "toggleBookmark")
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

        return menu
    }

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

        // Bookmark current page
        let bookmarkShortcut = ShortcutModel.current(for: "toggleBookmark")
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

        return menu
    }

    private func findMarkupAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        // Method 1: Use PDFKit's built-in hit testing
        if let annotation = page.annotation(at: point),
           isRemovableMarkup(annotation) {
            return annotation
        }

        // Method 2: Manual search with tolerance for edge cases
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

    private func isRemovableMarkup(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }

        // Check for highlight or underline type (case-insensitive, partial match)
        let typeLower = type.lowercased()
        let isMarkup = typeLower.contains("highlight") || typeLower.contains("underline")

        guard isMarkup else { return false }

        // Exclude comment annotations (have UUID in userName)
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

    private func findCommentAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        // Method 1: Use PDFKit's built-in hit testing
        if let annotation = page.annotation(at: point),
           isCommentAnnotation(annotation) {
            return annotation
        }

        // Method 2: Manual search with tolerance for edge cases
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

    private func buildAnnotationContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let isHighlight = isHighlightAnnotation(annotation)
        let menu = NSMenu()

        // Remove item
        let removeTitle = isHighlight ? "Remove Highlight" : "Remove Underline"
        let removeItem = NSMenuItem(title: removeTitle, action: #selector(removeAnnotationAction(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = annotation
        menu.addItem(removeItem)

        // Change Color submenu
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

    @objc private func removeAnnotationAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onAnnotationRemove?(annotation)
    }

    @objc private func changeColorAction(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (PDFAnnotation, NSColor) else { return }
        onAnnotationColorChange?(tuple.0, tuple.1)
    }

    // MARK: - Comment Context Menu

    private func buildCommentContextMenu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()

        // Remove item
        let removeItem = NSMenuItem(title: "Remove Comment", action: #selector(removeCommentAction(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = annotation
        menu.addItem(removeItem)

        // Change Color submenu
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

    @objc private func removeCommentAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onAnnotationRemove?(annotation)
    }

    @objc private func changeCommentColorAction(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (PDFAnnotation, NSColor) else { return }
        onCommentColorChange?(tuple.0, tuple.1)
    }

    // MARK: - Page Context Menu Actions

    @objc private func toggleBookmarkAction() {
        onToggleBookmark?()
    }

    @objc private func copyPageAsMarkdownAction() {
        onCopyPageAsMarkdown?()
    }

    @objc private func copyDocumentAsMarkdownAction() {
        onCopyDocumentAsMarkdown?()
    }
}
