//
//  MarkdownPrintRenderer.swift
//  MarkdownEngine
//
//  PageFlow fork seam (S9 styled-Markdown print). Builds a throwaway,
//  print-configured TextKit 2 `NSTextView` that renders a document THROUGH THE
//  ENGINE — i.e. wired to the SAME `MarkdownLayoutManagerDelegate` the live editor
//  uses — so the printed page matches the screen.
//
//  Why the engine and not a stock `NSTextView`: the Live-Preview renderer paints
//  math (`$…$` / `$$…$$`), narrow tables, code-block backgrounds, thematic breaks,
//  blockquote bars and list bullets in `MarkdownTextLayoutFragment.draw(at:in:)`.
//  Those glyphs carry a `.clear` foreground plus a custom `.renderedBlockImage` (etc.)
//  attribute and are drawn ONLY by that custom fragment, which is installed via
//  `textLayoutManager.delegate`. A plain `NSTextView` has no such delegate, so it
//  draws them as invisible glyphs — math/tables print BLANK. This builder installs
//  the delegate + the editor's real configuration, so the fragment fires on the
//  print view exactly as on screen.
//

import AppKit

/// Builds a detached, page-width `NSTextView` that styles a document's source
/// for paper through the engine's custom layout fragment, ready to hand to
/// `NSPrintOperation(view:printInfo:)`.
public enum MarkdownPrintRenderer {

    /// Construct the print view.
    ///
    /// The source is styled afresh rather than copied from the screen, so the
    /// page never loses what the screen defers or overlays:
    /// - nothing is revealed as raw markup (the view is read-only, so no token
    ///   is active at a caret);
    /// - every styling pass runs now, including the ones a long note defers;
    /// - a table wider than the page prints scaled to it (on screen it scrolls
    ///   in an overlay view, which paper can't carry);
    /// - the view is light (Aqua), so dynamic colors resolve to dark ink. Math
    ///   and diagram renderers follow the drawing appearance; a host that pins
    ///   them to a forced scheme lifts that pin while building the print view.
    ///
    /// - Parameters:
    ///   - source: The document's Markdown source.
    ///   - configuration: The live editor's configuration (theme, services).
    ///   - fontName, fontSize: The live editor's body font.
    ///   - baseFont: The resolved body font (trailing-line metrics).
    ///   - pageWidth: Printable content width in points.
    @MainActor
    public static func makePrintTextView(
        source: String,
        configuration: MarkdownEditorConfiguration,
        fontName: String,
        fontSize: CGFloat,
        baseFont: NSFont,
        pageWidth: CGFloat
    ) -> NSTextView {
        let width = max(1, pageWidth)

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:),
        // exactly as the live editor does in NativeTextViewWrapper.makeNSView.
        let printView = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: width))
        printView.configuration = configuration
        printView.rendersForPrint = true
        printView.baseFont = baseFont
        printView.font = baseFont
        printView.appearance = NSAppearance(named: .aqua)
        printView.backgroundColor = .white
        printView.drawsBackground = true
        printView.isEditable = false
        printView.isSelectable = false
        printView.isVerticallyResizable = true
        printView.isHorizontallyResizable = false
        printView.textContainerInset = .zero

        if let container = printView.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        guard let textLayoutManager = printView.textLayoutManager else { return printView }

        // The SAME custom layout-fragment delegate the editor uses draws the
        // rendered blocks. NSTextLayoutManager.delegate is weak → the view
        // retains it for the print operation's lifetime.
        let delegate = MarkdownLayoutManagerDelegate()
        printView.printLayoutDelegate = delegate
        textLayoutManager.delegate = delegate

        let styler = NativeTextViewCoordinator(
            text: .constant(source), fontName: fontName, fontSize: fontSize,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        styler.configuration = configuration
        styler.textView = printView
        let bridge = LayoutBridge(textLayoutManager)
        styler.layoutBridge = bridge
        printView.layoutBridge = bridge
        printView.printStyler = styler
        styler.rebuildTextStorageAndStyle(printView, from: source)
        // A long note defers part of its styling to idle passes; paper needs
        // all of it now.
        for _ in 0..<10_000 where !styler.deferredRestyleRanges.isEmpty {
            styler.flushDeferredRestyle()
        }

        // Full-document layout so pagination sees every page's height (TextKit 2
        // is viewport-lazy otherwise), then grow the frame to the laid-out height.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        printView.sizeToFit()
        return printView
    }
}
