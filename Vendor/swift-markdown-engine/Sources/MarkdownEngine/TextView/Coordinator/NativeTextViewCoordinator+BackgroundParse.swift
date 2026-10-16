//
//  NativeTextViewCoordinator+BackgroundParse.swift
//  MarkdownEngine
//
//  A very long note shows its text at once and gains Live Preview when a
//  background parse lands. Parsing in place held the first paint for the
//  whole parse — 0.6 s on a 4.6 MB note (D12: first text under 300 ms). The
//  parser's shared memos are lock-guarded and the rest of it is pure, so it
//  runs on a snapshot off the main thread; the result is cached only if the
//  source did not move meanwhile.
//

import AppKit

extension NativeTextViewCoordinator {
    /// UTF-16 length from which a rebuild parses off the main thread. The parse
    /// costs about 130 ns a character, so below this the first paint stays
    /// near 250 ms with the parse in place and never shows unstyled text.
    static let backgroundParseThreshold = 1_000_000

    /// Whether a rebuild of `source` should paint first and parse off the main
    /// thread: a long note on screen (print renders in one pass) with no parse
    /// already cached for it.
    func shouldParseInBackground(_ source: NSString, in textView: NSTextView) -> Bool {
        guard (textView as? NativeTextView)?.rendersForPrint != true,
              source.length >= Self.backgroundParseThreshold else { return false }
        return !hasCachedParse(of: source)
    }

    /// Whether the parse cache holds `source` exactly (typing may still owe it
    /// a rebase).
    func hasCachedParse(of source: NSString) -> Bool {
        guard let cachedParsedChars, cachedParsedDocument != nil else { return false }
        return utf16(cachedParsedChars, equals: source)
    }

    /// The parse of `text` when one is cached, for work that can wait for a
    /// background parse, whose restyle covers it. No whole-note parse starts
    /// here unless typing since the cached parse can't be rebased onto it.
    func parsedDocumentIfCached(for text: String) -> ParsedDocument? {
        guard hasCachedParse(of: text as NSString) else { return nil }
        return parsedDocument(for: text)
    }

    /// Parses `text` off the main thread, then styles the note under the
    /// visible-source anchor, so the line the reader is on holds as the
    /// styling changes heights.
    ///
    /// The note stays owed its styling until this lands, even if a click or a
    /// keystroke meanwhile parsed on main: those style only the caret's
    /// paragraphs. Only a newer background parse or a whole-note restyle takes
    /// the debt over. If the text moved, the restyle uses the parse of the
    /// current text when one is cached, or starts a new background parse.
    func parseInBackground(_ text: String, for textView: NSTextView) {
        let ticket = UUID()
        pendingBackgroundStyle = ticket
        Task { @MainActor [weak self, weak textView] in
            let tokens = await Task.detached(priority: .userInitiated) {
                MarkdownTokenizer.parseTokensViaAST(in: text)
            }.value
            guard let self, let textView, self.pendingBackgroundStyle == ticket else { return }
            let source = text as NSString
            if source.isEqual(to: textView.string), !self.hasCachedParse(of: source) {
                self.cacheParse(self.parsedDocument(from: tokens), of: source)
            }
            let focus = (textView as? NativeTextView)?.readingPosition()?.anchorOffset
            self.restylePreservingViewport(textView, anchoringVisibleSource: true) {
                self.restyleCurrentSource(in: textView, focusOffset: focus)
            }
        }
    }
}
