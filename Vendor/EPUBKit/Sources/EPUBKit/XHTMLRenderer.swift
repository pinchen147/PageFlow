import AppKit
import Foundation
import ImageIO

final class XHTMLRenderer: NSObject, XMLParserDelegate {
    private struct Style {
        var font = NSFont.systemFont(ofSize: 18)
        var color = NSColor.labelColor
        var link: URL?
        var paragraph: NSParagraphStyle = Metrics.body
        var preservesWhitespace = false
        var hidden = false
        var underlined = false
        /// Raised (superscript) or lowered (subscript) from the baseline.
        var baselineOffset: CGFloat = 0

        /// Nested elements share their parent's paragraph style; change a copy.
        mutating func updateParagraph(_ change: (NSMutableParagraphStyle) -> Void) {
            let copy = paragraph.mutableCopy() as! NSMutableParagraphStyle
            change(copy)
            paragraph = copy
        }
    }

    /// Block spacing and indents in points at the 18pt base size. The app's
    /// typography scales every one of them with the body size.
    private enum Metrics {
        static let em: CGFloat = 18
        static let paragraphSpacing = em * 0.55
        static let listItemSpacing = em * 0.3
        static let headingSpaceBefore = em * 1.2
        static let headingSpaceAfter = em * 0.4
        static let quoteIndent = em * 2
        /// Each list level moves item text this far in.
        static let listIndent = em * 1.6
        /// The marker hangs this far left of the item text.
        static let markerHang = em * 1.4

        /// Body text: justified like a printed book, with light hyphenation
        /// so justified Latin lines don't open wide gaps. CJK has no
        /// hyphenation dictionary, so the factor leaves it untouched. Never
        /// mutated: changes go to a copy (`Style.updateParagraph`).
        nonisolated(unsafe) static let body: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = paragraphSpacing
            style.alignment = .justified
            style.hyphenationFactor = 0.9
            return style
        }()
    }

    private struct PendingImage {
        let location: Int
        var source: String
        let alt: String?
        /// An inline `<svg>` document; `source` is then its key in the image store.
        var inline: Data?
        /// What the book's markup and stylesheets say of its size.
        var declared = EPUBImageSizing.Declared()
    }

    private struct OpenElement {
        let name: String
        let id: String?
        /// For matching stylesheet rules against an image's ancestors.
        let attributes: [String: String]
        let start: Int
        /// Marked as a note, itself or by an enclosing element.
        let isMarkedNote: Bool
        /// Inline ids at the start of this block, which point to it.
        var inlineIDs: [(id: String, isMarkedNote: Bool)] = []
        /// A footnote or endnote block (aside, div or p), left out of the
        /// reading flow once a note reference in the chapter points to it.
        var isNoteAside = false
        /// Its place in ``XHTMLRenderer/elementRanges``.
        var order = 0
        /// Set upright in one character's space, in a vertical chapter.
        var combinesUpright = false
    }

    /// Blocks that can hold a footnote or endnote.
    private static let noteBlocks: Set<String> = ["aside", "li", "p", "div", "dd", "section", "blockquote"]
    /// Blocks of these types are notes the reader reaches by their reference.
    private static let asideNoteTypes: Set<String> = [
        "footnote", "endnote", "rearnote", "doc-footnote", "doc-endnote", "doc-rearnote"
    ]
    private static let noteTypes: Set<String> = [
        "footnote", "endnote", "rearnote", "note", "footnotes", "endnotes", "rearnotes",
        "doc-footnote", "doc-endnote", "doc-endnotes", "doc-rearnote", "doc-rearnotes"
    ]

    /// Elements that start and end their own paragraph.
    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "aside", "header", "footer", "nav", "main", "blockquote",
        "figure", "figcaption", "table", "caption", "tr", "td", "th", "ul", "ol", "li", "dl", "dt", "dd",
        "pre", "hr", "h1", "h2", "h3", "h4", "h5", "h6"
    ]
    /// Table structure that holds cells, never text of its own.
    private static let tableStructure: Set<String> = ["table", "thead", "tbody", "tfoot", "tr", "colgroup", "col"]

    private let archive: ArchiveReader
    private let resourcePath: String
    /// nil for the search render, which needs only the one-character slots.
    private let images: EPUBImageStore?
    private let output = NSMutableAttributedString()
    private var styles = [Style()]
    private var elements: [String] = []
    private var parseError: Error?
    private var pendingImages: [PendingImage] = []
    /// The inline `<svg>` being read, from its root to its end.
    private var svgCapture: SVGCapture?
    /// The `<math>` being read, from its root to its end.
    private var mathCapture: MathMLCapture?
    /// Formulas read, each with its slot and the text shown if it can't be typeset.
    private var pendingMath: [(location: Int, formula: EPUBMathFormula, fallback: String)] = []
    /// Open lists, innermost last, with the number their next item gets.
    private var lists: [(ordered: Bool, next: Int)] = []
    /// A list item's marker waits for the item's first visible content, so
    /// an empty item never leaves a lone marker or a blank line.
    private var pendingMarker: Style?
    /// Open tables, innermost last.
    private var tables: [TableBuilder] = []
    /// Open `<ruby>` elements, innermost last.
    private var rubies: [RubyBuilder] = []
    /// The `<rt>` being read: its text goes on the base, never into the chapter.
    private var readingCapture: String?
    private(set) var anchors: [String: Int] = [:]
    /// Elements with an id that a note reference could point to.
    private(set) var noteTargets: [String: EPUBNoteTarget] = [:]
    /// Notes taken out of the reading flow, by every id inside them.
    private(set) var detachedNotes: [String: NSAttributedString] = [:]
    /// One id for each whole note left out, in the book's order.
    private(set) var detachedNoteIDs: [String] = []
    /// Footnote blocks with an id, where they sit in the text.
    private var noteAsides: [(id: String, range: NSRange)] = []
    /// Ids in this chapter that a note reference points to.
    /// Where each note in this chapter is linked from.
    private var noteReferences: [String: [Int]] = [:]
    private var tableFinishes: [() -> Void] = []
    /// Every open element, innermost last, for note targets.
    private var openElements: [OpenElement] = []
    /// Open `<a>` elements, innermost last: where each starts and whether it
    /// is marked as a note reference.
    private var openLinks: [(start: Int, marked: Bool)] = []
    private(set) var estimatedMemoryCost = 0
    private(set) var notices: [EPUBContentNotice] = []
    /// Every element's text range, in document order, for placing a fixed page.
    private(set) var elementRanges: [NSRange] = []
    /// Each installed image by its character, for placing a fixed page.
    private(set) var installedImages: [Int: (path: String, pixels: NSSize)] = [:]

    /// Images scale down, keeping their aspect, to fit this box.
    private let imageBounds: CGSize

    private let mathTypesetter: EPUBMathTypesetter?
    /// A fixed page keeps its notes where they are placed; the search render
    /// says the same, so offsets agree.
    private let keepsNotesInline: Bool
    private var writing = ChapterWriting()
    /// The chapter's stylesheets, read for the first image that asks.
    private lazy var imageCSS = archive.stylesheets.imageCSS(for: writing.stylesheets)
    private lazy var imageRulesUseIDs = imageCSS.usesIDs
    /// What images already asked of `imageCSS`, by what its rules can tell apart.
    private var declaredImageSizes: [String: EPUBImageSizing.Declared] = [:]
    /// A vertical chapter's columns, cut from the page like a horizontal one's lines.
    private var isVertical: Bool { writing.mode == .verticalRightToLeft }
    /// How long a line runs on this page.
    private var lineLength: CGFloat { isVertical ? imageBounds.height : imageBounds.width }

    init(archive: ArchiveReader, resourcePath: String, images: EPUBImageStore?,
         imageBounds: CGSize = CGSize(width: 720, height: CGFloat.greatestFiniteMagnitude),
         mathTypesetter: EPUBMathTypesetter? = EPUBMath.typesetter, keepsNotesInline: Bool = false) {
        self.keepsNotesInline = keepsNotesInline
        self.imageBounds = imageBounds
        self.mathTypesetter = mathTypesetter
        self.archive = archive
        self.resourcePath = resourcePath
        self.images = images
    }

    func render(_ data: Data) throws -> NSAttributedString {
        // The search render needs only the text, the same in any writing mode.
        if images != nil { writing = WritingModeScanner.scan(data, resourcePath: resourcePath, archive: archive) }
        if writing.mode == .verticalLeftToRight { addNotice(.verticalWritingFallback) }
        let parser = XMLParser(data: XMLDocumentParser.prepared(data))
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        guard parser.parse(), parseError == nil else {
            let reason = parseError?.localizedDescription ?? parser.parserError?.localizedDescription ?? "Malformed XHTML"
            throw EPUBError.invalidContent("\(resourcePath): \(reason)")
        }
        centerStandaloneImages()
        installImages()
        installMath()
        tableFinishes.forEach { $0() }
        tableFinishes = []
        if !keepsNotesInline { detachReferencedNotes() }
        // A placed page draws where its boxes say, never in columns.
        if isVertical, !keepsNotesInline, output.length > 0 {
            output.addAttribute(EPUBWriting.verticalAttribute, value: true, range: NSRange(location: 0, length: output.length))
        }
        estimatedMemoryCost += output.length * MemoryLayout<unichar>.stride
        return output.copy() as! NSAttributedString
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = XMLNode.local(elementName)
        elements.append(name)
        var style = styles.last ?? Style()
        svgCapture?.open(elementName, attributes: attributeDict)
        mathCapture?.open(name, attributes: attributeDict)
        // A whole chapter's writing mode was read before the parse; an inner
        // element's isn't laid out.
        if name != "html", name != "body", !isVertical,
           let inline = attributeDict["style"],
           let mode = CSSRules.declarations(inline).compactMap(CSSRules.writingMode).last, mode != .horizontal {
            addNotice(.verticalWritingFallback)
        }
        if Self.blockElements.contains(name), mathCapture == nil {
            ensureParagraphBreak()
        }
        for anchor in [attributeDict["id"], name == "a" ? attributeDict["name"] : nil].compactMap({ $0 }) {
            if anchors[anchor] == nil { anchors[anchor] = output.length }
        }
        let types = Self.semanticTypes(attributeDict)
        openElements.append(OpenElement(
            name: name,
            id: types.contains("pagebreak") || types.contains("doc-pagebreak")
                ? nil : attributeDict["id"] ?? (name == "a" ? attributeDict["name"] : nil),
            attributes: attributeDict,
            start: output.length,
            isMarkedNote: (openElements.last?.isMarkedNote ?? false) || !types.isDisjoint(with: Self.noteTypes),
            isNoteAside: ["aside", "div", "p"].contains(name) && !types.isDisjoint(with: Self.asideNoteTypes),
            order: elementRanges.count
        ))
        elementRanges.append(NSRange(location: output.length, length: 0))
        if isVertical, combinesUpright(attributeDict), !openElements.isEmpty {
            openElements[openElements.count - 1].combinesUpright = true
        }
        if name == "a" {
            openLinks.append((output.length, types.contains("noteref") || types.contains("doc-noteref")))
        }
        // Before any marker or text, so the paragraph's first character carries it.
        applyBlockLayout(name, attributes: attributeDict, to: &style)
        if Self.blockElements.contains(name) || name == "html" || name == "body",
           let direction = Self.writingDirection(attributeDict) {
            style.updateParagraph { $0.baseWritingDirection = direction }
        }
        switch name {
        case "script", "style", "head": style.hidden = true
        case "strong", "b": style.font = converted(style.font, trait: .boldFontMask)
        case "em", "i", "cite": style.font = converted(style.font, trait: .italicFontMask)
        case "u": style.underlined = true
        case "sup", "sub":
            // Note markers and exponents: smaller, off the baseline.
            let size = style.font.pointSize
            style.font = NSFontManager.shared.convert(style.font, toSize: (size * 0.7).rounded())
            style.baselineOffset += name == "sup" ? (size * 0.35).rounded() : -(size * 0.15).rounded()
        case "code", "pre", "kbd", "samp":
            style.font = .monospacedSystemFont(ofSize: style.font.pointSize, weight: .regular)
            style.preservesWhitespace = true
        case "h1": style.font = .systemFont(ofSize: 34, weight: .bold)
        case "h2": style.font = .systemFont(ofSize: 28, weight: .bold)
        case "h3": style.font = .systemFont(ofSize: 24, weight: .semibold)
        case "h4", "h5", "h6": style.font = .systemFont(ofSize: 20, weight: .semibold)
        case "li":
            pendingMarker = style
        case "ol", "ul":
            let start = name == "ol" ? attributeDict["start"].flatMap { Int($0) } ?? 1 : 1
            lists.append((name == "ol", start))
        case "br": append("\n", style: style)
        case "th":
            style.font = converted(style.font, trait: .boldFontMask)
        case "table":
            tables.append(TableBuilder(outerBlocks: style.paragraph.textBlocks))
        case "tr":
            tables.last?.startRow()
        case "a":
            if let href = attributeDict["href"] {
                // Colour and underline come from the reader's theme.
                if let link = resolvedLink(href) { style.link = link }
            }
        case "img", "image":
            let source = attributeDict["src"] ?? attributeDict["xlink:href"] ?? attributeDict["href"]
            if let source {
                if let scheme = URL(string: source)?.scheme,
                   ["http", "https"].contains(scheme.lowercased()) {
                    addNotice(.remoteResourceUnavailable)
                }
                // One U+FFFC per image from the start, so anchors and search
                // offsets never shift when the attachment is installed.
                if !style.hidden {
                    pendingImages.append(PendingImage(location: output.length, source: source, alt: attributeDict["alt"],
                                                      declared: images == nil ? .init() : declaredImageSize()))
                    append("\u{FFFC}", style: style)
                }
            }
        case "svg":
            // An inline drawing is one image: its slot now, its markup kept
            // until it ends, its text never shown.
            if svgCapture == nil {
                var slot: Int?
                if !style.hidden {
                    slot = pendingImages.count
                    pendingImages.append(PendingImage(location: output.length, source: "", alt: attributeDict["aria-label"]))
                    append("\u{FFFC}", style: style)
                }
                svgCapture = SVGCapture(root: elementName, attributes: attributeDict, slot: slot)
            }
            style.hidden = true
        case "ruby":
            rubies.append(RubyBuilder(baseStart: output.length))
        case "rb":
            rubies.last?.openBase = output.length
        case "rtc":
            // A second side of annotations isn't drawn; its loose text stays out too.
            guard let ruby = rubies.last else { break }
            ruby.skipsReadings = ruby.annotated != nil
            style.hidden = true
        case "rt":
            guard !rubies.isEmpty else { break }
            readingCapture = ""
            style.hidden = true
        case "rp":
            // The parentheses a reader without ruby support shows.
            if !rubies.isEmpty { style.hidden = true }
        case "math":
            // One slot for the whole formula; its markup is read until it ends.
            guard mathCapture == nil else { break }
            if MathMLCapture.isDisplay(attributeDict) {
                ensureParagraphBreak()
                style.updateParagraph {
                    $0.alignment = .center
                    $0.hyphenationFactor = 0
                    $0.firstLineHeadIndent = $0.headIndent
                }
            }
            let isHidden = style.hidden
            // After the append: the first text in a list item brings its marker.
            append("\u{FFFC}", style: style)
            mathCapture = MathMLCapture(attributes: attributeDict, location: isHidden ? nil : output.length - 1)
            style.hidden = true
        case "audio":
            addNotice(.audioUnavailable)
            append("[Audio unavailable]", style: style)
            style.hidden = true
        case "video":
            addNotice(.videoUnavailable)
            append("[Video unavailable]", style: style)
            style.hidden = true
        default: break
        }
        if let inline = attributeDict["style"]?.lowercased(), inline.contains("display:none") {
            style.hidden = true
        }
        styles.append(style)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let svgCapture {
            svgCapture.text(string)
            return
        }
        if let mathCapture {
            mathCapture.text(string)
            return
        }
        if readingCapture != nil {
            readingCapture? += string
            return
        }
        guard let style = styles.last, !style.hidden else { return }
        // Text between cells would break the table apart.
        if let parent = elements.last, Self.tableStructure.contains(parent), !tables.isEmpty { return }
        guard !style.preservesWhitespace else {
            append(string, style: style)
            return
        }
        // HTML collapses only ASCII whitespace; no-break and ideographic
        // spaces (a CJK paragraph's indent) are text.
        var text = string.replacingOccurrences(of: "[ \t\n\r\u{0C}]+", with: " ", options: .regularExpression)
        if text.hasPrefix(" "), followsBreakOrSpace { text.removeFirst() }
        append(text, style: style)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = XMLNode.local(elementName)
        let style = styles.last ?? Style()
        if let capture = svgCapture, capture.close(elementName) {
            svgCapture = nil
            finishSVG(capture)
        }
        switch name {
        case "rb": rubies.last?.closeBase(at: output.length)
        case "rt":
            if let reading = readingCapture {
                readingCapture = nil
                attachReading(reading)
            }
        case "ruby": _ = rubies.popLast()
        default: break
        }
        if let capture = mathCapture, capture.close() {
            mathCapture = nil
            finishMath(capture)
            if capture.isDisplay { ensureParagraphBreak() }
        }
        if Self.blockElements.contains(name), mathCapture == nil {
            ensureParagraphBreak()
        }
        if name == "td" || name == "th", let table = tables.last, style.paragraph.textBlocks.count > table.outerBlocks.count {
            // An empty cell still needs its paragraph, or the row loses it.
            if output.length == openElements.last?.start { append("\n", style: style) }
            table.endCell(at: output.length)
        }
        if name == "table", let table = tables.popLast() {
            // Measured once images and formulas are in, or a column holding
            // one is sized for its placeholder.
            let end = output.length
            tableFinishes.append { [unowned self] in
                table.finish(in: output, width: lineLength)
                table.keepNextParagraphClear(at: end, in: output)
            }
        }
        if name == "li" { pendingMarker = nil }
        if name == "ol" || name == "ul" { _ = lists.popLast() }
        if name == "a", let link = openLinks.popLast() { markNoteReference(from: link.start, marked: link.marked) }
        if let element = openElements.popLast() {
            elementRanges[element.order].length = max(0, output.length - element.start)
            recordNoteTarget(element)
            if element.combinesUpright { markCombined(from: element.start) }
            if element.isNoteAside, let id = element.id, output.length > element.start {
                noteAsides.append((id, NSRange(location: element.start, length: output.length - element.start)))
            }
        }
        _ = styles.popLast()
        _ = elements.popLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private func append(_ string: String, style: Style) {
        guard !string.isEmpty, !style.hidden else { return }
        if let marker = pendingMarker, string.contains(where: { !$0.isWhitespace }) {
            pendingMarker = nil
            var label = "•"
            if elements.contains("nav") {
                // EPUB navigation lists carry no markers (EPUB 3 nav: list-style none);
                // their entries usually number themselves.
                label = ""
            } else if let index = lists.indices.last, lists[index].ordered {
                label = "\(lists[index].next)."
                lists[index].next += 1
            }
            // The tab reaches the item's hanging indent, so wrapped lines align.
            append(label + "\t", style: marker)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.color,
            .paragraphStyle: style.paragraph
        ]
        if let link = style.link { attributes[.link] = link }
        if style.underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.baselineOffset != 0 { attributes[.baselineOffset] = style.baselineOffset }
        output.append(NSAttributedString(string: string, attributes: attributes))
    }

    /// Ends the current paragraph. A paragraph holding only whitespace is
    /// dropped instead, so stray spaces between blocks (common around list
    /// items) never become blank lines.
    private func ensureParagraphBreak() {
        guard output.length > 0, !endsWithNewline else { return }
        if let blank = trailingBlankParagraph() {
            output.deleteCharacters(in: blank)
            for (anchor, location) in anchors where location > blank.location {
                anchors[anchor] = blank.location
            }
            return
        }
        append("\n", style: styles.last ?? Style())
    }

    /// The unfinished last paragraph, if it is only whitespace. Stops at the
    /// first visible character, so a normal paragraph costs one comparison.
    private func trailingBlankParagraph() -> NSRange? {
        let text = output.mutableString
        var index = text.length
        while index > 0 {
            let character = text.character(at: index - 1)
            if character == 0x0A { break }
            guard let scalar = Unicode.Scalar(character), scalar.properties.isWhitespace else { return nil }
            index -= 1
        }
        return NSRange(location: index, length: text.length - index)
    }

    private var endsWithNewline: Bool {
        output.length > 0 && output.mutableString.character(at: output.length - 1) == 0x0A
    }

    /// Whether collapsed text starting with a space would double a gap or
    /// indent a line.
    private var followsBreakOrSpace: Bool {
        guard output.length > 0 else { return true }
        return [0x0A, 0x20, 0x09].contains(output.mutableString.character(at: output.length - 1))
    }

    /// Paragraph layout for block elements: headings, quotes, lists, figures
    /// and code each get their own spacing, indents and alignment.
    private func applyBlockLayout(_ name: String, attributes: [String: String], to style: inout Style) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            style.updateParagraph {
                // A heading inside a figure is its caption and stays centered.
                if $0.alignment != .center { $0.alignment = .natural }
                $0.hyphenationFactor = 0
                $0.firstLineHeadIndent = $0.headIndent
                $0.paragraphSpacingBefore = Metrics.headingSpaceBefore
                $0.paragraphSpacing = Metrics.headingSpaceAfter
                // Marks the heading for pagination, which keeps it with what follows.
                $0.headerLevel = Int(name.dropFirst()) ?? 1
            }
        case "blockquote":
            style.updateParagraph {
                $0.headIndent += Metrics.quoteIndent
                $0.firstLineHeadIndent = $0.headIndent
                $0.tailIndent -= Metrics.quoteIndent
            }
        case "li":
            if let value = attributes["value"].flatMap({ Int($0) }), let index = lists.indices.last {
                lists[index].next = value
            }
            style.updateParagraph {
                $0.headIndent += Metrics.listIndent
                $0.firstLineHeadIndent = $0.headIndent - Metrics.markerHang
                $0.tabStops = [NSTextTab(textAlignment: .natural, location: $0.headIndent)]
                $0.alignment = .natural
                $0.hyphenationFactor = 0
                $0.paragraphSpacingBefore = 0
                $0.paragraphSpacing = Metrics.listItemSpacing
            }
        case "figure", "figcaption":
            style.updateParagraph {
                $0.alignment = .center
                $0.hyphenationFactor = 0
                $0.firstLineHeadIndent = $0.headIndent
            }
        case "pre":
            style.updateParagraph {
                $0.alignment = .natural
                $0.hyphenationFactor = 0
                $0.paragraphSpacing = 0
            }
        case "table", "dt":
            style.updateParagraph {
                $0.alignment = .natural
                $0.hyphenationFactor = 0
            }
        case "caption":
            style.updateParagraph {
                $0.alignment = .center
                $0.hyphenationFactor = 0
                $0.firstLineHeadIndent = $0.headIndent
                $0.paragraphSpacing = Metrics.listItemSpacing
            }
        case "td", "th":
            guard let table = tables.last else { break }
            let block = table.startCell(attributes: attributes, at: output.length)
            let align = attributes["align"]?.lowercased()
            style.updateParagraph {
                $0.textBlocks = table.outerBlocks + [block]
                $0.alignment = align == "center" || (align == nil && name == "th") ? .center
                    : align == "right" ? .right : .natural
                $0.hyphenationFactor = 0
                $0.headIndent = 0
                $0.firstLineHeadIndent = 0
                $0.tailIndent = 0
                $0.tabStops = []
                $0.paragraphSpacing = 0
                $0.paragraphSpacingBefore = 0
                $0.headerLevel = 0
            }
        case "dd":
            style.updateParagraph {
                $0.headIndent += Metrics.quoteIndent
                $0.firstLineHeadIndent = $0.headIndent
            }
        default:
            // A later paragraph inside a list item lines up with the item's
            // text rather than its marker.
            if Self.blockElements.contains(name), pendingMarker == nil,
               style.paragraph.firstLineHeadIndent < style.paragraph.headIndent {
                style.updateParagraph { $0.firstLineHeadIndent = $0.headIndent }
            }
        }
    }

    /// An image alone in its paragraph is a figure: center it.
    private func centerStandaloneImages() {
        let text = output.mutableString
        for image in pendingImages {
            let paragraph = text.paragraphRange(for: NSRange(location: image.location, length: 0))
            // Longer paragraphs hold text, so this stays cheap per image.
            guard paragraph.length <= 64 else { continue }
            let standalone = (paragraph.location..<NSMaxRange(paragraph)).allSatisfy { index in
                let character = text.character(at: index)
                return index == image.location || Unicode.Scalar(character)?.properties.isWhitespace == true
            }
            guard standalone,
                  let current = output.attribute(.paragraphStyle, at: image.location, effectiveRange: nil)
                    as? NSParagraphStyle,
                  let centered = current.mutableCopy() as? NSMutableParagraphStyle else { continue }
            centered.alignment = .center
            centered.hyphenationFactor = 0
            centered.firstLineHeadIndent = centered.headIndent
            output.addAttribute(.paragraphStyle, value: centered, range: paragraph)
        }
    }

    /// Languages written right to left.
    private static let rightToLeftLanguages: Set<String> = ["ar", "he", "iw", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb"]

    /// A block's text direction: its `dir`, else right to left for a
    /// right-to-left `lang`. Natural alignment then follows it.
    private static func writingDirection(_ attributes: [String: String]) -> NSWritingDirection? {
        switch attributes["dir"]?.lowercased() {
        case "rtl": return .rightToLeft
        case "ltr": return .leftToRight
        default: break
        }
        guard let lang = (attributes["xml:lang"] ?? attributes["lang"])?.lowercased(),
              let code = lang.split(separator: "-").first else { return nil }
        return rightToLeftLanguages.contains(String(code)) ? .rightToLeft : nil
    }

    /// The element's epub:type and role tokens.
    private static func semanticTypes(_ attributes: [String: String]) -> Set<String> {
        let values = attributes.filter { $0.key == "role" || $0.key.hasSuffix(":type") }.values
        return Set(values.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
    }

    /// Tags a book link that reads as a note reference, so the reader can
    /// show the note instead of jumping: marked as one, or a short number
    /// or symbol, or superscript.
    private func markNoteReference(from start: Int, marked: Bool) {
        guard output.length > start else { return }
        // From the first linked character: a list marker may come before it.
        var link: URL?
        var first = start
        output.enumerateAttribute(.link, in: NSRange(location: start, length: output.length - start)) { value, subrange, stop in
            if let value = value as? URL { (link, first) = (value, subrange.location); stop.pointee = true }
        }
        guard let url = link, url.scheme == EPUBBook.internalLinkScheme, url.fragment != nil else { return }
        let range = NSRange(location: first, length: output.length - first)
        let reference: EPUBNoteReference
        if marked {
            reference = .marked
        } else {
            let text = output.mutableString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            var raised = false
            output.enumerateAttribute(.baselineOffset, in: range) { value, _, stop in
                if ((value as? NSNumber)?.doubleValue ?? 0) > 0 { raised = true; stop.pointee = true }
            }
            guard (raised && text.count <= 8) || Self.looksLikeNoteMarker(text) else { return }
            reference = .marker
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "note", value: reference.rawValue)]
        guard let tagged = components.url else { return }
        if let fragment = url.fragment,
           components.queryItems?.first(where: { $0.name == "path" })?.value == resourcePath {
            noteReferences[fragment, default: []].append(range.location)
        }
        output.enumerateAttribute(.link, in: range) { value, subrange, _ in
            if (value as? URL) == url { output.addAttribute(.link, value: tagged, range: subrange) }
        }
    }

    /// "1", "[12]", "(iv)", "*", "†": what a note marker looks like.
    static func looksLikeNoteMarker(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}.,"))
        guard !core.isEmpty, core.count <= 4 else { return false }
        if core.allSatisfy({ $0.isNumber || "*†‡§¶‖#".contains($0) }) { return true }
        return core.count <= 3 && core.allSatisfy { "ivx".contains($0) } || (core.count == 1 && core.first!.isLetter)
    }

    /// An id'd note block, or an inline id at the very start of one (the
    /// usual EPUB 2 footnote), points at that block's text. A mid-paragraph
    /// anchor (a page marker) points at no note.
    private func recordNoteTarget(_ element: OpenElement) {
        let range = NSRange(location: element.start, length: max(0, output.length - element.start))
        if Self.noteBlocks.contains(element.name) {
            if let id = element.id, range.length > 0 {
                noteTargets[id] = EPUBNoteTarget(range: range, isMarkedNote: element.isMarkedNote)
            }
            for inline in element.inlineIDs where range.length > 0 {
                noteTargets[inline.id] = EPUBNoteTarget(range: range,
                                                        isMarkedNote: inline.isMarkedNote || element.isMarkedNote)
            }
        } else if Self.blockElements.contains(element.name) {
            return
        } else if let id = element.id ?? element.inlineIDs.first?.id,
                  let index = openElements.lastIndex(where: { Self.blockElements.contains($0.name) }),
                  Self.noteBlocks.contains(openElements[index].name),
                  element.start - openElements[index].start <= 8 {
            openElements[index].inlineIDs.append((id, element.isMarkedNote))
        }
    }

    /// Takes the footnote blocks a note reference here points to out of the
    /// text, keeping each for its pop-up. Anchors inside one move to where
    /// it was; every later offset moves up by its length.
    private func detachReferencedNotes() {
        // A link from inside the note itself leaves it unreachable once hidden.
        let referenced = noteAsides.filter { note in
            NSMaxRange(note.range) <= output.length
                && (noteReferences[note.id] ?? []).contains { !NSLocationInRange($0, note.range) }
        }
        // The outermost of nested notes; a note in a table cell stays, or the cell would lose its paragraph.
        let removable = referenced.filter { note in
            !referenced.contains { $0.range != note.range && NSIntersectionRange($0.range, note.range) == note.range }
                && ((output.attribute(.paragraphStyle, at: note.range.location, effectiveRange: nil)
                    as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
        }
        detachedNoteIDs = removable.sorted { $0.range.location < $1.range.location }.map(\.id)
        for note in removable.sorted(by: { $0.range.location > $1.range.location }) {
            let range = note.range
            detachedNotes[note.id] = output.attributedSubstring(from: range)
            for (id, target) in noteTargets {
                let start = target.range.location
                let end = NSMaxRange(target.range)
                if start >= range.location, end <= NSMaxRange(range) {
                    detachedNotes[id] = output.attributedSubstring(from: target.range)
                    noteTargets[id] = nil
                } else {
                    let overlap = NSIntersectionRange(target.range, range).length
                    let location = start >= NSMaxRange(range) ? start - range.length : start
                    noteTargets[id] = EPUBNoteTarget(range: NSRange(location: location, length: target.range.length - overlap),
                                                     isMarkedNote: target.isMarkedNote)
                }
            }
            let noteText = detachedNotes[note.id]
            for (anchor, location) in anchors where location >= range.location {
                // A place inside the note goes with it, so what reaches for it
                // (a link, a recording's clip) finds the note, not the next text.
                if location < NSMaxRange(range), detachedNotes[anchor] == nil { detachedNotes[anchor] = noteText }
                anchors[anchor] = location >= NSMaxRange(range) ? location - range.length : range.location
            }
            output.deleteCharacters(in: range)
        }
    }

    /// A drawing that only wraps one raster (the usual cover) shows that
    /// raster; anything else is drawn from its own markup.
    private func finishSVG(_ capture: SVGCapture) {
        guard let slot = capture.slot else { return }
        if !capture.drawsVector, capture.rasters.count == 1 {
            pendingImages[slot].source = capture.rasters[0]
        } else if let document = capture.document {
            pendingImages[slot].source = "\(resourcePath)#svg-\(slot)"
            let directory = (resourcePath as NSString).deletingLastPathComponent
            pendingImages[slot].inline = capture.rasters.isEmpty || images == nil ? document
                : EPUBSVG.embeddingRasters(in: document, directory: directory) { [archive] in
                    try? archive.read($0, limit: EPUBSVG.byteLimit)
                }
        }
    }

    private func finishMath(_ capture: MathMLCapture) {
        guard let location = capture.location else { return }
        let sources = [MathMLConverter.latex(capture.root), capture.root.texAnnotation].compactMap { $0 }
        let alt = capture.root.attributes["alttext"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingMath.append((location, EPUBMathFormula(sources: sources, isDisplay: capture.isDisplay),
                            alt?.isEmpty == false ? alt! : capture.root.linearText))
    }

    private func makeAttachment(_ makeCell: @escaping @MainActor () -> NSTextAttachmentCell) -> NSTextAttachment {
        EPUBMainThreadRelay.sync {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = makeCell()
            return attachment
        }
    }

    /// Typesets the chapter's formulas in one batch; one that can't be
    /// typeset shows its alt text or linear text instead.
    private func installMath() {
        guard images != nil, !pendingMath.isEmpty else { return }
        let formulas = pendingMath.map(\.formula)
        let layouts = mathTypesetter?.typeset(formulas) ?? []
        for (index, math) in pendingMath.enumerated() {
            let attachment: NSTextAttachment
            if layouts.indices.contains(index), let layout = layouts[index] {
                attachment = makeAttachment { EPUBMathCell(layout: layout) }
            } else {
                addNotice(.mathMLFallback)
                let label = String(math.fallback.prefix(120))
                attachment = makeAttachment { EPUBAltTextCell(label: label) }
            }
            let range = NSRange(location: math.location, length: 1)
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(output.attributes(at: math.location, effectiveRange: nil)
                .filter { $0.key != .attachment }, range: NSRange(location: 0, length: 1))
            replacement.addAttribute(EPUBMath.textAttribute, value: math.fallback, range: NSRange(location: 0, length: 1))
            output.replaceCharacters(in: range, with: replacement)
        }
    }

    private func combinesUpright(_ attributes: [String: String]) -> Bool {
        if let inline = attributes["style"], ChapterWriting.combines(inline: inline) { return true }
        guard !writing.combinedClasses.isEmpty, let classes = attributes["class"]?.lowercased() else { return false }
        return classes.split(whereSeparator: \.isWhitespace).contains { writing.combinedClasses.contains(String($0)) }
    }

    /// Marks a finished element's short text to set upright. The value is its
    /// offset, so two neighbours stay two runs.
    private func markCombined(from start: Int) {
        let range = NSRange(location: start, length: output.length - start)
        guard range.length > 0, range.length <= EPUBWriting.combinedLimit,
              !output.mutableString.substring(with: range).contains(where: \.isNewline) else { return }
        output.addAttribute(EPUBWriting.combinedAttribute, value: start, range: range)
    }

    /// Hangs a finished `<rt>` on its base: the next `<rb>`, else the text
    /// since the last reading. A reading with no base left joins the one
    /// before it (several `<rt>` in one `<rtc>`), or is shown as text.
    private func attachReading(_ reading: String) {
        guard let ruby = rubies.last, !ruby.skipsReadings else { return }
        let text = reading.replacingOccurrences(of: "[ \t\n\r\u{0C}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // An empty reading still uses up its base.
            _ = ruby.nextBase(upTo: output.length)
            return
        }
        var base = ruby.nextBase(upTo: output.length)
        let string = output.mutableString
        func isBlank(_ index: Int) -> Bool {
            Unicode.Scalar(string.character(at: index))?.properties.isWhitespace == true
        }
        while base.length > 0, isBlank(base.location) { base = NSRange(location: base.location + 1, length: base.length - 1) }
        while base.length > 0, isBlank(NSMaxRange(base) - 1) { base.length -= 1 }
        if base.length > 0 {
            output.addAttribute(EPUBRuby.attribute, value: EPUBRubyText(text), range: base)
            ruby.annotated = (base, text)
        } else if let last = ruby.annotated {
            let joined = last.reading + text
            output.addAttribute(EPUBRuby.attribute, value: EPUBRubyText(joined), range: last.base)
            ruby.annotated = (last.base, joined)
        } else if styles.count >= 2 {
            append(text, style: styles[styles.count - 2])
            ruby.baseStart = output.length
        }
    }

    func addNotice(_ notice: EPUBContentNotice) {
        if !notices.contains(notice) { notices.append(notice) }
    }

    private func resolvedLink(_ href: String) -> URL? {
        if let external = URL(string: href), let scheme = external.scheme?.lowercased() {
            // Never hand a book-authored file:, app or share URL to the system.
            return ["http", "https", "mailto"].contains(scheme) ? external : nil
        }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path: String
        if parts.first?.isEmpty == true {
            path = resourcePath
        } else {
            let directory = (resourcePath as NSString).deletingLastPathComponent
            guard let resolved = ArchivePath.normalized(String(parts[0]), relativeTo: directory) else {
                return nil
            }
            path = resolved
        }
        var components = URLComponents()
        components.scheme = EPUBBook.internalLinkScheme
        components.host = "local"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if parts.count == 2 { components.fragment = String(parts[1]) }
        return components.url
    }

    private func installImages() {
        guard let images else { return }
        let directory = (resourcePath as NSString).deletingLastPathComponent
        var sizes: [String: NSSize] = [:]
        for imageRecord in pendingImages {
            let range = NSRange(location: imageRecord.location, length: 1)
            let attachment: NSTextAttachment
            var resolved: (path: String, pixels: NSSize)?
            if let inline = imageRecord.inline {
                if let size = Self.acceptedSVGSize(inline) {
                    images.registerInline(inline, key: imageRecord.source)
                    estimatedMemoryCost += inline.count
                    resolved = (imageRecord.source, size)
                }
            } else if let path = ArchivePath.normalized(imageRecord.source.removingFragment, relativeTo: directory),
                      let pixels = sizes[path] ?? imagePixelSize(at: path) {
                sizes[path] = pixels
                resolved = (path, pixels)
            }
            if let (path, pixels) = resolved {
                installedImages[imageRecord.location] = (path, pixels)
                // Only the header is read now; pixels decode when the image
                // is first drawn, through the book's bounded cache.
                let font = output.attribute(.font, at: imageRecord.location, effectiveRange: nil) as? NSFont
                let sizing = EPUBImageSizing(
                    pixels: pixels, declared: imageRecord.declared, fontSize: font?.pointSize ?? Style().font.pointSize,
                    lineHeight: font.map { $0.ascender - $0.descender } ?? Style().font.pointSize * 1.2,
                    bounds: imageBounds, isInText: paragraphHoldsText(at: imageRecord.location))
                let bounds = imageBounds
                attachment = makeAttachment {
                    EPUBImageCell(store: images, path: path, size: sizing.size,
                                  textSizing: sizing.textSizing, pageBounds: bounds)
                }
            } else {
                let label = String((imageRecord.alt.map { "[\($0)]" } ?? "[Image unavailable]").prefix(120))
                attachment = makeAttachment { EPUBAltTextCell(label: label) }
            }
            let attributes = output.attributes(at: range.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(
                attributes.filter { $0.key != .attachment },
                range: NSRange(location: 0, length: replacement.length)
            )
            output.replaceCharacters(in: range, with: replacement)
        }
    }

    /// The size the book gives the image element just opened: its attributes,
    /// then the rules that match it, then its own style. A chapter's images are
    /// mostly alike, so each likeness asks the rules once.
    private func declaredImageSize() -> EPUBImageSizing.Declared {
        var nodes: [XMLNode] = []
        for element in openElements {
            let node = XMLNode(name: element.name, attributes: element.attributes)
            node.parent = nodes.last
            nodes.append(node)
        }
        guard let image = nodes.last else { return .init() }
        var likeness = ""
        for node in nodes {
            // Rules look at names, classes and (few sheets) ids all the way up.
            for part in [node.localName, imageRulesUseIDs ? node.attributes["id"] : nil, node.attributes["class"]] {
                likeness += part ?? ""
                likeness += "\u{1}"
            }
        }
        for part in [image.attributes["style"], image.attributes["width"], image.attributes["height"],
                     image.attributes["align"], image.parent?.attributes["style"]] {
            likeness += part ?? ""
            likeness += "\u{1}"
        }
        if let known = declaredImageSizes[likeness] { return known }
        let values = imageCSS.computed(for: image, directory: "")
        func floats(_ values: [String: String]) -> Bool { values["float"].map { !$0.lowercased().hasPrefix("none") } ?? false }
        // A floated drop cap often has its float on a span around the image.
        let wrapperFloats = image.parent.map { $0.localName.lowercased() == "span" && floats(imageCSS.computed(for: $0, directory: "")) } ?? false
        let align = image.attributes["align"]?.lowercased()
        let declared = EPUBImageSizing.Declared(width: values["width"] ?? image.attributes["width"],
                                                height: values["height"] ?? image.attributes["height"],
                                                floats: floats(values) || wrapperFloats || align == "left" || align == "right")
        declaredImageSizes[likeness] = declared
        return declared
    }

    /// Whether anything but images and white space shares the image's paragraph.
    private func paragraphHoldsText(at location: Int) -> Bool {
        let text = output.mutableString
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        return text.rangeOfCharacter(from: Self.textCharacters, range: paragraph).location != NSNotFound
    }

    private static let textCharacters: CharacterSet = {
        var images = CharacterSet.whitespacesAndNewlines
        images.insert("\u{FFFC}")
        return images.inverted
    }()

    /// The displayed pixel size of an acceptable image, read from its header.
    /// Reads only the image header when that is enough (most are), else the
    /// whole image.
    private func imagePixelSize(at path: String) -> NSSize? { Self.imagePixelSize(at: path, in: archive) }

    static func imagePixelSize(at path: String, in archive: ArchiveReader) -> NSSize? {
        if let prefix = try? archive.readPrefix(path, length: 256 * 1024, limit: 32 * 1024 * 1024),
           let size = Self.acceptedPixelSize(prefix) {
            return size
        }
        return (try? archive.read(path, limit: 32 * 1024 * 1024)).flatMap(Self.acceptedPixelSize)
    }

    static func acceptedPixelSize(_ data: Data) -> NSSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return acceptedSVGSize(data) }
        let pixels = width.uint64Value.multipliedReportingOverflow(by: height.uint64Value)
        guard !pixels.overflow, pixels.partialValue > 0, pixels.partialValue <= 40_000_000 else { return nil }
        // EXIF orientations 5–8 swap the displayed axes.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = NSSize(width: width.doubleValue, height: height.doubleValue)
        return (5...8).contains(orientation) ? NSSize(width: size.height, height: size.width) : size
    }

    /// An SVG's size in points, within the same 40 MP ceiling as rasters.
    private static func acceptedSVGSize(_ data: Data) -> NSSize? {
        guard let size = EPUBSVG.size(of: data), size.width * size.height <= 40_000_000 else { return nil }
        return size
    }

    private func converted(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }
}

/// How large an image in a flowing chapter is drawn. A size the book gives
/// is kept: ems follow the text, and so does a small size in running text,
/// which reads as text there; other lengths are points, one to a CSS pixel as
/// an image's pixels are. With none given, an image in a line of text with a
/// letter's shape and size stands in for a letter and takes the line's height.
/// Everything else draws at its pixels, fitted to the page.
struct EPUBImageSizing {
    struct Declared {
        var width: String?
        var height: String?
        /// Floated: beside the text, not in its line.
        var floats = false
    }

    /// Up to this many pixels tall an image in text can be a letter; taller
    /// it's a picture or a drop cap, however it's placed.
    private static let letterPixelHeight: CGFloat = 50
    /// Wider than this for its height it isn't a letter: an inline equation, a
    /// logo, a slashed fraction. They keep their pixels, so stay readable.
    private static let letterWidestShape: CGFloat = 1.25
    /// Narrower than this for its height (3:5) it can be a stacked fraction,
    /// which only stays readable at line height when it's this short at most.
    private static let letterNarrowShape: CGFloat = 0.6
    private static let narrowLetterPixelHeight: CGFloat = 32
    /// Smaller than this it's a spacer or a tracking pixel, not a letter.
    private static let spacerPixelSize: CGFloat = 4
    /// A declared height up to this in running text reads as text.
    private static let textPixelHeight: CGFloat = 48
    private static let cssPixelsPerEm: CGFloat = 16

    let size: NSSize
    let textSizing: EPUBImageCell.TextSizing?

    init(pixels: NSSize, declared: Declared, fontSize: CGFloat, lineHeight: CGFloat, bounds: CGSize, isInText: Bool) {
        let shape = pixels.height > 0 ? pixels.width / pixels.height : 1
        let width = Self.Length(declared.width, isWidth: true)
        let height = Self.Length(declared.height, isWidth: false)
        func points(_ length: Length) -> CGFloat {
            switch length {
            case .ems(let ems): return ems * fontSize
            case .points(let points): return points
            case .pageShare(let share): return share * bounds.width
            }
        }
        if width != nil || height != nil, pixels.width > 0, pixels.height > 0 {
            let box = NSSize(width: width.map(points) ?? height.map(points)! * shape,
                             height: height.map(points) ?? width.map(points)! / shape)
            // The height in ems, when the image goes by the text.
            let ems: CGFloat?
            if case .ems(let value)? = height {
                ems = value
            } else if case .ems? = width {
                ems = box.height / fontSize
            } else if isInText, box.height <= Self.textPixelHeight {
                ems = box.height / Self.cssPixelsPerEm
            } else {
                ems = nil
            }
            if let ems {
                let tall = ems * fontSize
                let wide = tall * box.width / box.height
                let fit = min(1, bounds.width / wide, bounds.height / tall)
                size = NSSize(width: wide * fit, height: tall * fit)
                textSizing = .ems(ems)
            } else {
                let fit = min(1, bounds.width / box.width, bounds.height / box.height)
                size = NSSize(width: box.width * fit, height: box.height * fit)
                textSizing = nil
            }
            return
        }
        if isInText, !declared.floats, Self.hasALettersShape(pixels) {
            size = NSSize(width: lineHeight * shape, height: lineHeight)
            textSizing = .line
            return
        }
        let fit = min(1, bounds.width / pixels.width, bounds.height / pixels.height)
        size = NSSize(width: pixels.width * fit, height: pixels.height * fit)
        textSizing = nil
    }

    private static func hasALettersShape(_ pixels: NSSize) -> Bool {
        guard min(pixels.width, pixels.height) >= spacerPixelSize, pixels.height <= letterPixelHeight else { return false }
        let shape = pixels.width / pixels.height
        return shape <= letterWidestShape && (shape >= letterNarrowShape || pixels.height <= narrowLetterPixelHeight)
    }

    private enum Length {
        case ems(CGFloat)
        case points(CGFloat)
        /// Of the page's text width.
        case pageShare(CGFloat)

        /// Nil for no size, `auto`, or nothing usable.
        init?(_ value: String?, isWidth: Bool) {
            guard let text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            func number(_ suffix: String) -> CGFloat? {
                guard text.hasSuffix(suffix), let number = Double(text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)),
                      number > 0 else { return nil }
                return CGFloat(number)
            }
            if let ems = number("rem") ?? number("em") {
                self = .ems(ems)
            } else if let exes = number("ex") {
                self = .ems(exes / 2)
            } else if text.hasSuffix("%") {
                // A height's percentage has no definite box to take it from.
                guard isWidth, let share = number("%") else { return nil }
                self = .pageShare(share / 100)
            } else if let points = EPUBFixedCSS.length(text, basis: 0), points > 0 {
                self = .points(points)
            } else {
                return nil
            }
        }
    }
}

/// One open `<ruby>`: which text its next reading goes on.
private final class RubyBuilder {
    var baseStart: Int
    var openBase: Int?
    /// `<rb>` bases waiting for their `<rt>`.
    var bases: [NSRange] = []
    var annotated: (base: NSRange, reading: String)?
    /// Inside a second `<rtc>`: its readings aren't drawn.
    var skipsReadings = false

    init(baseStart: Int) {
        self.baseStart = baseStart
    }

    func closeBase(at end: Int) {
        if let start = openBase { bases.append(NSRange(location: start, length: end - start)) }
        openBase = nil
    }

    func nextBase(upTo end: Int) -> NSRange {
        if !bases.isEmpty {
            baseStart = end
            return bases.removeFirst()
        }
        defer { baseStart = end }
        return NSRange(location: baseStart, length: end - baseStart)
    }
}

/// The markup of one inline `<svg>`, re-serialized as its own document.
private final class SVGCapture {
    let slot: Int?
    private(set) var rasters: [String] = []
    private(set) var drawsVector = false
    private var xml = ""
    private var depth = 0
    private var tooLarge = false
    private static let byteLimit = 2 * 1024 * 1024
    private static let graphics: Set<String> = [
        "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "use", "foreignObject"
    ]

    init(root: String, attributes: [String: String], slot: Int?) {
        self.slot = slot
        var attributes = attributes
        // The namespaces are often declared on <html>, out of this document.
        let prefix = root.contains(":") ? root.split(separator: ":")[0] : nil
        let svgNamespace = "http://www.w3.org/2000/svg"
        if let prefix {
            attributes["xmlns:\(prefix)"] = attributes["xmlns:\(prefix)"] ?? svgNamespace
        } else {
            attributes["xmlns"] = attributes["xmlns"] ?? svgNamespace
        }
        attributes["xmlns:xlink"] = attributes["xmlns:xlink"] ?? "http://www.w3.org/1999/xlink"
        open(root, attributes: attributes)
    }

    /// The document, or nil when it grew past the size limit.
    var document: Data? { tooLarge ? nil : Data(xml.utf8) }

    func open(_ name: String, attributes: [String: String]) {
        depth += 1
        let local = XMLNode.local(name)
        if local == "image", let href = attributes["xlink:href"] ?? attributes["href"] {
            rasters.append(href)
        } else if Self.graphics.contains(local) {
            drawsVector = true
        }
        let list = attributes.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(Self.escaped($0.value, quotes: true))\"" }.joined()
        write("<\(name)\(list)>")
    }

    func text(_ string: String) { write(Self.escaped(string, quotes: false)) }

    /// Returns true when this closes the root.
    func close(_ name: String) -> Bool {
        write("</\(name)>")
        depth -= 1
        return depth == 0
    }

    private func write(_ string: String) {
        guard !tooLarge else { return }
        xml += string
        if xml.utf8.count > Self.byteLimit { tooLarge = true }
    }

    private static func escaped(_ string: String, quotes: Bool) -> String {
        var result = string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if quotes { result = result.replacingOccurrences(of: "\"", with: "&quot;") }
        return result
    }
}
