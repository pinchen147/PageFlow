import AppKit

/// the reference editor's selection bar (doc 24 §6.3, doc 25 §1.1):
/// `Comment | [Text style ▾] | B I U S {} Highlight | [List ▾] | Link`
/// in text (Comment when the host keeps comments), only Comment in a code
/// block, and `B I U S {} Highlight | Link` in a table cell. the reference editor's
/// Add reaction is left out (owner decision, 2026-10-15). 34 tall: a 1 pt
/// border, 4 pt padding, 24 pt controls 2 apart.
final class MarkdownSelectionBarView: NSView {
    enum Item: Hashable {
        case comment, textStyle, bold, italic, underline, strikethrough, code, highlight, list, link
    }

    static let height: CGFloat = 34
    /// Set while the bar holds the keyboard (entered with F6).
    var onKeyboardExit: (() -> Void)?
    private(set) var focusedItem: Item?
    /// Items folded into "More formatting" when the editor is too narrow.
    private(set) var folded: [Item] = []
    let moreButton = SelectionBarButton(content: .symbol("ellipsis"), tooltip: "More formatting", hasCaret: false, opensOnMouseDown: true)
    private(set) var buttons: [Item: SelectionBarButton] = [:]
    private var separators: [SelectionBarSeparator] = []
    /// The items in order, with `nil` for a separator.
    private var arrangement: [Item?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Formatting")
        let specs: [(Item, SelectionBarButton.Content, String, Bool)] = [
            (.comment, .symbol("plus.bubble"), "Comment", false),
            (.textStyle, .symbol("textformat"), "Text style", true),
            (.bold, .symbol("bold"), "Bold", false),
            (.italic, .symbol("italic"), "Italic", false),
            (.underline, .symbol("underline"), "Underline", false),
            (.strikethrough, .symbol("strikethrough"), "Strikethrough", false),
            (.code, .symbol("chevron.left.forwardslash.chevron.right"), "Code", false),
            (.highlight, .symbol("highlighter"), "Highlight", false),
            (.list, .symbol("list.bullet"), "List", true),
            (.link, .symbol("link"), "Link", false),
        ]
        for (item, content, tip, caret) in specs {
            let button = SelectionBarButton(content: content, tooltip: tip, hasCaret: caret, opensOnMouseDown: caret)
            buttons[item] = button
            addSubview(button)
        }
        buttons[.list]?.compactTrigger = true
        moreButton.isHidden = true
        addSubview(moreButton)
        arrange(inTable: false)
    }

    /// Comment leads the bar (a host that keeps comments).
    var showsComments = false {
        didSet {
            guard showsComments != oldValue else { return }
            arrangement = []
            arrange(inTable: lastArrangement.inTable, inCode: lastArrangement.inCode)
        }
    }
    private var lastArrangement = (inTable: false, inCode: false)

    // MARK: - Keyboard (F6)

    override var acceptsFirstResponder: Bool { focusedItem != nil }

    /// The visible controls in order, the overflow button last.
    private var keyboardOrder: [Item] {
        arrangement.compactMap { $0 }.filter { buttons[$0]?.isHidden == false }
    }

    /// Takes the keyboard: Text style, or Bold in a table (the reference editor).
    func beginKeyboardFocus(inTable: Bool) {
        let order = keyboardOrder
        focusedItem = inTable ? (order.contains(.bold) ? .bold : order.first) : order.first
        refreshFocusRing()
        window?.makeFirstResponder(self)
    }

    func endKeyboardFocus() {
        focusedItem = nil
        refreshFocusRing()
    }

    private func refreshFocusRing() {
        for (item, button) in buttons { button.hasKeyboardFocus = item == focusedItem }
    }

    override func keyDown(with event: NSEvent) {
        let order = keyboardOrder
        guard let current = focusedItem, let index = order.firstIndex(of: current), !order.isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 123: focusedItem = order[(index - 1 + order.count) % order.count] // ←
        case 124: focusedItem = order[(index + 1) % order.count]               // →
        case 115: focusedItem = order.first                                    // Home
        case 119: focusedItem = order.last                                     // End
        case 36, 76, 49: _ = buttons[current]?.accessibilityPerformPress()     // Return, Enter, Space
        case 125: if buttons[current]?.hasCaret == true { _ = buttons[current]?.accessibilityPerformPress() } // ↓
        case 126, 116, 121: break                                              // ↑, PageUp, PageDown
        case 53, 48:                                                           // Escape, Tab
            endKeyboardFocus()
            onKeyboardExit?()
            return
        default: return
        }
        refreshFocusRing()
    }

    override func resignFirstResponder() -> Bool {
        endKeyboardFocus()
        return super.resignFirstResponder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// The controls for a text selection, for text in a table cell (no Text
    /// style, no List: deviation a), or for a code block (only Comment).
    func arrange(inTable: Bool, inCode: Bool = false) {
        lastArrangement = (inTable, inCode)
        let comments: [Item?] = showsComments ? [.comment] : []
        let wanted: [Item?]
        if inCode {
            wanted = comments
        } else if inTable {
            wanted = comments + (showsComments ? [nil] : []) + [.bold, .italic, .underline, .strikethrough, .code, .highlight, nil, .link]
        } else {
            wanted = comments + (showsComments ? [nil] : [])
                + [.textStyle, nil, .bold, .italic, .underline, .strikethrough, .code, .highlight, nil, .list, nil, .link]
        }
        guard wanted != arrangement else { return }
        arrangement = wanted
        separators.forEach { $0.removeFromSuperview() }
        separators = wanted.filter { $0 == nil }.map { _ in SelectionBarSeparator() }
        separators.forEach(addSubview)
        for (item, button) in buttons { button.isHidden = !wanted.contains(item) }
        layoutItems()
    }

    /// Lays the controls out and sizes the bar to fit them; past
    /// `maximumWidth`, controls fold from the end (Link stays) into "More
    /// formatting", and separators left alone are dropped (the reference editor).
    func layoutItems(maximumWidth: CGFloat = .greatestFiniteMagnitude) {
        var entries = arrangement
        folded = []
        func width(of entries: [Item?], more: Bool) -> CGFloat {
            var total: CGFloat = 1 + 4 + 4 + 1
            for (index, entry) in entries.enumerated() {
                if index > 0 { total += 2 }
                total += entry.flatMap { buttons[$0]?.intrinsicContentSize.width } ?? 5
            }
            return total + (more ? 2 + 24 : 0)
        }
        while width(of: entries, more: !folded.isEmpty) > maximumWidth,
              let index = entries.lastIndex(where: { $0 != nil && $0 != .link && $0 != .comment }) {
            if let item = entries[index] { folded.insert(item, at: 0) }
            entries.remove(at: index)
            // Drop separators with no control on one side.
            while let first = entries.first, first == nil { entries.removeFirst() }
            var cleaned: [Item?] = []
            for entry in entries where !(entry == nil && cleaned.last == .some(nil)) { cleaned.append(entry) }
            entries = cleaned
        }
        for (item, button) in buttons { button.isHidden = !entries.contains(item) }
        var x: CGFloat = 1 + 4
        var separatorIndex = 0
        separators.forEach { $0.isHidden = true }
        for (index, entry) in entries.enumerated() {
            if index > 0 { x += 2 }
            let view: NSView
            if let item = entry, let button = buttons[item] { view = button } else {
                guard separatorIndex < separators.count else { continue }
                view = separators[separatorIndex]
                view.isHidden = false
                separatorIndex += 1
            }
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: x, y: 1 + 4, width: size.width, height: 24)
            x += size.width
        }
        moreButton.isHidden = folded.isEmpty
        if !folded.isEmpty {
            x += 2
            moreButton.frame = NSRect(x: x, y: 1 + 4, width: 24, height: 24)
            x += 24
        }
        setFrameSize(NSSize(width: x + 4 + 1, height: Self.height))
    }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = ChromePalette.surface.cgColor
            layer.borderColor = ChromePalette.border.cgColor
        }
        layer.borderWidth = 1
        ChromePalette.applyBarShadow(to: layer, dark: ChromePalette.isDark(effectiveAppearance))
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        buttons.values.forEach { $0.needsDisplay = true }
        separators.forEach { $0.needsDisplay = true }
    }

    /// Clicks on the bar's padding land on the nearest control (the reference editor's
    /// hit areas reach the bar's edge).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if let hit = super.hitTest(point), hit !== self { return hit }
        let visible = buttons.values.filter { !$0.isHidden }
        return visible.min { abs($0.frame.midX - local.x) < abs($1.frame.midX - local.x) } ?? self
    }
}
