import AppKit

/// A formula keeps its native source storage alive while document Undo refers
/// to it, including when its rendered attachment is shown instead of its editor.
@MainActor
final class NativeSemanticCellMathEditor: NSObject, NSTextViewDelegate {
    weak var cell: NativeSemanticCellTextView?
    let objectID: UUID
    let textView = NativeSemanticCellMathSourceView(frame: .zero)
    let scroll = NSScrollView()

    init(source: String, objectID: UUID, cell: NativeSemanticCellTextView) {
        self.objectID = objectID
        self.cell = cell
        super.init()
        textView.sourceOwner = self
        textView.delegate = self
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.string = source
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 2)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        refreshAppearance()
    }

    var hasProtectedInput: Bool { textView.hasMarkedText() || textView.isCommittingSource || textView.writingToolsSource != nil }
    var committedSource: String { textView.committedSource }

    func undoManager(for view: NSTextView) -> UndoManager? { cell?.session?.undoManager(for: view) }

    func refreshAppearance() {
        guard let cell, let session = cell.session else { return }
        let theme = session.configuration.theme
        textView.isEditable = cell.isEditable
        textView.insertionPointColor = theme.bodyText
        guard !hasProtectedInput else { return }
        let font = NSFont.monospacedSystemFont(ofSize: MarkdownTableLayout.cellFont(for: session.presentationFont).pointSize, weight: .regular)
        if textView.font != font { textView.font = font }
        if textView.textColor != theme.bodyText { textView.textColor = theme.bodyText }
        textView.insertionPointColor = theme.bodyText
        textView.backgroundColor = .textBackgroundColor
        scroll.backgroundColor = .textBackgroundColor
    }

    func show() {
        guard let cell else { return }
        refreshAppearance()
        scroll.frame = NSRect(origin: .zero, size: NSSize(width: max(80, cell.bounds.width), height: max(26, cell.bounds.height)))
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        if scroll.superview !== cell { cell.addSubview(scroll) }
        cell.window?.makeFirstResponder(textView)
    }

    func dismiss(restoreFocus: Bool) {
        guard !hasProtectedInput else { return }
        changed()
        scroll.removeFromSuperview()
        if restoreFocus, let cell { cell.window?.makeFirstResponder(cell) }
    }

    func changed() {
        guard !hasProtectedInput, let cell else { return }
        cell.refreshMathObjects()
        cell.session?.textDidChange(Notification(name: NSText.didChangeNotification, object: cell))
    }

    func textDidChange(_ notification: Notification) { changed() }

    @available(macOS 15.0, *)
    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        self.textView.writingToolsSource = self.textView.committedSource
    }

    @available(macOS 15.0, *)
    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        self.textView.writingToolsSource = nil
        changed()
        cell?.session?.onInputSettled?()
    }
}

@MainActor
final class NativeSemanticCellMathSourceView: NSTextView {
    weak var sourceOwner: NativeSemanticCellMathEditor?
    var isCommittingSource = false
    var writingToolsSource: String?
    private var displacedSource: String?

    var committedSource: String {
        if let writingToolsSource { return writingToolsSource }
        let marked = markedRange()
        guard hasMarkedText(), let displacedSource, marked.location != NSNotFound,
              NSMaxRange(marked) <= (string as NSString).length else { return string }
        return (string as NSString).replacingCharacters(in: marked, with: displacedSource)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let range = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            if range.location >= 0, range.length >= 0, NSMaxRange(range) <= (self.string as NSString).length {
                displacedSource = (self.string as NSString).substring(with: range)
            }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let composing = hasMarkedText()
        isCommittingSource = composing
        super.insertText(string, replacementRange: replacementRange)
        isCommittingSource = false
        if !hasMarkedText() {
            displacedSource = nil
            if composing {
                sourceOwner?.changed()
                sourceOwner?.cell?.session?.onInputSettled?()
            }
        }
    }

    override func unmarkText() {
        super.unmarkText()
        displacedSource = nil
        if !isCommittingSource {
            sourceOwner?.changed()
            sourceOwner?.cell?.session?.onInputSettled?()
        }
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { sourceOwner?.dismiss(restoreFocus: false) }
        return accepted
    }

    override func insertNewline(_ sender: Any?) { sourceOwner?.dismiss(restoreFocus: true) }
    override func cancelOperation(_ sender: Any?) { sourceOwner?.dismiss(restoreFocus: true) }
}
