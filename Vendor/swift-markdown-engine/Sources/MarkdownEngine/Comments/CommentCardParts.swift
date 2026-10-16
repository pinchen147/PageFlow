import AppKit

/// the reference editor's comment times (doc 25 §4.2): "3:42 PM" today, "Yesterday,
/// 3:42 PM", "Oct 14, 3:42 PM", the year added for other years; never "2m ago".
enum CommentTimeFormat {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return "\(day.string(from: date)), \(clock)"
    }
}

/// the reference editor's eight reactions, in order (doc 25 §6.1).
enum CommentReactions {
    static let emoji = ["\u{1F44D}", "\u{2795}", "\u{2764}\u{FE0F}", "\u{1F389}", "\u{1F440}", "\u{1F604}", "\u{1F680}", "\u{2705}"]
}

/// A 24 tall text button on a card: Cancel, Save, Delete, Show more.
final class CommentTextButton: NSView {
    enum Style { case secondary, primary, danger, link }
    let title: String
    let style: Style
    var onPress: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var hasKeyboardFocus = false { didSet { if hasKeyboardFocus != oldValue { needsDisplay = true } } }

    init(_ title: String, style: Style) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var font: NSFont { style == .link ? CommentPalette.footnote : NSFont.systemFont(ofSize: 12, weight: .medium) }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: style == .link ? width : width + 16, height: style == .link ? 17 : 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        let ink: NSColor
        switch style {
        case .primary:
            CommentPalette.accent.withAlphaComponent(isHovered ? 0.9 : 1).setFill()
            box.fill()
            ink = .white
        case .danger:
            CommentPalette.dangerFill.withAlphaComponent(isHovered ? 0.9 : 1).setFill()
            box.fill()
            ink = .white
        case .secondary:
            (isHovered ? CommentPalette.alpha2 : CommentPalette.alpha1).setFill()
            box.fill()
            ink = CommentPalette.text
        case .link:
            ink = isHovered ? CommentPalette.text : CommentPalette.secondaryText
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(isEnabled ? 1 : 0.4)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
        if hasKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            CommentPalette.accent.setStroke()
            ring.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// One reaction pill (doc 25 §6.3): rounded, 1 pt border, padding 4 × 8,
/// a 13 pt emoji and its count. Mine is accent-bordered on a 10 % accent fill.
final class CommentReactionPill: NSView {
    let emoji: String
    let count: Int
    let isMine: Bool
    var onPress: (() -> Void)?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    init(emoji: String, count: Int, isMine: Bool) {
        self.emoji = emoji
        self.count = count
        self.isMine = isMine
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(emoji) reactions: \(count)")
        setAccessibilityValue(isMine ? 1 : 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let emojiFont = NSFont.systemFont(ofSize: 13)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var intrinsicContentSize: NSSize {
        let emojiWidth = (emoji as NSString).size(withAttributes: [.font: Self.emojiFont]).width
        let countWidth = ("\(count)" as NSString).size(withAttributes: [.font: Self.countFont]).width
        return NSSize(width: ceil(8 + emojiWidth + 4 + countWidth + 8 + 2), height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isMine {
            CommentPalette.accentMuted.setFill()
            pill.fill()
            CommentPalette.accentBorder.setStroke()
        } else {
            (isHovered ? CommentPalette.alpha2 : CommentPalette.alpha1).setFill()
            pill.fill()
            CommentPalette.alpha2.setStroke()
        }
        pill.lineWidth = 1
        pill.stroke()
        let emojiSize = (emoji as NSString).size(withAttributes: [.font: Self.emojiFont])
        (emoji as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - emojiSize.height) / 2), withAttributes: [.font: Self.emojiFont])
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.countFont, .foregroundColor: isMine ? CommentPalette.accentText : CommentPalette.secondaryText,
        ]
        let countSize = ("\(count)" as NSString).size(withAttributes: countAttributes)
        ("\(count)" as NSString).draw(at: NSPoint(x: 9 + emojiSize.width + 4, y: (bounds.height - countSize.height) / 2),
                                      withAttributes: countAttributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// A comment body (doc 25 §4.2): 13/19 pt, Markdown's inline marks rendered,
/// line breaks kept.
enum CommentBodyText {
    static func attributed(_ body: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CommentPalette.bodyLineHeight
        paragraph.maximumLineHeight = CommentPalette.bodyLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [
            .font: CommentPalette.body, .foregroundColor: CommentPalette.text, .paragraphStyle: paragraph,
            .baselineOffset: CommentPalette.bodyBaselineOffset,
        ]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: body, options: options) else {
            return NSAttributedString(string: body, attributes: base)
        }
        let result = NSMutableAttributedString(string: String(parsed.characters), attributes: base)
        var offset = 0
        for run in parsed.runs {
            let utf16 = (String(parsed[run.range].characters) as NSString).length
            let range = NSRange(location: offset, length: utf16)
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
                } else if !traits.isEmpty {
                    let descriptor = CommentPalette.body.fontDescriptor.withSymbolicTraits(traits)
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: 13) ?? CommentPalette.body, range: range)
                }
                if intent.contains(.strikethrough) {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            if let link = run.link {
                result.addAttribute(.link, value: link, range: range)
            }
            offset += utf16
        }
        return result
    }
}
