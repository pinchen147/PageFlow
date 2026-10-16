import AppKit

/// the reference editor's new-comment composer (doc 25 §2): styled as a lit card —
/// radius 10, padding 12, the panel shadow — holding the "Add a comment"
/// field and an up-arrow Send, 8 apart, aligned at the bottom. No Cancel and
/// no quote: the highlight in the text is the reference. A long selection
/// adds a note that the comment attaches to its beginning.
final class CommentComposerView: CommentSurfaceView {
    let field = CommentFieldView(frame: .zero)
    let send = CommentButton(symbol: "arrow.up", tooltip: "Send")
    private let note = NSTextField(wrappingLabelWithString: "Long selection \u{2014} your comment will attach to the beginning of it.")
    var showsClampNote = false { didSet { note.isHidden = !showsClampNote; needsLayout = true } }
    var onPost: ((String) -> Void)?
    var onDiscard: (() -> Void)?
    /// The composer's height changed (the rail re-stacks).
    var onResize: (() -> Void)?

    static let padding: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        isRaised = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Add a comment")
        field.placeholder = "Add a comment"
        field.onSubmit = { [weak self] in self?.post() }
        field.onEscape = { [weak self] in self?.onDiscard?() }
        field.onChange = { [weak self] _ in self?.contentChanged() }
        send.isEnabled = false
        send.onPress = { [weak self] in self?.post() }
        note.font = CommentPalette.caption
        note.textColor = CommentPalette.mutedText
        note.isHidden = true
        addSubview(note)
        addSubview(field)
        addSubview(send)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func post() {
        guard !field.isBlank else { return }
        onPost?(field.text)
    }

    private func contentChanged() {
        send.isEnabled = !field.isBlank
        let height = fittingHeight(forWidth: bounds.width)
        if abs(height - bounds.height) > 0.5 { onResize?() }
        needsLayout = true
    }

    /// The composer's height at `width`.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = width - Self.padding * 2
        var height = Self.padding * 2
        if showsClampNote { height += noteHeight(forWidth: inner) + 8 }
        height += field.fittingHeight(forWidth: inner - 8 - 24)
        return ceil(height)
    }

    private func noteHeight(forWidth width: CGFloat) -> CGFloat {
        ceil(note.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.padding * 2
        var y = Self.padding
        if showsClampNote {
            let height = noteHeight(forWidth: inner)
            note.frame = NSRect(x: Self.padding, y: y, width: inner, height: height)
            y += height + 8
        }
        let fieldWidth = inner - 8 - 24
        let fieldHeight = field.fittingHeight(forWidth: fieldWidth)
        field.frame = NSRect(x: Self.padding, y: y, width: fieldWidth, height: fieldHeight)
        send.frame = NSRect(x: bounds.width - Self.padding - 24, y: y + fieldHeight - 24, width: 24, height: 24)
    }
}
