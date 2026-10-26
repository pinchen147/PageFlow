import AppKit

/// An image selected as a whole: the reference editor's node selection (doc 26
/// §3). The text view's selection is the image's whole token, and the reveal
/// pass leaves that token rendered, so selecting an image lays nothing out.
struct ObjectSelection: Equatable {
    /// The whole `![…](…)` or `![[…]]` token: the text view's selection.
    var token: NSRange
    /// The character that carries the rendered image and its anchor attributes.
    var anchor: Int
}

/// No path puts a caret in a rendered image or shows its Markdown (doc 26 §3,
/// §11.1): a click, an arrow, Find, Undo or a programmatic selection that lands
/// on a rendered image's line selects the image instead. Images that failed to
/// load are not rendered and keep caret editing, so their source can be fixed.
extension NativeTextViewCoordinator {

    // MARK: - Finding rendered images

    /// The rendered image on the line holding `selection`, when the selection
    /// lies between the line's start and its last character before the break.
    /// "Rendered" is the anchor the styler draws the image on.
    static func renderedImage(around selection: NSRange, in storage: NSTextStorage) -> ObjectSelection? {
        let text = storage.mutableString
        guard let line = imageLine(holding: selection, in: text) else { return nil }
        var found: ObjectSelection?
        let scope = NSRange(location: line.first, length: line.contentEnd - line.first)
        storage.enumerateAttribute(.markdownBlockSourceRange, in: scope) { value, range, stop in
            guard let value = value as? NSValue,
                  storage.attribute(.markdownBlockKind, at: range.location, effectiveRange: nil) as? String
                      == MarkdownBlockKind.image.rawValue,
                  storage.attribute(.renderedBlockImage, at: range.location, effectiveRange: nil) != nil else { return }
            let token = AnchorRelativeRange.decode(value, anchorLocation: range.location)
            guard token.location >= line.start, NSMaxRange(token) <= line.contentEnd else { return }
            found = ObjectSelection(token: token, anchor: range.location)
            stop.pointee = true
        }
        return found
    }

    /// The image token on the line holding `selection`, from the parse: what an
    /// edit's restyle is about to draw (the Undo of Delete Image restores a line
    /// the styler has not reached yet).
    static func imageToken(around selection: NSRange, tokens: [MarkdownToken], in text: NSString) -> MarkdownToken? {
        guard let line = imageLine(holding: selection, in: text) else { return nil }
        return tokens.first {
            ($0.kind == .imageLink || $0.kind == .imageEmbed) && $0.range.location == line.first
                && NSMaxRange($0.range) <= line.contentEnd && $0.standaloneParagraphRange(in: text) != nil
        }
    }

    /// The line holding `selection` when the selection stays on it and the line
    /// starts (after spaces) with `!`, the cheap test before any attribute read.
    private static func imageLine(holding selection: NSRange, in text: NSString) -> (start: Int, first: Int, contentEnd: Int)? {
        guard selection.location != NSNotFound, text.length > 0, NSMaxRange(selection) <= text.length else { return nil }
        let line = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let contentEnd = Self.contentEnd(of: line, in: text)
        guard NSMaxRange(selection) <= contentEnd else { return nil }
        var first = line.location
        while first < contentEnd, [0x20, 0x09].contains(text.character(at: first)) { first += 1 }
        guard first < contentEnd, text.character(at: first) == 0x21 else { return nil }
        return (line.location, first, contentEnd)
    }

    // MARK: - Selecting

    /// Selects `image` as a whole: its token becomes the text view's selection.
    func selectImage(_ image: ObjectSelection, in tv: NSTextView) {
        objectSelection = image
        guard tv.selectedRange() != image.token else { return }
        isSettingObjectSelection = true
        defer { isSettingObjectSelection = false }
        tv.setSelectedRange(image.token)
    }

    /// The selection handler's net (doc 26 §3.2), before the reveal pass: a
    /// selection that lands on a rendered image's line selects the image. True
    /// when it moved the selection; the handler that move ran has done the rest.
    func selectImageUnderSelection(_ selection: NSRange, in tv: NSTextView) -> Bool {
        guard !isSettingObjectSelection else { return false }
        guard tv === textView, tv.isEditable, let storage = tv.textStorage,
              let image = Self.renderedImage(around: selection, in: storage) else {
            objectSelection = nil
            return false
        }
        selectImage(image, in: tv)
        return selection != image.token
    }

    /// After an edit: an object selection holds only while the selection is its
    /// token and the image is still drawn; a ranged selection that an edit left
    /// on a rendered image's line (Undo of Delete Image) selects that image.
    /// A caret skips all of this, so typing pays nothing.
    func reconcileObjectSelectionAfterEdit(in tv: NSTextView) {
        guard tv === textView, !isComposing(in: tv), !isWritingToolsActive else { return }
        let selection = tv.selectedRange()
        guard objectSelection != nil || selection.length > 0 else { return }
        guard tv.isEditable, let storage = tv.textStorage,
              let image = Self.renderedImage(around: selection, in: storage) else {
            objectSelection = nil
            return
        }
        selectImage(image, in: tv)
    }

    /// The selection the reveal pass sees as an object: the object selection's
    /// token while it is the text view's selection.
    func objectSelectionRange(for selection: NSRange) -> NSRange? {
        guard let token = objectSelection?.token, token == selection else { return nil }
        return token
    }

    func objectSelectionDidChange(from old: ObjectSelection?) {
        if objectSelection != nil, imageChrome == nil, let main = textView as? NativeTextView {
            imageChrome = ImageChromeController(coordinator: self, textView: main)
        }
        imageChrome?.selectionDidChange(from: old)
        // Phase 3 gives the bar an image arrangement; until then it hides.
        selectionBar?.setNeedsUpdate()
        if #available(macOS 15.0, *), let tv = textView {
            if objectSelection != nil, writingToolsBehaviorBeforeObject == nil {
                writingToolsBehaviorBeforeObject = tv.writingToolsBehavior.rawValue
                tv.writingToolsBehavior = .none
            } else if objectSelection == nil, let raw = writingToolsBehaviorBeforeObject {
                writingToolsBehaviorBeforeObject = nil
                tv.writingToolsBehavior = NSWritingToolsBehavior(rawValue: raw) ?? .default
            }
        }
        if let objectSelection, objectSelection.token != old?.token {
            MarkdownTableEditingSession.announce(imageDescription(objectSelection).map { "\($0), image" } ?? "Image")
        }
    }

    /// The selected image's description as VoiceOver reads it: no tokens, escapes
    /// decoded; an embed's file name. Nil when it has none.
    /// Parses the token's own source: the note's parse would be checked against
    /// the whole note first, two full-length compares per selection at 5 MB.
    func imageDescription(_ image: ObjectSelection) -> String? {
        guard let text = textView?.textStorage?.mutableString, NSMaxRange(image.token) <= text.length else { return nil }
        let source = text.substring(with: image.token) as NSString
        guard let token = MarkdownTokenizer.parseTokensViaAST(in: source as String, memoizing: false).first(where: {
            $0.range == NSRange(location: 0, length: source.length) && ($0.kind == .imageLink || $0.kind == .imageEmbed)
        }) else { return nil }
        let description = NativeTextView.imageDescription(for: token, in: source)
        return description.isEmpty ? nil : description
    }

    // MARK: - Keys (doc 26 §11.1)

    /// Keys on an object-selected image, and the Backspace / ⌦ that select the
    /// image next to the caret. Nil leaves the key to the other handlers.
    func handleImageCommand(_ selector: Selector, in tv: NSTextView) -> Bool? {
        guard tv === textView, tv.isEditable, !isComposing(in: tv), let storage = tv.textStorage else { return nil }
        let selection = tv.selectedRange()
        if let object = objectSelection, selection == object.token {
            return handleObjectCommand(selector, on: object, in: tv)
        }
        guard selection.length == 0 else { return nil }
        let backward: Bool
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)): backward = true
        case #selector(NSResponder.deleteForward(_:)): backward = false
        default: return nil
        }
        guard let image = renderedImage(nextToLineOf: selection.location, backward: backward, in: storage) else { return nil }
        selectImage(image, in: tv)
        return true
    }

    private func handleObjectCommand(_ selector: Selector, on object: ObjectSelection, in tv: NSTextView) -> Bool? {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveForward(_:)), #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveWordForward(_:)):
            moveCaret(outOf: object, forward: true, in: tv)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveBackward(_:)), #selector(NSResponder.moveWordLeft(_:)),
             #selector(NSResponder.moveWordBackward(_:)):
            moveCaret(outOf: object, forward: false, in: tv)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)), #selector(NSResponder.moveBackwardAndModifySelection(_:)):
            // Shrinking the token by one character would land back on the image:
            // the range runs from the end of the line before instead.
            extendSelection(backwardFrom: object, in: tv)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteWordForward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToEndOfLine(_:)),
             #selector(NSResponder.deleteToBeginningOfParagraph(_:)), #selector(NSResponder.deleteToEndOfParagraph(_:)),
             #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
            deleteImage(object, in: tv)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertParagraphSeparator(_:)), #selector(NSResponder.insertLineBreak(_:)):
            insertParagraph(after: object, in: tv)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
            break
        case #selector(NSResponder.cancelOperation(_:)):
            // The reference editor's Escape ladder hides the bar; the image stays selected.
            _ = selectionBar?.suppressForEscape()
        default:
            return nil
        }
        return true
    }

    /// ↓ / → put the caret at the start of the line after the image's line, ↑ / ←
    /// at the end of the line before; a rendered image there is selected
    /// instead (the net). Past either end of the note nothing moves.
    private func moveCaret(outOf object: ObjectSelection, forward: Bool, in tv: NSTextView) {
        let text = tv.string as NSString
        guard NSMaxRange(object.token) <= text.length else { return }
        let line = text.paragraphRange(for: object.token)
        let caret: Int
        if forward {
            guard NSMaxRange(line) > Self.contentEnd(of: line, in: text) else { return }
            caret = NSMaxRange(line)
        } else {
            guard line.location > 0 else { return }
            caret = Self.contentEnd(of: text.paragraphRange(for: NSRange(location: line.location - 1, length: 0)), in: text)
        }
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    /// ⇧← on an image: the image's line and the break before it.
    private func extendSelection(backwardFrom object: ObjectSelection, in tv: NSTextView) {
        let text = tv.string as NSString
        let line = text.paragraphRange(for: object.token)
        guard line.location > 0 else { return }
        let start = Self.contentEnd(of: text.paragraphRange(for: NSRange(location: line.location - 1, length: 0)), in: text)
        tv.setSelectedRange(NSRange(location: start, length: Self.contentEnd(of: line, in: text) - start),
                            affinity: .upstream, stillSelecting: false)
    }

    /// Delete Image (doc 26 §5.2): the line's content goes, its break stays, and
    /// the caret waits on the empty line. One Undo step restores the image selected.
    func deleteImage(_ object: ObjectSelection, in tv: NSTextView) {
        let source = tv.string
        let text = source as NSString
        guard NSMaxRange(object.token) <= text.length else { return }
        let line = text.paragraphRange(for: object.token)
        let content = NSRange(location: line.location, length: Self.contentEnd(of: line, in: text) - line.location)
        guard replaceSourceRanges([content], with: "", expectedSource: source, actionName: "Delete Image",
                                  selectionAfter: NSRange(location: line.location, length: 0)) else { return }
        commitTextSync(for: tv)
        MarkdownTableEditingSession.announce("Image deleted")
    }

    /// Return on an image: a new paragraph after it (a blank separator line,
    /// then the caret's line), as the table's gap caret makes one.
    private func insertParagraph(after object: ObjectSelection, in tv: NSTextView) {
        let source = tv.string
        let text = source as NSString
        guard NSMaxRange(object.token) <= text.length else { return }
        let end = Self.contentEnd(of: text.paragraphRange(for: object.token), in: text)
        _ = replaceSourceRanges([NSRange(location: end, length: 0)], with: "\n\n", expectedSource: source,
                                actionName: "Typing", selectionAfter: NSRange(location: end + 2, length: 0))
    }

    /// Backspace at the start of a line, or ⌦ at the end of one, next to a
    /// rendered image's line selects that image instead of joining the lines
    /// (ProseMirror's `selectNodeBackward` / `selectNodeForward`). A line with
    /// text looks past one blank line, as Backspace after a table does.
    private func renderedImage(nextToLineOf caret: Int, backward: Bool, in storage: NSTextStorage) -> ObjectSelection? {
        let text = storage.mutableString
        guard caret <= text.length else { return nil }
        let line = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let end = Self.contentEnd(of: line, in: text)
        func isBlank(_ range: NSRange) -> Bool {
            text.substring(with: range).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
        func neighbour(of range: NSRange) -> NSRange? {
            if backward { return range.location > 0 ? text.paragraphRange(for: NSRange(location: range.location - 1, length: 0)) : nil }
            let next = NSMaxRange(range)
            return next > Self.contentEnd(of: range, in: text) && next < text.length
                ? text.paragraphRange(for: NSRange(location: next, length: 0)) : nil
        }
        if backward {
            guard caret == line.location, caret > 0 else { return nil }
        } else {
            guard caret == end, NSMaxRange(line) > end else { return nil }
        }
        guard var other = neighbour(of: line) else { return nil }
        if !isBlank(line), isBlank(other), let further = neighbour(of: other) { other = further }
        let probe = NSRange(location: other.location, length: 0)
        return Self.renderedImage(around: probe, in: storage)
    }
}
