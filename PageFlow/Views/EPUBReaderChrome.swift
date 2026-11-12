//
//  EPUBReaderChrome.swift
//  PageFlow
//
//  What both EPUB reading surfaces (the continuous stack and the spread)
//  share around their pages: the reading keys, page-turn actions for
//  VoiceOver, handing the keyboard back to the reader, the paper's shadow
//  and edge, and a spread's fold.
//

import AppKit
import Carbon.HIToolbox

extension NSView {
    /// Gives this reader surface the keyboard. Unless `overEditing`, a field
    /// the user is typing in keeps it.
    func claimReaderFocus(overEditing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return }
            if let surface = self as? any ReaderFocusSurface {
                guard surface.isBeingRead else { return }
                if surface.annotationDocument?.ownsAnnotationResponder(window.firstResponder) == true { return }
            }
            if !overEditing, let editor = window.firstResponder as? NSTextView, editor.isEditable { return }
            // Already inside the surface (a page's text has focus): keep it.
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return }
            window.makeFirstResponder(self)
        }
    }

    /// Hides this reader surface. AppKit hands the keyboard of a view being
    /// hidden to the next key view, and looking for one makes SwiftUI rebuild
    /// the window's focus order inside the update that hid it. The tab being
    /// shown takes the keyboard next, so nothing needs to look.
    func setReaderSurfaceHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden, let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(nil)
        }
        isHidden = hidden
    }
}

/// A reader surface, which takes the keyboard as it gets a window. One already told
/// it's what's being read takes it from whatever holds it: asked before it had a
/// window, it would otherwise leave it in the Find field of a tab just closed.
protocol ReaderFocusSurface: NSView {
    var isBeingRead: Bool { get set }
    var annotationDocument: (any TabDocument)? { get set }
}

extension ReaderFocusSurface {
    /// AppKit asks views for command keys before opening the Tools menu. Use
    /// the selection in the book that owns the responder at the time of the key.
    func performAnnotationKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              !isHiddenOrHasHiddenAncestor, let responder = window.firstResponder as? NSView,
              responder === self || (responder is EPUBPageTextView && responder.isDescendant(of: self)),
              let content = annotationDocument as? EPUBContent, content.book != nil else { return false }
        if ShortcutModel.current(for: "highlight").matches(event: event) {
            return content.highlights.highlightSelection() != nil
        }
        if ShortcutModel.current(for: "underline").matches(event: event) {
            return content.highlights.highlightSelection(style: .underline) != nil
        }
        if ShortcutModel.current(for: "comment").matches(event: event), content.canAddNote {
            return content.addNote() != nil
        }
        return false
    }
}

/// Hands the keyboard back to a reader surface whenever it becomes the thing
/// being read again (its tab shown, Find or a note closed) or nothing else holds
/// it (a field in the sidebar went with the sidebar).
final class ReaderFocus {
    private var wanted = false

    func update(_ wants: Bool, view: some ReaderFocusSurface) {
        defer { wanted = wants }
        view.isBeingRead = wants
        guard wants, !wanted || view.window?.firstResponder === view.window else { return }
        view.claimReaderFocus(overEditing: true)
    }
}

/// The paper under EPUB pages, the same in every layout: one drop shadow and,
/// for dark pages that would sink into the dark viewer, a faint edge.
enum EPUBPageSheet {
    static func draw(_ frames: [NSRect], in dirtyRect: NSRect, palette: EPUBPagePalette) {
        let visible = frames.filter { $0.insetBy(dx: -20, dy: -20).intersects(dirtyRect) }
        guard !visible.isEmpty else { return }
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        visible.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()
        guard palette == .dark else { return }
        NSColor.white.withAlphaComponent(0.1).setStroke()
        for frame in visible {
            let edge = NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}

/// The fold between a spread's two pages: a soft shade either side of the
/// spine, so facing pages read as a book rather than one sheet.
final class EPUBSpineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSGradient(colorsAndLocations:
            (.black.withAlphaComponent(0), 0),
            (.black.withAlphaComponent(0.12), 0.5),
            (.black.withAlphaComponent(0), 1))
        shade?.draw(in: bounds, angle: 0)
    }
}

/// Control-scroll zooms, by PDF's step, on both surfaces.
enum EPUBControlScroll {
    /// The page scale after an event, or nil if it isn't a Control-scroll.
    static func scale(after event: NSEvent, from scale: CGFloat) -> CGFloat? {
        guard event.modifierFlags.contains(.control), event.scrollingDeltaY != 0 else { return nil }
        let factor = DesignTokens.pdfControlScrollZoomFactor
        let range = EPUBPageGeometry.scaleRange
        return min(max(event.scrollingDeltaY > 0 ? scale * factor : scale / factor, range.lowerBound), range.upperBound)
    }
}

/// A two-finger double tap, on both surfaces: from the fit in to a readable
/// size at the pointer, from anywhere else back to the fit, like PDFKit's.
enum EPUBSmartZoom {
    static func scale(from scale: CGFloat, fit: CGFloat) -> CGFloat {
        abs(scale - fit) <= fit * 0.03 ? min(fit * 1.5, EPUBPageGeometry.scaleRange.upperBound) : fit
    }
}

/// The reading keys, read the same way by both surfaces. Any other key, or
/// one with modifiers, keeps its text meaning (Shift-arrow extends a selection).
enum EPUBReaderKey: Equatable {
    /// Space / Shift-Space, Page Down / Page Up: a screenful, or a page.
    case screen(forward: Bool)
    /// → / ←: a page (← forward in a right-to-left book).
    case turn(forward: Bool)
    /// ↓ / ↑: a line.
    case line(forward: Bool)
    /// End / Home.
    case end(forward: Bool)
    /// Esc: closes the Notes panel, then the sidebar. Read only while the
    /// pages hold the keyboard, so a field being typed in keeps its own Esc.
    case escape

    /// How far an arrow key pans or scrolls, in points on screen.
    static let lineStep: CGFloat = 40

    init?(_ event: NSEvent, rightToLeft: Bool = false) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_Space, []), (kVK_PageDown, []): self = .screen(forward: true)
        case (kVK_Space, .shift), (kVK_PageUp, []): self = .screen(forward: false)
        case (kVK_RightArrow, []): self = .turn(forward: !rightToLeft)
        case (kVK_LeftArrow, []): self = .turn(forward: rightToLeft)
        case (kVK_DownArrow, []): self = .line(forward: true)
        case (kVK_UpArrow, []): self = .line(forward: false)
        case (kVK_End, []): self = .end(forward: true)
        case (kVK_Home, []): self = .end(forward: false)
        case (kVK_Escape, []): self = .escape
        default: return nil
        }
    }
}

extension NSScrollView {
    /// Pans pages wider than the window by an arrow key's step; returns false
    /// at their side or if they fit. Forward is to the left in a right-to-left book.
    func panSideways(_ forward: Bool, rightToLeft: Bool) -> Bool {
        guard let documentView else { return false }
        let toRight = forward != rightToLeft
        let bounds = contentView.bounds
        let right = documentView.frame.width - bounds.width
        guard toRight ? bounds.minX < right - 1 : bounds.minX > 1 && right > 0 else { return false }
        let x = bounds.minX + (toRight ? 1 : -1) * EPUBReaderKey.lineStep / magnification
        contentView.scroll(to: NSPoint(x: min(max(0, x), right), y: bounds.minY))
        reflectScrolledClipView(contentView)
        return true
    }
}

extension NSView {
    /// Names the view as the book's pages and gives VoiceOver Next Page and
    /// Previous Page actions; `turn` returns whether there was a page.
    func setUpReaderAccessibility(turn: @escaping (Bool) -> Bool) {
        setAccessibilityLabel("Book pages")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Next Page") { turn(true) },
            NSAccessibilityCustomAction(name: "Previous Page") { turn(false) }
        ])
    }
}
