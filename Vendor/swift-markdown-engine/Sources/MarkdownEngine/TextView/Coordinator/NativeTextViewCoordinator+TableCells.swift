import AppKit

extension NativeTextViewCoordinator {
    /// A focused table cell's keystroke. Its grid already shows the edit, so the
    /// table's hidden source takes it with hidden attributes, and the table
    /// re-renders once typing pauses instead of on every keystroke (a whole-table
    /// render and two whole-document parses). Returns nil when the span cannot be
    /// written this way (it holds the table's image anchor), so the caller uses
    /// the ordinary transaction.
    func replaceHiddenTableSource(
        _ range: NSRange, with replacement: String, actionName: String, registersUndo: Bool = true
    ) -> Bool? {
        guard let tv = textView, let attributes = hiddenTableSourceAttributes(replacing: range, with: replacement) else {
            return nil
        }
        isDeferringTableRender = true
        defer { isDeferringTableRender = false }
        return replaceSourceRanges([range], with: replacement, expectedSource: tv.string, actionName: actionName,
                                   reflowsParagraphChain: false, insertedAttributes: attributes,
                                   registersUndo: registersUndo)
    }

    /// Re-render the table at `range` now, pinned to the viewport: a cell edit
    /// changed a row's height, and the grid must not overlap the text below
    /// until a deferred render.
    func restyleTableNow(_ range: NSRange) {
        guard let tv = textView else { return }
        let text = tv.string
        PerfTrace.time("table.rowHeightRestyle") {
            restyle(tv, paragraphCandidates: [range], tokens: parsedDocument(for: text).tokens, text: text,
                    anchoringViewport: true)
        }
    }

    /// The attributes rendered tables give their non-anchor source: invisible,
    /// in the marker font, kerned to no width, in the row's paragraph style.
    private func hiddenTableSourceAttributes(
        replacing range: NSRange, with replacement: String
    ) -> [NSAttributedString.Key: Any]? {
        guard let storage = textView?.textStorage, range.location > 0, NSMaxRange(range) < storage.length else { return nil }
        let probe = NSRange(location: range.location - 1, length: range.length + 2)
        var holdsAnchor = false
        storage.enumerateAttribute(.renderedBlockImage, in: probe) { value, _, stop in
            if value != nil { holdsAnchor = true; stop.pointee = true }
        }
        let neighbor = NSMaxRange(range)
        guard !holdsAnchor,
              storage.attribute(.foregroundColor, at: neighbor, effectiveRange: nil) as? NSColor == .clear,
              let font = storage.attribute(.font, at: neighbor, effectiveRange: nil) as? NSFont else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.clear,
            .kern: -HeadingHelpers.hiddenRunWidth(replacement, font: font),
        ]
        attributes[.paragraphStyle] = storage.attribute(.paragraphStyle, at: neighbor, effectiveRange: nil)
        return attributes
    }
}
