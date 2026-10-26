import AppKit

/// The text field of the reference editor's comment composer, reply box and edit box
/// (doc 25 §2.2–§2.3, §5.2–§5.3): 13/19 pt text, a muted placeholder, at
/// least 24 tall, growing to `maximumHeight` and then scrolling. Enter (and
/// ⌘Return) submits, ⇧Return adds a line, Escape gives up.
final class CommentFieldView: NSView {
    let scrollView = NSScrollView()
    let textView: CommentTextView
    var placeholder: String {
        get { textView.placeholder }
        set { textView.placeholder = newValue; setAccessibilityLabel(newValue); textView.setAccessibilityLabel(newValue) }
    }
    var maximumHeight: CGFloat = 272 { didSet { invalidateIntrinsicContentSize() } }
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    static let minimumHeight: CGFloat = 24

    var text: String {
        get { textView.string }
        set {
            guard newValue != textView.string else { return }
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            contentDidChange()
        }
    }

    /// Whether the body is only whitespace (Send stays disabled).
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A small TextKit 1 stack: the field measures its lines to grow.
    private let storage = NSTextStorage()

    override init(frame: NSRect) {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: max(frame.width, 10), height: .greatestFiniteMagnitude))
        manager.addTextContainer(container)
        textView = CommentTextView(frame: NSRect(x: 0, y: 0, width: max(frame.width, 10), height: Self.minimumHeight),
                                   textContainer: container)
        super.init(frame: frame)
        textView.font = CommentPalette.body
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CommentPalette.bodyLineHeight
        paragraph.maximumLineHeight = CommentPalette.bodyLineHeight
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: CommentPalette.body, .paragraphStyle: paragraph, .foregroundColor: CommentPalette.text,
                                     .baselineOffset: CommentPalette.bodyBaselineOffset]
        textView.textColor = CommentPalette.text
        textView.insertionPointColor = CommentPalette.text
        textView.field = self
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        addSubview(scrollView)
        setAccessibilityElement(false)
        textView.setAccessibilityRole(.textArea)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// The text's height, between 24 and `maximumHeight`.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: bounds.width))
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0, let container = textView.textContainer, let manager = textView.layoutManager else {
            return Self.minimumHeight
        }
        if abs(container.size.width - width) > 0.5 { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        let lines = max(CommentPalette.bodyLineHeight, used)
        return min(maximumHeight, max(Self.minimumHeight, ceil(lines + (Self.minimumHeight - CommentPalette.bodyLineHeight))))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = bounds.width
        let contentHeight = max(bounds.height, (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0) + 5)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        textView.textContainerInset = NSSize(width: 0, height: (Self.minimumHeight - CommentPalette.bodyLineHeight) / 2)
    }

    func focus() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    var hasFocus: Bool { window?.firstResponder === textView }

    fileprivate func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        textView.needsDisplay = true
        onChange?(text)
    }
}

/// The field's text view: draws the placeholder and maps the keys.
final class CommentTextView: NSTextView {
    weak var field: CommentFieldView?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if flags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if !hasMarkedText() {
                field?.onSubmit?()
            } else {
                super.keyDown(with: event)
            }
        case 53 where !hasMarkedText(): // Escape
            field?.onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        field?.contentDidChange()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { field?.onFocusChange?(true) }
        needsDisplay = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { field?.onFocusChange?(false) }
        needsDisplay = true
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CommentPalette.bodyLineHeight
        paragraph.maximumLineHeight = CommentPalette.bodyLineHeight
        (placeholder as NSString).draw(
            with: NSRect(x: 0, y: textContainerInset.height, width: bounds.width, height: CommentPalette.bodyLineHeight),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: CommentPalette.body, .foregroundColor: CommentPalette.mutedText, .paragraphStyle: paragraph,
                         .baselineOffset: CommentPalette.bodyBaselineOffset]
        )
    }
}
