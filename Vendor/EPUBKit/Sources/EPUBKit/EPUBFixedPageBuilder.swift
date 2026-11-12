import AppKit
import Foundation

/// Reads one chapter's markup as a fixed page: its images, painted colours and
/// positioned text blocks. A page it can't place faithfully (text in the
/// normal flow, an element scaled or rotated, vertical writing) gets no fixed
/// page, and the chapter reflows with a notice.
final class EPUBFixedPageBuilder {
    /// More positioned blocks than this are one line each, or worse: a page
    /// built that way is too costly to lay out and reads better reflowed.
    private static let blockLimit = 800
    /// HTML's default font size.
    private static let defaultFontSize: CGFloat = 16
    private static let headings: [String: CGFloat] = ["h1": 2, "h2": 1.5, "h3": 1.17, "h4": 1, "h5": 0.83, "h6": 0.67]

    private let document: XMLDocumentParser
    private let chapter: EPUBChapter
    private let archive: ArchiveReader
    private let packageViewport: CGSize?
    private let directory: String
    private var css = EPUBFixedCSS()

    private var rangeOfNode: [ObjectIdentifier: NSRange] = [:]
    private var slotImages: [Int: (path: String, pixels: NSSize)] = [:]
    private var textLength = 0
    private var pageSize = CGSize.zero
    private var layers: [(z: Int, layer: EPUBFixedPage.Layer)] = []
    private var blocks: [EPUBFixedPage.TextBlock] = []
    private var string: NSString = ""
    private var failed = false
    private var hidden: [NSRange] = []

    /// What gives a run of text and in-flow images a place: the page, or a
    /// positioned element.
    private final class Owner {
        let range: NSRange
        /// Nil for the page itself, whose in-flow text has no set place.
        let frame: CGRect?
        var excluded: [NSRange] = []
        var flowImages: [(node: XMLNode, box: CGRect, css: [String: String])] = []
        /// A relative element's place is known only if it comes first in flow.
        var hasRelativeChild = false

        init(range: NSRange, frame: CGRect?) {
            self.range = range
            self.frame = frame
        }
    }

    init?(bytes: Data, chapter: EPUBChapter, archive: ArchiveReader, packageViewport: CGSize?) {
        guard let document = try? XMLDocumentParser.parse(bytes) else { return nil }
        self.document = document
        self.chapter = chapter
        self.archive = archive
        self.packageViewport = packageViewport
        directory = (chapter.path as NSString).deletingLastPathComponent
        readStylesheets()
    }

    private func readStylesheets() {
        for node in document.elements(named: "link") {
            guard node.attributes["rel"]?.lowercased().contains("stylesheet") == true, let href = node.attributes["href"],
                  URL(string: href)?.scheme == nil,
                  let path = ArchivePath.normalized(href.removingFragment, relativeTo: directory),
                  let data = try? archive.read(path, limit: 2 * 1024 * 1024) else { continue }
            css.add(String(decoding: data, as: UTF8.self), directory: (path as NSString).deletingLastPathComponent)
        }
        for node in document.elements(named: "style") {
            css.add(node.text, directory: directory)
        }
    }

    /// This page's size: an SVG spine item's own, else what its markup says,
    /// else the first background image's.
    private func resolvedPageSize() -> CGSize? {
        if chapter.isImage {
            return (try? archive.read(chapter.path, limit: EPUBSVG.byteLimit)).flatMap { EPUBFixedPageSize.svg($0) }
        }
        if let size = EPUBFixedPageSize.of(document: document, path: chapter.path, archive: archive,
                                           packageViewport: packageViewport) { return size }
        guard let root = document.root else { return nil }
        for node in [root] + root.descendants(named: "body") + root.descendants(named: "div") {
            let values = css.computed(for: node, directory: directory)
            if let path = EPUBFixedCSS.path(in: values["background-image"] ?? values["background"]),
               let size = XHTMLRenderer.imagePixelSize(at: path, in: archive) { return size }
        }
        return nil
    }

    /// The page, or nil when the chapter should reflow. `elements` holds each
    /// element's range in `rendered`, in document order; `images` each placed
    /// image by its character.
    func page(rendered: NSAttributedString, elements: [NSRange],
              images: [Int: (path: String, pixels: NSSize)], store: EPUBImageStore) -> EPUBFixedPage? {
        guard let root = document.root, let size = resolvedPageSize(), size.width >= 1, size.height >= 1 else { return nil }
        pageSize = size
        slotImages = images
        textLength = rendered.length
        string = rendered.string as NSString
        var order = 0
        func index(_ node: XMLNode) {
            if elements.indices.contains(order) { rangeOfNode[ObjectIdentifier(node)] = elements[order] }
            order += 1
            node.children.forEach(index)
        }
        index(root)
        guard order == elements.count else { return nil }

        let pageBox = CGRect(origin: .zero, size: size)
        let owner = Owner(range: NSRange(location: 0, length: rendered.length), frame: nil)
        visit(root, containing: pageBox, flow: pageBox, owner: owner)
        finish(owner)
        guard !failed, blocks.count <= Self.blockLimit else { return nil }
        // Blocks read in text order; layers stack by z-index, then in order.
        let stacked = layers.enumerated().sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element.layer)
        return EPUBFixedPage(size: size, background: pageBackground(of: root), layers: stacked,
                             blocks: blocks.sorted { $0.range.location < $1.range.location },
                             text: styled(rendered, root: root), images: store, hidden: hidden)
    }

    private func range(of node: XMLNode) -> NSRange {
        guard let range = rangeOfNode[ObjectIdentifier(node)], range.location <= textLength else {
            return NSRange(location: textLength, length: 0)
        }
        return NSRange(location: range.location, length: min(range.length, textLength - range.location))
    }

    // MARK: - Placement

    private func visit(_ node: XMLNode, containing: CGRect, flow: CGRect, owner: Owner) {
        guard !failed else { return }
        let name = node.localName.lowercased()
        guard !["head", "script", "style", "link", "meta", "title"].contains(name) else { return }
        let values = css.computed(for: node, directory: directory)
        if values["display"] == "none" || values["visibility"] == "hidden" {
            // Text the page never shows; it stays in the chapter's offsets.
            owner.excluded.append(range(of: node))
            hidden.append(range(of: node))
            return
        }
        // Text set vertically can't be placed; an image under a vertical root can.
        let isVertical = ["writing-mode", "-webkit-writing-mode", "-epub-writing-mode"]
            .contains { values[$0]?.contains("vertical") == true }
        if isVertical, hasText(node) {
            failed = true
            return
        }
        // A percentage moves by the element's own size: without one, nowhere to put it.
        let transform = values["transform"] ?? values["-webkit-transform"]
        if transform?.contains("%") == true, values["width"] == nil || values["height"] == nil {
            failed = true
            return
        }
        let ownSize = CGSize(width: EPUBFixedCSS.length(values["width"], basis: flow.width, page: pageSize) ?? flow.width,
                             height: EPUBFixedCSS.length(values["height"], basis: flow.height, page: pageSize) ?? flow.height)
        guard let moved = EPUBFixedCSS.translation(transform, box: ownSize) else {
            failed = true
            return
        }
        let position = values["position"]?.lowercased() ?? "static"
        let transformed = moved != .zero
        let isImage = name == "img" || name == "image" || name == "svg"
        if position == "relative" {
            if owner.hasRelativeChild {
                failed = true
                return
            }
            owner.hasRelativeChild = true
        }

        if isImage {
            owner.excluded.append(range(of: node))
            if position == "absolute" || position == "fixed" || position == "relative" {
                place(node, values: values, box: position == "relative" ? flow : containing, position: position, moved: moved)
            } else {
                owner.flowImages.append((node, flow.offsetBy(dx: moved.x, dy: moved.y), values))
            }
            return
        }

        var box = flow.offsetBy(dx: moved.x, dy: moved.y)
        var childContaining = transformed ? box : containing
        var inner = owner
        let isNewOwner = position == "absolute" || position == "fixed" || position == "relative"
        if isNewOwner {
            let frame = position == "relative"
                ? relativeFrame(values, flow: box)
                : absoluteFrame(values, containing: containing, moved: moved)
            guard let frame else {
                failed = true
                return
            }
            box = frame
            childContaining = frame
            owner.excluded.append(range(of: node))
            inner = Owner(range: range(of: node), frame: textFrame(frame, values: values, hasWidth: values["width"] != nil))
        } else if let width = EPUBFixedCSS.length(values["width"], basis: box.width, page: pageSize) {
            box.size.width = width
            if let height = EPUBFixedCSS.length(values["height"], basis: box.height, page: pageSize) {
                box.size.height = height
            }
        } else if let height = EPUBFixedCSS.length(values["height"], basis: box.height, page: pageSize) {
            box.size.height = height
        }
        // The page's own background covers it; another element paints only
        // a box with a height, as a browser would.
        let isRoot = name == "html" || name == "body"
        if !isRoot, hasText(node), hasUnpaintableBackground(values, box: box) {
            failed = true
            return
        }
        if isRoot || values["height"] != nil || (isNewOwner && box.height > 0 && position != "relative") {
            paintBackground(of: values, in: box, z: zIndex(values), paintsColor: !isRoot)
        }
        for child in node.children {
            visit(child, containing: childContaining, flow: box, owner: inner)
        }
        if isNewOwner { finish(inner) }
    }

    private func zIndex(_ values: [String: String]) -> Int { values["z-index"].flatMap { Int($0) } ?? 0 }

    /// An absolutely positioned element's box, in page units.
    private func absoluteFrame(_ values: [String: String], containing: CGRect, moved: CGPoint) -> CGRect? {
        func length(_ name: String, _ basis: CGFloat) -> CGFloat? {
            EPUBFixedCSS.length(values[name], basis: basis, page: pageSize)
        }
        // A value given but not understood (calc()) can't be placed.
        for name in ["left", "top", "right", "bottom", "width", "height"] {
            if let value = values[name], value.lowercased() != "auto",
               length(name, name == "left" || name == "right" || name == "width" ? containing.width : containing.height) == nil {
                return nil
            }
        }
        let left = length("left", containing.width)
        let right = length("right", containing.width)
        let top = length("top", containing.height)
        let bottom = length("bottom", containing.height)
        var width = length("width", containing.width)
        var height = length("height", containing.height)
        if width == nil, let left, let right { width = containing.width - left - right }
        if height == nil, let top, let bottom { height = containing.height - top - bottom }
        var x = left ?? 0
        if left == nil, let right, let width { x = containing.width - right - width }
        var y = top ?? 0
        if top == nil, let bottom, let height { y = containing.height - bottom - height }
        x += EPUBFixedCSS.length(values["margin-left"], basis: containing.width, page: pageSize) ?? 0
        y += EPUBFixedCSS.length(values["margin-top"], basis: containing.width, page: pageSize) ?? 0
        return CGRect(x: containing.minX + x + moved.x, y: containing.minY + y + moved.y,
                      width: max(0, width ?? containing.maxX - (containing.minX + x)),
                      height: max(0, height ?? 0))
    }

    /// A relatively positioned element's box: where the flow puts it (taken as
    /// its container's start: a later in-flow sibling reflows the page),
    /// nudged by its offsets.
    private func relativeFrame(_ values: [String: String], flow: CGRect) -> CGRect? {
        let left = EPUBFixedCSS.length(values["left"], basis: flow.width, page: pageSize) ?? 0
        let top = EPUBFixedCSS.length(values["top"], basis: flow.height, page: pageSize) ?? 0
        let width = EPUBFixedCSS.length(values["width"], basis: flow.width, page: pageSize) ?? flow.width
        let height = EPUBFixedCSS.length(values["height"], basis: flow.height, page: pageSize) ?? flow.height
        return CGRect(x: flow.minX + left, y: flow.minY + top, width: width, height: height)
    }

    /// Where an element's text sets: inside its padding.
    private func textFrame(_ frame: CGRect, values: [String: String], hasWidth: Bool) -> CGRect {
        let basis = frame.width
        func inset(_ name: String) -> CGFloat { EPUBFixedCSS.length(values[name], basis: basis, page: pageSize) ?? 0 }
        let left = inset("padding-left")
        let top = inset("padding-top")
        var width = frame.width - left
        if hasWidth {
            width -= inset("padding-right")
        } else if values["white-space"] == "nowrap" || values["white-space"] == "pre" {
            // A line that never wraps, whatever the substituted font's width.
            width = .greatestFiniteMagnitude
        }
        return CGRect(x: frame.minX + left, y: frame.minY + top, width: max(1, width), height: frame.height)
    }

    /// Ends an owner: its in-flow images and one run of text take its place.
    private func finish(_ owner: Owner) {
        guard !failed else { return }
        let runs = textRuns(of: owner)
        if !owner.flowImages.isEmpty {
            // Text beside an in-flow image, or images in flow, need real flow.
            guard runs.isEmpty, owner.flowImages.count == 1, !owner.hasRelativeChild else {
                failed = true
                return
            }
            let image = owner.flowImages[0]
            placeFlowImage(image.node, values: image.css, box: image.box)
            return
        }
        guard !runs.isEmpty else { return }
        guard runs.count == 1, let frame = owner.frame else {
            failed = true
            return
        }
        blocks.append(EPUBFixedPage.TextBlock(range: runs[0], frame: frame))
    }

    /// The owner's own text: its range less anything placed apart, without
    /// whitespace at either end; runs of only whitespace are dropped.
    private func textRuns(of owner: Owner) -> [NSRange] {
        var runs: [NSRange] = []
        var cursor = owner.range.location
        func add(_ end: Int) {
            guard end > cursor, let run = Self.trimmed(NSRange(location: cursor, length: end - cursor), in: string) else { return }
            runs.append(run)
        }
        for hole in owner.excluded.sorted(by: { $0.location < $1.location }) where hole.length > 0 {
            add(hole.location)
            cursor = max(cursor, NSMaxRange(hole))
        }
        add(NSMaxRange(owner.range))
        return runs
    }

    private static func trimmed(_ range: NSRange, in string: NSString) -> NSRange? {
        func blank(_ index: Int) -> Bool {
            Unicode.Scalar(string.character(at: index))?.properties.isWhitespace == true
        }
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, blank(start) { start += 1 }
        while end > start, blank(end - 1) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - Images

    /// A placed image's source: the renderer installed it at its character.
    private func installed(_ node: XMLNode) -> (slot: Int, path: String, pixels: NSSize)? {
        let range = range(of: node)
        let slots = range.location..<max(range.location + 1, NSMaxRange(range))
        for slot in slots {
            if let image = slotImages[slot] { return (slot, image.path, image.pixels) }
        }
        return nil
    }

    private func explicitSize(of node: XMLNode, values: [String: String], box: CGSize, natural: CGSize) -> CGSize? {
        // CSS first; then the element's own width and height.
        func length(_ name: String, _ basis: CGFloat) -> CGFloat? {
            EPUBFixedCSS.length(values[name] ?? node.attributes[name], basis: basis, page: pageSize)
        }
        let width = length("width", box.width)
        let height = length("height", box.height)
        switch (width, height) {
        case let (width?, height?): return CGSize(width: width, height: height)
        case let (width?, nil): return CGSize(width: width, height: width * natural.height / natural.width)
        case let (nil, height?): return CGSize(width: height * natural.width / natural.height, height: height)
        default: return nil
        }
    }

    private func place(_ node: XMLNode, values: [String: String], box: CGRect, position: String, moved: CGPoint) {
        guard let image = installed(node) else {
            failed = true
            return
        }
        guard let origin = position == "relative"
            ? relativeFrame(values, flow: box)?.origin.applying(CGAffineTransform(translationX: moved.x, y: moved.y))
            : absoluteFrame(values, containing: box, moved: moved)?.origin else {
            failed = true
            return
        }
        let size = sized(node, image: image, values: values, box: box.size)
        addImage(node, image: image, frame: CGRect(origin: origin, size: size), z: zIndex(values))
    }

    /// An image with no position fills what it was given: its own size, its
    /// natural size, or scaled down to fit.
    private func placeFlowImage(_ node: XMLNode, values: [String: String], box: CGRect) {
        guard let image = installed(node) else {
            failed = true
            return
        }
        addImage(node, image: image, frame: CGRect(origin: box.origin, size: sized(node, image: image, values: values, box: box.size)),
                 z: zIndex(values))
    }

    private func sized(_ node: XMLNode, image: (slot: Int, path: String, pixels: NSSize), values: [String: String], box: CGSize) -> CGSize {
        // A drawing fills its box unless it says otherwise; an SVG spine item always does.
        if chapter.isImage { return box }
        if let explicit = explicitSize(of: node, values: values, box: box, natural: image.pixels) { return explicit }
        if node.localName.lowercased() == "svg" { return box }
        let shrink = min(1, box.width / image.pixels.width, box.height / image.pixels.height)
        return CGSize(width: image.pixels.width * shrink, height: image.pixels.height * shrink)
    }

    private func addImage(_ node: XMLNode, image: (slot: Int, path: String, pixels: NSSize), frame: CGRect, z: Int) {
        guard node.localName.lowercased() == "svg" else {
            layers.append((z, EPUBFixedPage.Layer(frame: frame, clip: nil, imagePath: image.path, color: nil, slot: image.slot)))
            return
        }
        // The drawing's coordinates map into its frame; one that only wraps a
        // raster shows that raster where its <image> says.
        let (mapped, clip) = rasterFrame(in: node, frame: frame)
        layers.append((z, EPUBFixedPage.Layer(frame: mapped, clip: clip, imagePath: image.path, color: nil, slot: image.slot)))
    }

    private func rasterFrame(in svg: XMLNode, frame: CGRect) -> (CGRect, CGRect?) {
        let aspect = svg.attributes["preserveAspectRatio"] ?? ""
        let box = (svg.attribute(named: "viewBox") ?? "").split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }.map { CGFloat($0) }
        guard box.count == 4, box[2] > 0, box[3] > 0 else { return (frame, nil) }
        var scaleX = frame.width / box[2]
        var scaleY = frame.height / box[3]
        if !aspect.hasPrefix("none") {
            let uniform = aspect.contains("slice") ? max(scaleX, scaleY) : min(scaleX, scaleY)
            scaleX = uniform
            scaleY = uniform
        }
        let originX = frame.minX + (frame.width - box[2] * scaleX) / 2 - box[0] * scaleX
        let originY = frame.minY + (frame.height - box[3] * scaleY) / 2 - box[1] * scaleY
        var content = CGRect(x: originX + box[0] * scaleX, y: originY + box[1] * scaleY,
                             width: box[2] * scaleX, height: box[3] * scaleY)
        // A drawing that only holds a raster is that raster; shapes need the whole box.
        let shapes = ["path", "rect", "circle", "ellipse", "line", "polygon", "polyline", "text", "use"]
        if !shapes.contains(where: { svg.firstDescendant(named: $0) != nil }), let raster = svg.firstDescendant(named: "image"),
           let width = Self.number(raster, "width"), let height = Self.number(raster, "height") {
            content = CGRect(x: originX + (Self.number(raster, "x") ?? 0) * scaleX,
                             y: originY + (Self.number(raster, "y") ?? 0) * scaleY,
                             width: width * scaleX, height: height * scaleY)
        }
        return (content, aspect.contains("slice") ? frame : nil)
    }

    private static func number(_ node: XMLNode, _ name: String) -> CGFloat? {
        guard let value = node.attributes[name], !value.hasSuffix("%") else { return nil }
        return Double(value.replacingOccurrences(of: "px", with: "")).map { CGFloat($0) }
    }

    // MARK: - Backgrounds

    private func paintBackground(of values: [String: String], in box: CGRect, z: Int, paintsColor: Bool) {
        // The colour goes first: an image over the same box paints on top of it.
        if paintsColor, let color = fillColor(values), box.height > 0 {
            layers.append((z, EPUBFixedPage.Layer(frame: box, clip: nil, imagePath: nil, color: color, slot: nil)))
        }
        let image = EPUBFixedCSS.path(in: values["background-image"]) ?? EPUBFixedCSS.path(in: values["background"])
        if let image {
            guard let pixels = XHTMLRenderer.imagePixelSize(at: image, in: archive) else {
                failed = true
                return
            }
            layers.append((z, EPUBFixedPage.Layer(frame: backgroundFrame(values, natural: pixels, box: box), clip: box,
                                                  imagePath: image, color: nil, slot: nil)))
        }
    }

    /// Whether the page shows words here: a stylesheet's or script's text isn't any.
    private func hasText(_ node: XMLNode) -> Bool {
        guard !["head", "style", "script", "title"].contains(node.localName.lowercased()) else { return false }
        return !node.ownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || node.children.contains(where: hasText)
    }

    /// A background this page can't paint, a colour it can't read or a box
    /// with no height to fill. Light text meant for it would vanish.
    private func hasUnpaintableBackground(_ values: [String: String], box: CGRect) -> Bool {
        if let color = fillColor(values) {
            return color.alphaComponent > 0 && box.height <= 0 && values["height"] == nil
        }
        guard let declared = (values["background-color"] ?? values["background"])?.lowercased() else { return false }
        return !declared.isEmpty && !declared.contains("url(")
            && !["none", "transparent", "inherit", "initial", "unset"].contains(declared)
    }

    private func fillColor(_ values: [String: String]) -> NSColor? {
        EPUBFixedCSS.color(values["background-color"]) ?? EPUBFixedCSS.color(values["background"])
    }

    private func backgroundFrame(_ values: [String: String], natural: CGSize, box: CGRect) -> CGRect {
        let sizing = values["background-size"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? "auto"
        var size = natural
        switch sizing {
        case "cover":
            let scale = max(box.width / natural.width, box.height / natural.height)
            size = CGSize(width: natural.width * scale, height: natural.height * scale)
        case "contain":
            let scale = min(box.width / natural.width, box.height / natural.height)
            size = CGSize(width: natural.width * scale, height: natural.height * scale)
        default:
            let parts = sizing.split(whereSeparator: \.isWhitespace).map(String.init)
            if let first = parts.first, let width = EPUBFixedCSS.length(first, basis: box.width, page: pageSize) {
                size.width = width
                size.height = parts.count > 1
                    ? EPUBFixedCSS.length(parts[1], basis: box.height, page: pageSize) ?? width * natural.height / natural.width
                    : width * natural.height / natural.width
            }
        }
        let centered = (values["background-position"] ?? values["background"] ?? "").contains("center")
        return CGRect(x: box.minX + (centered ? (box.width - size.width) / 2 : 0),
                      y: box.minY + (centered ? (box.height - size.height) / 2 : 0),
                      width: size.width, height: size.height)
    }

    private func pageBackground(of root: XMLNode) -> NSColor {
        for node in root.descendants(named: "body") + [root] {
            if let color = fillColor(css.computed(for: node, directory: directory)), color.alphaComponent > 0 {
                return color
            }
        }
        return .white
    }

    // MARK: - Text

    private struct TextStyle {
        var size = defaultFontSize
        var bold = false
        var italic = false
        var monospaced = false
        var families: [String] = []
        var color = NSColor.black
        var alignment: NSTextAlignment = .left
        /// A line height in units, or as a factor of the font size.
        var lineHeight: CGFloat?
        var lineFactor: CGFloat?
        var kern: CGFloat?
    }

    /// The chapter's text in the publisher's type. Same characters, so a
    /// fixed page shares every offset with the chapter.
    private func styled(_ rendered: NSAttributedString, root: XMLNode) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: rendered)
        let full = NSRange(location: 0, length: text.length)
        // Flowing text's spacing and justification don't belong on a set page.
        text.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.alignment = .left
            style.hyphenationFactor = 0
            style.lineSpacing = 0
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        apply(root, inherited: TextStyle(), to: text)
        return text
    }

    private func apply(_ node: XMLNode, inherited: TextStyle, to text: NSMutableAttributedString) {
        let name = node.localName.lowercased()
        let values = css.computed(for: node, directory: directory)
        var style = inherited
        if let factor = Self.headings[name] {
            style.size *= factor
            style.bold = true
        }
        switch name {
        case "b", "strong", "th": style.bold = true
        case "i", "em", "cite": style.italic = true
        case "sup", "sub", "small": style.size *= name == "small" ? 0.83 : 0.7
        case "code", "pre", "kbd", "samp": style.monospaced = true
        default: break
        }
        if let size = values["font-size"] {
            switch size.lowercased() {
            case "smaller": style.size *= 0.83
            case "larger": style.size *= 1.2
            default:
                if let length = EPUBFixedCSS.length(size, basis: inherited.size, font: inherited.size, page: pageSize) {
                    style.size = length
                }
            }
        }
        if let weight = values["font-weight"]?.lowercased() {
            style.bold = weight.hasPrefix("bold") || (Int(weight) ?? 400) >= 600
        }
        if let slant = values["font-style"]?.lowercased() {
            style.italic = slant.hasPrefix("italic") || slant.hasPrefix("oblique")
        }
        if let families = values["font-family"] {
            style.families = families.split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n\t"))
            }
        }
        if let color = EPUBFixedCSS.color(values["color"]) { style.color = color }
        switch values["text-align"]?.lowercased() {
        case "center": style.alignment = .center
        case "right", "end": style.alignment = .right
        case "justify": style.alignment = .justified
        case "left", "start": style.alignment = .left
        default: break
        }
        if let height = values["line-height"]?.lowercased().trimmingCharacters(in: .whitespaces) {
            if height == "normal" {
                style.lineHeight = nil
                style.lineFactor = nil
            } else if let factor = Double(height) {
                style.lineFactor = CGFloat(factor)
                style.lineHeight = nil
            } else if let length = EPUBFixedCSS.length(height, basis: style.size, font: style.size, page: pageSize) {
                style.lineHeight = length
                style.lineFactor = nil
            }
        }
        if let spacing = EPUBFixedCSS.length(values["letter-spacing"], basis: style.size, font: style.size, page: pageSize) {
            style.kern = spacing
        }
        let range = range(of: node)
        if range.length > 0 {
            text.addAttributes([
                .font: Self.font(style),
                .foregroundColor: style.color
            ], range: range)
            if let kern = style.kern { text.addAttribute(.kern, value: kern, range: range) }
            if name == "sup" || name == "sub" {
                text.addAttribute(.baselineOffset, value: inherited.size * (name == "sup" ? 0.35 : -0.15), range: range)
            }
            if values["text-decoration"]?.contains("underline") == true {
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            let setsLines = values["font-size"] != nil && style.lineFactor != nil
            if setsLines || values["text-align"] != nil || values["line-height"] != nil || values["text-indent"] != nil
                || values["margin-bottom"] != nil || values["margin-top"] != nil || Self.headings[name] != nil {
                setParagraphs(in: range, style: style, values: values, to: text)
            }
        }
        for child in node.children {
            apply(child, inherited: style, to: text)
        }
    }

    private func setParagraphs(in range: NSRange, style: TextStyle, values: [String: String], to text: NSMutableAttributedString) {
        let height = style.lineHeight ?? style.lineFactor.map { $0 * style.size }
        let basis = style.size
        func length(_ name: String) -> CGFloat? {
            EPUBFixedCSS.length(values[name], basis: basis, font: basis, page: pageSize)
        }
        text.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            guard let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            paragraph.alignment = style.alignment
            if let height {
                paragraph.minimumLineHeight = height
                paragraph.maximumLineHeight = height
            }
            if let indent = length("text-indent") { paragraph.firstLineHeadIndent = paragraph.headIndent + indent }
            if let after = length("margin-bottom") { paragraph.paragraphSpacing = after }
            if let before = length("margin-top") { paragraph.paragraphSpacingBefore = before }
            text.addAttribute(.paragraphStyle, value: paragraph, range: run)
        }
    }

    private static let genericFamilies: [String: String] = [
        "serif": "Times New Roman", "sans-serif": "Helvetica Neue", "monospace": "Menlo", "cursive": "Snell Roundhand",
        "fantasy": "Papyrus", "system-ui": ".AppleSystemUIFont"
    ]

    /// Families the Mac has, by name; a book's embedded fonts aren't loaded,
    /// so one of them falls through to the next name or the default serif.
    private static func font(_ style: TextStyle) -> NSFont {
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        for family in style.families {
            let name = genericFamilies[family.lowercased()] ?? family
            if let font = manager.font(withFamily: name, traits: traits, weight: style.bold ? 9 : 5, size: style.size) { return font }
            if let font = NSFont(name: name, size: style.size) { return converted(font, traits: traits) }
        }
        if style.monospaced { return converted(.monospacedSystemFont(ofSize: style.size, weight: .regular), traits: traits) }
        return manager.font(withFamily: "Times New Roman", traits: traits, weight: style.bold ? 9 : 5, size: style.size)
            ?? converted(.systemFont(ofSize: style.size), traits: traits)
    }

    private static func converted(_ font: NSFont, traits: NSFontTraitMask) -> NSFont {
        var result = font
        if traits.contains(.boldFontMask) { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        if traits.contains(.italicFontMask) { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
    }
}
