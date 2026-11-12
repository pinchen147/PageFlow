//
//  EPUBZoomPanel.swift
//  PageFlow
//
//  A book's figure or table opened large in a floating panel beside the
//  reader: pinch, ⌘+ / ⌘− and scroll to zoom and pan, ⌘0 to fit, double-click
//  to switch between fit and actual size, Esc to close. A table opens at its
//  natural size on the page's paper and pans from there.
//

import AppKit
import EPUBKit

final class EPUBZoomPanel: NSPanel {
    /// One panel at a time: opening another figure replaces it.
    private(set) static weak var current: EPUBZoomPanel?

    private let scroll = NSScrollView()
    /// The scale that fits the content in the panel.
    private var fitScale: CGFloat = 1
    /// A table is read at its size: it opens there, and its fit (⌘0) fits its
    /// width and scrolls down. A figure opens fitted, whole.
    private var isTable = false
    /// While true the content refits as the panel resizes.
    private var keepsFit = true

    private weak var origin: EPUBContent?
    private var originLifetime: UUID?
    private var closed = false
    private var paletteRevision = 0
    private var paletteTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var tableSource: TableSnapshot?

    /// These snapshots cross executors read-only. Recoloring copies the text
    /// and its table blocks; attachments keep their existing immutable styling.
    private nonisolated struct TableSnapshot: @unchecked Sendable {
        let text: NSAttributedString
        let palette: EPUBPagePalette

        init(_ text: NSAttributedString, palette: EPUBPagePalette) {
            self.text = NSAttributedString(attributedString: text)
            self.palette = palette
        }
    }

    /// The package's image decode reads the attachment's fixed store/path and
    /// uses its synchronized image cache; it does not mutate attachment styling.
    private nonisolated struct ImageSource: @unchecked Sendable {
        let attachment: NSTextAttachment
    }

    private var isCurrentAndAlive: Bool {
        guard !closed, Self.current === self else { return false }
        // Save As relocates the same live book. Its file URL is not its lifetime.
        guard let origin else { return originLifetime == nil }
        return originLifetime != nil && origin.asideLifetime == originLifetime
    }

    // MARK: - Opening

    /// Shows a book image: its display decode at once, the large decode once ready.
    static func showImage(of attachment: NSTextAttachment, title: String, over parent: NSWindow?, origin: EPUBContent? = nil) {
        guard let preview = EPUBAttachmentImage.preview(of: attachment) else { return }
        let view = EPUBZoomImageView(image: preview)
        let panel = present(view, title: title, over: parent, origin: origin)
        let source = ImageSource(attachment: attachment)
        let work = Task.detached(priority: .userInitiated) {
            EPUBAttachmentImage.zoomImage(of: source.attachment)
        }
        panel.imageTask = Task { [weak panel, weak view] in
            let large = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let panel, panel.isCurrentAndAlive, let view,
                  panel.scroll.documentView === view, let large, large.width > preview.width else { return }
            view.image = large
            panel.imageTask = nil
        }
    }

    /// Source ink may still be the committed page palette while chrome has
    /// already moved to the owner's requested palette.
    static func showTable(_ table: NSAttributedString, background: NSColor, title: String, over parent: NSWindow?,
                          origin: EPUBContent? = nil, sourcePalette: EPUBPagePalette = .light) {
        let layout = EPUBZoomTable.layout(table)
        let panel = present(EPUBZoomTable.textView(layout.text, width: layout.width, background: background),
                            title: title, over: parent, isTable: true, canvas: background, origin: origin)
        panel.tableSource = TableSnapshot(layout.text, palette: sourcePalette)
        panel.refreshPalette()
    }

    @discardableResult
    private static func present(_ document: NSView, title: String, over parent: NSWindow?,
                                isTable: Bool = false, canvas: NSColor = DesignTokens.viewerBackground,
                                origin: EPUBContent? = nil) -> EPUBZoomPanel {
        current?.close()
        let screen = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let area = parent?.frame ?? screen
        // Big enough to read, no bigger than the content needs.
        let size = NSSize(width: min(max(document.frame.width + 40, 420), area.width * 0.85, screen.width),
                          height: min(max(document.frame.height + 60, 320), area.height * 0.85, screen.height))
        let panel = EPUBZoomPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                  backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.origin = origin
        panel.originLifetime = origin?.asideLifetime
        panel.appearance = origin.map { NSAppearance(named: $0.requestedPalette == .dark ? .darkAqua : .aqua) }
            ?? parent?.appearance
        panel.isTable = isTable
        panel.setUp(document, canvas: canvas)
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.scroll.documentView)
        current = panel
        panel.refreshPalette()
        return panel
    }

    private func setUp(_ document: NSView, canvas: NSColor) {
        let clip = EPUBZoomClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.backgroundColor = canvas
        scroll.drawsBackground = true
        contentView = scroll
        setAccessibilityLabel(title)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification,
                                               object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        if isTable {
            keepsFit = false
            scroll.magnification = 1
        } else {
            fit()
        }
    }

    // MARK: - Appearance and lifetime

    static func refreshPalette(for content: EPUBContent) {
        guard let panel = current, panel.origin === content else { return }
        panel.refreshPalette()
    }

    static func close(for content: EPUBContent) {
        guard let panel = current, panel.origin === content else { return }
        panel.close()
    }

    private func refreshPalette() {
        guard isCurrentAndAlive, let origin else { return }
        let requested = origin.requestedPalette
        appearance = NSAppearance(named: requested == .dark ? .darkAqua : .aqua)
        paletteTask?.cancel()
        paletteTask = nil
        paletteRevision &+= 1
        let background = EPUBTextStyling.themeBackgroundColor(for: requested)
        guard isTable else {
            scroll.backgroundColor = background
            return
        }
        guard let source = tableSource, source.palette != requested,
              let holder = scroll.documentView, let view = holder.subviews.first as? EPUBZoomTableView,
              let storage = view.storage else { return }
        let revision = paletteRevision
        let work = Task.detached(priority: .userInitiated) {
            TableSnapshot(EPUBTextStyling.recoloring(source.text, from: source.palette, to: requested), palette: requested)
        }
        paletteTask = Task { [weak self, weak origin, weak view] in
            let replacement = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, isCurrentAndAlive, let origin, self.origin === origin,
                  origin.requestedPalette == requested, paletteRevision == revision,
                  tableSource?.text === source.text, let view, scroll.documentView === holder,
                  holder.subviews.first === view, view.storage === storage else { return }
            let selection = view.selectedRanges
            let bounds = scroll.contentView.bounds
            // Storage and paper publish together on the main actor. The holder,
            // natural dimensions and zoom/fit state are never rebuilt.
            storage.setAttributedString(replacement.text)
            view.backgroundColor = background
            scroll.backgroundColor = background
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            view.selectedRanges = selection
            scroll.contentView.scroll(to: bounds.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            tableSource = replacement
            paletteTask = nil
        }
    }

    override func close() {
        closed = true
        paletteRevision &+= 1
        paletteTask?.cancel()
        paletteTask = nil
        imageTask?.cancel()
        imageTask = nil
        if Self.current === self { Self.current = nil }
        super.close()
    }

    // MARK: - Zoom

    /// Scales the content to the panel, a small figure up to twice its size.
    func fit() {
        guard let document = scroll.documentView, document.frame.width > 0, document.frame.height > 0 else { return }
        let available = scroll.contentSize
        let width = available.width / document.frame.width
        fitScale = isTable ? min(width, 1) : min(width, available.height / document.frame.height, 2)
        keepsFit = true
        scroll.magnification = min(max(fitScale, scroll.minMagnification), scroll.maxMagnification)
    }

    func zoom(by factor: CGFloat) {
        keepsFit = false
        let target = min(max(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification)
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(target, centeredAt: center)
    }

    /// Double-click: actual size at the click, or back to the fit.
    func toggleActualSize(at point: NSPoint) {
        if abs(scroll.magnification - 1) < 0.01 {
            fit()
        } else {
            keepsFit = false
            scroll.setMagnification(1, centeredAt: point)
        }
    }

    var magnification: CGFloat { scroll.magnification }

    @objc private func resized() {
        if keepsFit { fit() }
    }

    @objc private func magnified() {
        keepsFit = abs(scroll.magnification - fitScale) < 0.01
    }

    // MARK: - Keys

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let zoomIn = ShortcutModel.current(for: "zoomIn")
        if zoomIn.matches(event: event) {
            zoom(by: 1.25)
        } else if ShortcutModel.current(for: "zoomOut").matches(event: event) {
            zoom(by: 1 / 1.25)
        } else if ShortcutModel.current(for: "actualSize").matches(event: event)
                    || ShortcutModel.current(for: "zoomToFit").matches(event: event) {
            fit()
        } else if ShortcutModel.current(for: "closeTab").matches(event: event) {
            close()
        } else if zoomIn == ShortcutModel(key: "+"),
                  event.modifierFlags.intersection([.control, .option, .shift, .command]).subtracting(.shift) == .command,
                  ["=", "+"].contains(event.charactersIgnoringModifiers) {
            // On keyboards where + is shifted, both ⌘= and ⇧⌘+ enlarge the panel.
            zoom(by: 1.25)
        } else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

/// Keeps content smaller than the panel centred both ways.
private final class EPUBZoomClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A book image at one point per pixel.
final class EPUBZoomImageView: NSView {
    var image: CGImage {
        didSet { needsDisplay = true }
    }
    /// The size it is shown at: the first image's, so a sharper decode
    /// arriving later fills the same space.
    private let pointSize: NSSize

    init(image: CGImage) {
        self.image = image
        pointSize = NSSize(width: image.width, height: image.height)
        super.init(frame: NSRect(origin: .zero, size: pointSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: pointSize).draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let panel = window as? EPUBZoomPanel else { return super.mouseDown(with: event) }
        panel.toggleActualSize(at: convert(event.locationInWindow, from: nil))
    }
}
