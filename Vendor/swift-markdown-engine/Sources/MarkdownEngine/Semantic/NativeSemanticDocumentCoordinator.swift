import AppKit

/// One native input and committed-export owner for a retained semantic editor.
@MainActor
public final class NativeSemanticDocumentCoordinator: NSObject, NSTextViewDelegate {
    let textView: NativeSemanticTextView
    var configuration: MarkdownEditorConfiguration
    let documentUndoManager: UndoManager
    weak var tableWidthsController: MarkdownEditorController?
    var hasActiveComposition: Bool { textView.hasMarkedText() || documentStorage.hasActiveComposition }
    var tableWidthBindingRevision: UInt64?
    var keyBindings: MarkdownKeyBindings = .default
    var onCommittedSourceChange: ((String) -> Void)?
    var objectPopover: NSPopover?
    var imageCropView: ImageCropView?
    var imageAltPopover: ImageAltTextPopover?
    weak var preferredInputView: NSView?
    var imageControls: NativeSemanticImageControls?
    var selectionBar: NativeSemanticSelectionBar?
    var onKeyCommand: ((MarkdownEditorKeyCommand) -> Bool)?
    private var writingToolsSnapshot: SemanticMarkdownDocument?
    var onLinkClick: ((String) -> Void)?
    var onOpenLocalLink: ((URL) -> Void)?
    var onPasteImage: ((NSPasteboard) -> String?)?
    var onDropDocuments: (([URL]) -> Bool)?
    var opensDroppedFile: ((URL) -> Bool)?
    var onImportImages: ((MarkdownImageDrop, @escaping ([String]) -> Void) -> Void)?
    var onFileDragHover: ((MarkdownFileDragKind?) -> Void)?
    var onRequestFocus: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onInputSettled: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var isWritingToolsActive = false
    enum AdmissionFailure: Error { case activeComposition }
    var onExportFailure: ((Error) -> Void)?
    private(set) var revision: UInt64 = 0
    private var publication: DispatchWorkItem?
    private var composition: DisplacedText?
    private var lastPublishedSource: String
    lazy var inlineEditor = NativeSemanticInlineEditor(textView: textView)
    lazy var documentStorage = NativeSemanticDocumentStorage(textView: textView, configuration: configuration)

    private struct DisplacedText {
        let content: NSAttributedString
    }

    init(source: String, configuration: MarkdownEditorConfiguration, undoManager: UndoManager,
         fontName: String = "SF Pro", fontSize: CGFloat = 16) throws {
        let imported = try SemanticMarkdownImport.decode(source)
        self.configuration = configuration
        documentUndoManager = undoManager
        lastPublishedSource = source
        textView = NativeSemanticTextView(usingTextLayoutManager: true)
        super.init()
        textView.font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        configureNativeInput()
        textView.delegate = self
        textView.semanticCoordinator = self
        documentStorage.load(imported)
        documentStorage.onChange = { [weak self] in self?.committedContentChanged() }
        documentStorage.onInputSettled = { [weak self] in self?.onInputSettled?() }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(nativeHistoryDidReplay(_:)),
                                                   name: name, object: documentUndoManager)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func nativeHistoryDidReplay(_ notification: Notification) {
        guard !hasActiveComposition, !isWritingToolsActive else { return }
        // Native Undo restores attributed runs after its text-change callback.
        // Repair paragraph identities only once that complete replay has ended.
        textView.preservingSemanticViewport(requireEdit: false, revealCaret: false) {
            admitParagraphRoles()
            documentStorage.restoreImportedIdentityIfUnchanged()
            refreshCurrentCodeHighlighting()
        }
        committedContentChanged()
    }

    func makeNativeView(frame: NSRect) -> NSScrollView {
        let scroll = ClampedScrollView(frame: frame)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        textView.frame = NSRect(origin: .zero, size: frame.size)
        textView.minSize = NSSize(width: 0, height: frame.height)
        scroll.documentView = textView
        textView.updateSemanticGeometry()
        selectionBar = NativeSemanticSelectionBar(owner: self, scroll: scroll)
        imageControls = NativeSemanticImageControls(owner: self)
        return scroll
    }

    public func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager }

    public func textDidChange(_ notification: Notification) {
        guard !isWritingToolsActive, !textView.isSettingMarkedText, !textView.isCommittingMarkedText,
              !textView.hasMarkedText() else { return }
        admitParagraphRoles()
        refreshCurrentCodeHighlighting()
        committedContentChanged()
    }

    func handleKeyEquivalent(_ event: NSEvent, in view: NSTextView) -> Bool {
        guard view === textView, view.window?.firstResponder === view,
              view.isEditable, !view.hasMarkedText(), let command = keyBindings.command(for: event) else { return false }
        if command == .focusSelectionBar, selectionBar?.focusBar() == true { return true }
        if command == .link, selectionBar != nil { selectionBar?.showLinkEditor(); return true }
        if onKeyCommand?(command) == true { return true }
        guard let format = command.format else { return false }
        return applyFormat(format)
    }

    /// Export failures remain failures; callers must retain the dirty draft rather than save old source.
    func flushCommittedSource() throws -> String {
        publication?.cancel()
        publication = nil
        let source = try exportResult().source
        if !source.utf16.elementsEqual(lastPublishedSource.utf16) {
            lastPublishedSource = source
            onCommittedSourceChange?(source)
        }
        return source
    }

    func snapshot() -> SemanticMarkdownDocument { documentStorage.snapshot() }

    func exportResult() throws -> SemanticMarkdownExportResult {
        if let writingToolsSnapshot { return try SemanticMarkdownImport.export(writingToolsSnapshot) }
        if let composition, textView.hasMarkedText(), let storage = textView.textStorage {
            let marked = textView.markedRange()
            guard marked.location != NSNotFound, marked.location <= storage.length,
                  marked.length <= storage.length - marked.location else { throw SemanticInlineText.EditError.invalidRange }
            let committed = NSMutableAttributedString(attributedString: storage)
            committed.replaceCharacters(in: marked, with: composition.content)
            return try SemanticMarkdownImport.export(documentStorage.snapshot(attributedText: committed))
        }
        return try SemanticMarkdownImport.export(snapshot())
    }

    func replaceSource(_ source: String) throws {
        guard !hasActiveComposition, !isWritingToolsActive else { throw AdmissionFailure.activeComposition }
        let document = try SemanticMarkdownImport.decode(source)
        publication?.cancel()
        composition = nil
        documentStorage.load(document, selectedRange: textView.selectedRange())
        lastPublishedSource = source
        revision &+= 1
        documentUndoManager.removeAllActions()
    }

    @discardableResult
    func updateConfiguration(_ configuration: MarkdownEditorConfiguration, fontName: String = "SF Pro", fontSize: CGFloat = 16) -> Bool {
        guard !hasActiveComposition, !isWritingToolsActive else { return false }
        let document = snapshot()
        let selection = textView.selectedRange()
        let editable = textView.isEditable
        var typing = textView.typingAttributes
        self.configuration = configuration
        configureNativeInput()
        textView.isEditable = editable
        let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        textView.font = font
        documentStorage.configuration = configuration
        documentStorage.baseFont = font
        documentStorage.load(document, selectedRange: selection)
        typing[.font] = font
        typing[NativeSemanticAttributes.baseFont] = font
        let marks = SemanticInlineMarks(rawValue: (typing[NativeSemanticAttributes.marks] as? NSNumber)?.intValue ?? 0)
        textView.typingAttributes = NativeSemanticAttributes.render(marks, over: typing)
        textView.updateSemanticGeometry()
        return true
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionBar?.update()
        imageControls?.refresh()
        onSelectionChange?()
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        writingToolsSnapshot = snapshot()
        isWritingToolsActive = true
        publication?.cancel()
        publication = nil
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        isWritingToolsActive = false
        writingToolsSnapshot = nil
        admitParagraphRoles()
        refreshCurrentCodeHighlighting()
        committedContentChanged()
        onInputSettled?()
    }

    func beginComposition(replacing range: NSRange) -> Bool {
        guard composition == nil else { return true }
        guard let storage = textView.textStorage, range.location >= 0, range.length >= 0,
              range.location <= storage.length, range.length <= storage.length - range.location else { return false }
        composition = DisplacedText(content: NSAttributedString(attributedString: storage.attributedSubstring(from: range)))
        publication?.cancel()
        publication = nil
        return true
    }

    func finishedComposition() {
        guard !textView.hasMarkedText() else { return }
        composition = nil
        admitParagraphRoles()
        refreshCurrentCodeHighlighting()
        committedContentChanged()
        onInputSettled?()
    }

    func committedContentChanged() {
        revision &+= 1
        publication?.cancel()
        guard !textView.hasMarkedText() else { return }
        let expected = revision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == expected, !self.textView.hasMarkedText() else { return }
            do { _ = try self.flushCommittedSource() }
            catch { self.onExportFailure?(error) }
        }
        publication = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func configureNativeInput() {
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.insertionPointColor = configuration.theme.bodyText
        textView.textColor = configuration.theme.bodyText
        textView.linkTextAttributes = [.foregroundColor: configuration.theme.link]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: configuration.horizontalLayoutInset,
                                             height: configuration.textInsets.vertical)
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking.automaticSpellingCorrection
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = configuration.spellChecking.grammarChecking
        textView.isAutomaticQuoteSubstitutionEnabled = configuration.inputSubstitution.automaticQuoteSubstitution
        textView.isAutomaticDataDetectionEnabled = configuration.inputSubstitution.automaticDataDetection
        textView.isAutomaticDashSubstitutionEnabled = configuration.inputSubstitution.automaticDashSubstitution
        textView.isAutomaticTextReplacementEnabled = configuration.inputSubstitution.automaticTextReplacement
    }
}
