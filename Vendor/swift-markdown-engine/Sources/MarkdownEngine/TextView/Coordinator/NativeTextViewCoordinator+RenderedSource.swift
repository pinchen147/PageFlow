import AppKit

/// Only a click on the drawn object owns editable source content; a caret does not.
struct RenderedSourceIntent {
    var range: NSRange
    let kind: MarkdownTokenKind
    let document: Int
    var source: Int
}

extension NativeTextViewCoordinator {
    func isEditingRenderedSource(_ token: MarkdownToken, in view: NSTextView) -> Bool {
        guard view === textView, view.isEditable, let intent = renderedSourceIntent else { return false }
        return intent.document == documentGeneration && intent.source == nativeSourceGeneration
            && intent.kind == token.kind && intent.range == token.range
    }

    func beginRenderedSourceEditing(_ token: MarkdownToken, in view: NativeTextView) {
        guard view === textView, view.isEditable else { return }
        renderedSourceIntent = RenderedSourceIntent(range: token.range, kind: token.kind,
                                                   document: documentGeneration, source: nativeSourceGeneration)
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        let text = view.string as NSString
        var start = token.contentRange.location
        while start < NSMaxRange(token.contentRange), let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
        let selection = token.kind == .inlineLatex ? token.contentRange : NSRange(location: start, length: 0)
        view.setSelectedRange(selection)
        // A previous ordinary caret may already have activated this token. Intent
        // changes still need a style pass when that caret-derived set is unchanged.
        restyle(view, paragraphCandidates: [token.range], anchoringViewport: true)
    }

    func retireRenderedSourceIntentIfNeeded(in view: NSTextView) {
        guard let intent = renderedSourceIntent, pendingTextChange == nil, !isApplyingSpanEdit,
              view.undoManager?.isUndoing != true, view.undoManager?.isRedoing != true else { return }
        let selection = view.selectedRange()
        let contained = selection.location >= intent.range.location && NSMaxRange(selection) <= NSMaxRange(intent.range)
        guard intent.document != documentGeneration || intent.source != nativeSourceGeneration || !contained || !view.isEditable else { return }
        renderedSourceIntent = nil
        let length = (view.string as NSString).length
        let oldRange = NSIntersectionRange(intent.range, NSRange(location: 0, length: length))
        if oldRange.length > 0 { restyle(view, paragraphCandidates: [oldRange], anchoringViewport: true) }
    }

    func advanceRenderedSourceIntent(after change: TextChange?) {
        guard var intent = renderedSourceIntent else { return }
        guard intent.document == documentGeneration, intent.source == nativeSourceGeneration else {
            renderedSourceIntent = nil; return
        }
        guard let change else {
            // Native Undo bypasses admission. Continue an already explicit editor
            // only when that same object survives the actual restored source.
            if let view = textView, view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true,
               let token = parsedDocument(for: view.string).tokens.first(where: {
                   $0.kind == intent.kind && $0.range.location == intent.range.location
               }) {
                intent.range = token.range
                intent.source = nativeSourceGeneration + 1
                renderedSourceIntent = intent
            } else { renderedSourceIntent = nil }
            return
        }
        let edited = change.oldRange
        if NSMaxRange(edited) <= intent.range.location {
            intent.range.location += change.delta
        } else if edited.location >= NSMaxRange(intent.range) {
            // An edit after the object does not move its source address.
        } else if edited.location >= intent.range.location && NSMaxRange(edited) <= NSMaxRange(intent.range) {
            intent.range.length += change.delta
        } else {
            renderedSourceIntent = nil
            return
        }
        intent.source = nativeSourceGeneration + 1
        renderedSourceIntent = intent
    }
}

extension MarkdownStyler.StylingContext {
    func isEditingRenderedSource(_ token: MarkdownToken) -> Bool {
        guard let view = layoutBridge?.firstTextContainer?.textView,
              let owner = view.delegate as? NativeTextViewCoordinator else { return false }
        return owner.isEditingRenderedSource(token, in: view)
    }
}

extension NativeTextView {
    /// The same native image geometry that paints the object admits the click.
    /// This route never runs for keyboard, Find, Undo or programmatic selection.
    func routeMouseDownToRenderedSource(_ event: NSEvent) -> Bool {
        guard isEditable, event.type == .leftMouseDown, !event.modifierFlags.contains(.shift),
              let window, event.window === window, let owner = delegate as? NativeTextViewCoordinator, let storage = textStorage,
              let viewport = viewportCharacterRange else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let source = string
        let tokens = owner.parsedDocument(for: source).tokens
        let scope = NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))
        var target: MarkdownToken?
        storage.enumerateAttribute(.renderedBlockImage, in: scope) { value, range, stop in
            guard value is NSImage, let rect = renderedImageRect(at: range.location), rect.contains(point),
                  let token = tokens.first(where: { token in
                      let eligible = token.kind == .inlineLatex || token.kind == .blockLatex
                          || (token.kind == .codeBlock && MarkdownTokenizer.extractLanguage(from: token, in: source)
                              .map { configuration.diagramLanguages.contains($0.lowercased()) } == true)
                      return eligible && NSLocationInRange(range.location, token.contentRange)
                  }) else { return }
            target = token
            stop.pointee = true
        }
        guard let target else { return false }
        owner.beginRenderedSourceEditing(target, in: self)
        return true
    }
}
