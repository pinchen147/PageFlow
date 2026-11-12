//
//  EPUBAsideView.swift
//  PageFlow
//
//  The supplement reader: a linear="no" spine item shown in one scrolling
//  column over the pages, in the reader's typography and theme, with its
//  own search and a Back button that returns to the page the reader left.
//

import AppKit
import EPUBKit
import SwiftUI

struct EPUBAsideView: View {
    let aside: EPUBAside
    let onBack: () -> Void
    /// A link in the text; returns whether the book took it.
    let onLink: (URL) -> Bool
    var chromePalette: EPUBPagePalette? = nil

    @State private var query = ""
    @State private var matches: [NSRange] = []
    @State private var current = 0
    /// Bumps to scroll the current match into view.
    @State private var revealRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EPUBAsideTextView(aside: aside, matches: matches, current: matches.isEmpty ? nil : current,
                              revealRequest: revealRequest, onLink: onLink)
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 420, idealHeight: 680)
        .environment(\.colorScheme, (chromePalette ?? aside.palette) == .dark ? .dark : .light)
        .onAppear(perform: start)
        .onChange(of: aside.target) { start() }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .pageFlowClickCursor()
            .help("Back to the page you were reading")
            Text(aside.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignTokens.spacingSM)
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .accessibilityLabel("Search this supplement")
                .onSubmit { step(1) }
                .onChange(of: query) { queryChanged() }
            if !query.isEmpty {
                Text(matches.isEmpty ? "No results" : "\(current + 1) of \(matches.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(matches.isEmpty)
                    .help("Previous match")
                    .accessibilityLabel("Previous match")
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(matches.isEmpty)
                    .help("Next match")
                    .accessibilityLabel("Next match")
            }
        }
        .padding(.horizontal, DesignTokens.spacingMD)
        .padding(.vertical, DesignTokens.spacingSM)
    }

    /// Opened from Find, the search starts at the match that opened it.
    private func start() {
        query = aside.query
        search(keeping: aside.targetIsMatch ? aside.target : nil)
    }

    /// Typing searches as it goes and shows the first match; the query
    /// that opened the supplement keeps its match.
    private func queryChanged() {
        if aside.targetIsMatch, query == aside.query {
            search(keeping: aside.target)
            return
        }
        search(keeping: nil)
        if !matches.isEmpty { revealRequest &+= 1 }
    }

    private func search(keeping match: NSRange?) {
        matches = Self.matches(of: query, in: aside.text.string)
        current = match.flatMap { matches.firstIndex(of: $0) } ?? 0
    }

    private func step(_ amount: Int) {
        guard !matches.isEmpty else { return }
        current = (current + amount + matches.count) % matches.count
        revealRequest &+= 1
    }

    /// Every match of `query`, as the book's Find matches.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        var found: [NSRange] = []
        var cursor = 0
        while cursor < string.length {
            let range = string.range(of: query, options: .caseInsensitive,
                                     range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound else { break }
            found.append(range)
            cursor = NSMaxRange(range)
        }
        return found
    }
}

/// The supplement's text in a TextKit 1 view (tables need it), read-only
/// and selectable, painted with its search's matches.
struct EPUBAsideTextView: NSViewRepresentable {
    let aside: EPUBAside
    let matches: [NSRange]
    let current: Int?
    let revealRequest: Int
    let onLink: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = EPUBPageLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: DesignTokens.spacingLG * 2, height: DesignTokens.spacingLG)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(aside.title)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        // The pages' bar: Liquid Glass, hidden until the pointer nears the edge.
        GlassScrollerHover.install(on: scroll)
        context.coordinator.storage = storage
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let layout = textView.layoutManager else { return }
        let coordinator = context.coordinator
        coordinator.onLink = onLink
        coordinator.document = aside.document
        let background = EPUBTextStyling.themeBackgroundColor(for: aside.palette)
        textView.backgroundColor = background
        scroll.backgroundColor = background
        let newReader = coordinator.shownID != aside.id
        if newReader || coordinator.shownText !== aside.text {
            let selection = textView.selectedRanges
            let bounds = scroll.contentView.bounds
            coordinator.shownID = aside.id
            coordinator.shownText = aside.text
            coordinator.storage?.setAttributedString(aside.text)
            if newReader {
                coordinator.shownTarget = nil
                coordinator.revealRevision &+= 1
            } else {
                if let container = textView.textContainer { layout.ensureLayout(for: container) }
                textView.selectedRanges = selection
                scroll.contentView.scroll(to: bounds.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let length = textView.string.utf16.count
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for match in matches where NSMaxRange(match) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.searchOtherResults, forCharacterRange: match)
        }
        if let current, matches.indices.contains(current), NSMaxRange(matches[current]) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.searchCurrentResult,
                                         forCharacterRange: matches[current])
        }
        // Only a genuinely changed navigation request may move this reader.
        var reveal: (range: NSRange, match: Bool)?
        if coordinator.shownTarget != aside.target {
            coordinator.shownTarget = aside.target
            coordinator.revealRevision &+= 1
            reveal = aside.target.map { ($0, aside.targetIsMatch) }
        } else if revealRequest != coordinator.shownReveal, let current, matches.indices.contains(current) {
            coordinator.revealRevision &+= 1
            reveal = (matches[current], true)
        }
        coordinator.shownReveal = revealRequest
        if let reveal {
            let revision = coordinator.revealRevision
            let id = aside.id
            let target = aside.target
            DispatchQueue.main.async { [weak coordinator, weak textView] in
                guard let coordinator, let textView, coordinator.shownID == id,
                      coordinator.shownTarget == target, coordinator.revealRevision == revision else { return }
                Self.reveal(reveal.range, in: textView, asMatch: reveal.match)
            }
        }
    }

    /// A match scrolls into view and bounces; a fragment's place scrolls to the top.
    private static func reveal(_ range: NSRange, in textView: NSTextView, asMatch: Bool) {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              NSMaxRange(range) <= textView.string.utf16.count else { return }
        layout.ensureLayout(for: container)
        if asMatch {
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
            return
        }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0),
                                       actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container)
        textView.scroll(NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerOrigin.y - DesignTokens.spacingMD)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var document: EPUBContent?
        var storage: NSTextStorage?
        var shownID: UUID?
        var shownText: NSAttributedString?
        var shownTarget: NSRange?
        var shownReveal = 0
        var revealRevision = 0
        var onLink: (URL) -> Bool = { _ in false }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLink(url)
        }

        /// A figure in a supplement opens large, as on the pages.
        func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol,
                      in cellFrame: NSRect, at charIndex: Int) {
            guard let attachment = textView.textStorage?.attribute(.attachment, at: charIndex, effectiveRange: nil)
                    as? NSTextAttachment, EPUBAttachmentImage.isImage(attachment) else { return }
            EPUBZoomPanel.showImage(of: attachment, title: "Figure", over: textView.window, origin: document)
        }
    }
}
