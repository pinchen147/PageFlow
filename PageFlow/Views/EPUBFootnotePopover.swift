//
//  EPUBFootnotePopover.swift
//  PageFlow
//
//  Footnote pop-ups: a note reference shows its note beside the link, in
//  the reader's typography and theme, instead of jumping away from the page.
//

import AppKit
import EPUBKit

/// What clicking a link on a book page does.
enum EPUBLinkResult {
    /// Not a book link: the system opens web and mail links.
    case unhandled
    /// The reader jumped to the link's target.
    case followed
    /// A note reference: resolves to the note to show at the link, or nil
    /// when the target read as no note and the reader jumped there instead.
    case footnote(Task<EPUBFootnote?, Never>)
}

typealias EPUBLinkHandler = (URL) -> EPUBLinkResult

/// A footnote's text, styled as the pages are, and the jump to it.
struct EPUBFootnote {
    let text: NSAttributedString
    let palette: EPUBPagePalette
    /// Jumps to the note in the book, remembering the place for Back; nil
    /// for a note shown only as a pop-up.
    let goToNote: (@MainActor () -> Void)?

    /// The note's text without the block's trailing break or leading space.
    nonisolated static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var start = 0
        var end = string.length
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool {
            Unicode.Scalar(string.character(at: index)).map(whitespace.contains) ?? false
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }
}

/// The popover a note shows in: its text, scrolling when long, and Go to Note.
final class EPUBFootnoteViewController: NSViewController, NSTextViewDelegate {
    nonisolated static let textWidth: CGFloat = 360
    private static let maxTextHeight: CGFloat = 320
    private static let padding: CGFloat = 16

    private let note: EPUBFootnote
    private let linkHandler: EPUBLinkHandler?
    /// Set by ``show(_:relativeTo:of:linkHandler:)``.
    private weak var popover: NSPopover?
    /// A note opened from a reference in this one, shown beside it.
    private var nestedPopover: NSPopover?
    var nestedNote: NSPopover? { nestedPopover }

    /// Shows `note` beside `rect` of `view`. A note reference in it opens a
    /// nested pop-up; other links close it and go through `linkHandler`, as
    /// links on the page do.
    static func show(_ note: EPUBFootnote, relativeTo rect: NSRect, of view: NSView,
                     linkHandler: EPUBLinkHandler?) -> NSPopover {
        let controller = EPUBFootnoteViewController(note: note, linkHandler: linkHandler)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: note.palette == .dark ? .darkAqua : .aqua)
        popover.contentViewController = controller
        controller.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return popover
    }

    private init(note: EPUBFootnote, linkHandler: EPUBLinkHandler?) {
        self.note = note
        self.linkHandler = linkHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let padding = Self.padding
        // TextKit 1, as on the pages: book images are attachment cells.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(EPUBPageLayoutManager())
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: Self.textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.textStorage?.setAttributedString(note.text)
        textView.setAccessibilityLabel("Footnote")

        var textHeight: CGFloat = 20
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            textHeight = max(textHeight, ceil(layout.usedRect(for: container).height))
        }
        textView.frame = NSRect(x: 0, y: 0, width: Self.textWidth, height: textHeight)
        let visibleHeight = min(textHeight, Self.maxTextHeight)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = textHeight > Self.maxTextHeight
        scrollView.documentView = textView
        // The pages' bar: Liquid Glass, floating over the text.
        if scrollView.hasVerticalScroller { GlassScrollerHover.install(on: scrollView) }
        let scrollSize = NSSize(width: Self.textWidth, height: visibleHeight)

        let button = NSButton(title: "Go to Note", target: self, action: #selector(goToNote))
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.sizeToFit()

        let hasButton = note.goToNote != nil
        let width = scrollSize.width + padding * 2
        let height = padding + scrollSize.height + (hasButton ? 10 + button.frame.height + padding * 0.75 : padding)
        let container = EPUBFootnoteBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.color = EPUBTextStyling.themeBackgroundColor(for: note.palette)
        // Unflipped: the button sits at the bottom right, the text above it.
        button.setFrameOrigin(NSPoint(x: width - padding - button.frame.width, y: padding * 0.75))
        let textBottom = hasButton ? button.frame.maxY + 10 : padding
        scrollView.frame = NSRect(origin: NSPoint(x: padding, y: textBottom), size: scrollSize)
        container.addSubview(scrollView)
        if hasButton { container.addSubview(button) }
        view = container
        preferredContentSize = container.frame.size
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        nestedPopover?.close()
    }

    @objc private func goToNote() {
        popover?.close()
        note.goToNote?()
    }

    /// A note reference opens its note in a pop-up beside this one; any
    /// other link closes this note and is followed as on the page.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        guard url.epubNoteReference != nil, let linkHandler else {
            popover?.close()
            if case .unhandled = linkHandler?(url) ?? .unhandled { return false }
            return true
        }
        guard case .footnote(let resolving) = linkHandler(url) else {
            popover?.close()
            return true
        }
        let anchor = Self.linkRect(at: charIndex, in: textView)
        Task { [weak self] in
            let nested = await resolving.value
            guard let self, view.window != nil else { return }
            // Read as no note, the link jumped: this note is left behind.
            guard let nested else {
                popover?.close()
                return
            }
            nestedPopover?.close()
            nestedPopover = Self.show(nested, relativeTo: anchor, of: textView, linkHandler: linkHandler)
        }
        return true
    }

    /// The link's rect on the line clicked.
    private static func linkRect(at index: Int, in textView: NSTextView) -> NSRect {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, index < storage.length else { return .zero }
        var linkRange = NSRange()
        _ = storage.attribute(.link, at: index, effectiveRange: &linkRange)
        let clicked = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                             actualCharacterRange: nil), in: container)
        let whole = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil), in: container)
        return (whole.height <= clicked.height * 1.5 ? whole : clicked)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
}

/// The popover's paper, in the reader's theme.
private final class EPUBFootnoteBackgroundView: NSView {
    var color = NSColor.white

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
