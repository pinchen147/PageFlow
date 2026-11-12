import AppKit
import Foundation

/// The little CSS a fixed page needs to be placed: tag, class and id rules
/// with descendant selectors, inline styles and common units. Anything richer
/// (pseudo-classes, attribute selectors, sibling combinators, @media) is left
/// out; a page that depends on it reflows rather than being misplaced.
struct EPUBFixedCSS {
    private struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []

        func matches(_ node: XMLNode) -> Bool {
            if let tag, tag != node.localName.lowercased() { return false }
            if let id, id != node.attributes["id"] { return false }
            guard !classes.isEmpty else { return true }
            let own = (node.attributes["class"] ?? "").split(whereSeparator: \.isWhitespace)
            return classes.allSatisfy { own.contains(Substring($0)) }
        }
    }

    private struct Rule {
        let chain: [Compound]
        let specificity: Int
        let declarations: [String: String]

        func matches(_ node: XMLNode) -> Bool {
            guard let last = chain.last, last.matches(node) else { return false }
            var remaining = chain.dropLast()
            var ancestor = node.parent
            while let wanted = remaining.last {
                guard let current = ancestor else { return false }
                if wanted.matches(current) { remaining.removeLast() }
                ancestor = current.parent
            }
            return true
        }
    }

    /// In the order they apply: lowest specificity first, then source order.
    private var rules: [Rule] = []

    /// Whether any rule tells elements apart by id.
    var usesIDs: Bool { rules.contains { $0.chain.contains { $0.id != nil } } }

    /// Reads a stylesheet; `url()`s become paths from the archive's root.
    mutating func add(_ css: String, directory: String) {
        let source = Self.withoutComments(css)
        var cursor = source.startIndex
        while let open = source[cursor...].firstIndex(of: "{") {
            let selectors = source[cursor..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // An at-rule's block is skipped whole, nested rules and all;
            // `@import` and `@charset` end at a semicolon ahead of the next rule.
            if selectors.contains("@") {
                var depth = 1
                var index = source.index(after: open)
                while index < source.endIndex, depth > 0 {
                    if source[index] == "{" { depth += 1 }
                    if source[index] == "}" { depth -= 1 }
                    index = source.index(after: index)
                }
                cursor = index
                continue
            }
            guard let close = source[open...].firstIndex(of: "}") else { break }
            let declarations = Self.declarations(String(source[source.index(after: open)..<close]), directory: directory)
            for selector in selectors.split(separator: ",") {
                guard let rule = Self.rule(selector, declarations: declarations) else { continue }
                rules.append(rule)
            }
            cursor = source.index(after: close)
        }
        sortRules()
    }

    /// Adds another sheet's rules after these, as if it were read here.
    mutating func append(_ other: EPUBFixedCSS) {
        guard !other.rules.isEmpty else { return }
        guard !rules.isEmpty else {
            rules = other.rules
            return
        }
        rules += other.rules
        sortRules()
    }

    /// A stable sort, so a later rule of equal weight wins.
    private mutating func sortRules() {
        rules = rules.enumerated().sorted {
            ($0.element.specificity, $0.offset) < ($1.element.specificity, $1.offset)
        }.map(\.element)
    }

    private static func withoutComments(_ css: String) -> String {
        css.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"@(charset|import|namespace)[^;]*;"#, with: " ", options: .regularExpression)
    }

    private static func rule(_ selector: Substring, declarations: [String: String]) -> Rule? {
        // Past a tag, class and id there is nothing here to match with.
        guard !selector.contains(where: { ":[+~".contains($0) }) else { return nil }
        let parts = selector.replacingOccurrences(of: ">", with: " ").split(whereSeparator: \.isWhitespace)
        var specificity = 0
        var chain: [Compound] = []
        for part in parts {
            var compound = Compound()
            var name = ""
            var kind: Character = " "
            func finish() {
                guard !name.isEmpty else { return }
                switch kind {
                case ".": compound.classes.append(name); specificity += 10
                case "#": compound.id = name; specificity += 100
                default:
                    if name != "*" { compound.tag = name.lowercased(); specificity += 1 }
                }
            }
            for character in part {
                if character == "." || character == "#" {
                    finish()
                    name = ""
                    kind = character
                } else {
                    name.append(character)
                }
            }
            finish()
            chain.append(compound)
        }
        return chain.isEmpty ? nil : Rule(chain: chain, specificity: specificity, declarations: declarations)
    }

    /// A style attribute or rule body, property names lowercased, shorthand
    /// boxes expanded, `url()`s resolved against `directory`.
    static func declarations(_ body: String, directory: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in body.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            if value.contains("url(") {
                // A data URI's own ";" cut it short here; it can't be placed.
                value = value[value.range(of: "url(")!.upperBound...].contains(")")
                    ? resolvingURLs(in: value, directory: directory) : "url(\(unresolvedImage))"
            }
            result[name] = value
            if name == "margin" || name == "padding" {
                let sides = value.split(whereSeparator: \.isWhitespace).map(String.init)
                let top = sides.first ?? "0"
                let right = sides.count > 1 ? sides[1] : top
                let bottom = sides.count > 2 ? sides[2] : top
                let left = sides.count > 3 ? sides[3] : right
                for (side, length) in [("top", top), ("right", right), ("bottom", bottom), ("left", left)] {
                    result["\(name)-\(side)"] = length
                }
            }
        }
        return result
    }

    /// Stands for an image the archive can't give (remote, data, escaping): it
    /// fails to load, so the page reflows with a notice instead of showing blank.
    private static let unresolvedImage = "unresolved-image"

    private static func resolvingURLs(in value: String, directory: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#) else { return value }
        let source = value as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let target = source.substring(with: match.range(at: 1))
            if URL(string: target)?.scheme == nil, let path = ArchivePath.normalized(target.removingFragment, relativeTo: directory) {
                result += "url(\(path))"
            } else {
                result += "url(\(unresolvedImage))"
            }
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    /// Every declaration that applies to a node, inline style last.
    func computed(for node: XMLNode, directory: String) -> [String: String] {
        var result: [String: String] = [:]
        for rule in rules where rule.matches(node) {
            result.merge(rule.declarations) { _, new in new }
        }
        if let inline = node.attributes["style"] {
            result.merge(Self.declarations(inline, directory: directory)) { _, new in new }
        }
        return result
    }

    /// The archive path in a resolved value's `url()`.
    static func path(in value: String?) -> String? {
        guard let value, let open = value.range(of: "url("), let close = value[open.upperBound...].firstIndex(of: ")") else { return nil }
        return String(value[open.upperBound..<close])
    }

    /// A length in page units. Percentages take `basis`; em takes `font`.
    static func length(_ value: String?, basis: CGFloat, font: CGFloat = 16, page: CGSize = .zero) -> CGFloat? {
        guard let text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty, text != "auto" else { return nil }
        let units: [(String, CGFloat)] = [
            ("rem", 16), ("em", font), ("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("in", 96), ("cm", 96 / 2.54),
            ("mm", 96 / 25.4), ("vw", page.width / 100), ("vh", page.height / 100), ("%", basis / 100), ("", 1)
        ]
        for (unit, factor) in units where text.hasSuffix(unit) {
            guard let number = Double(text.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) else { continue }
            return CGFloat(number) * factor
        }
        return nil
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()` and basic names.
    static func color(_ value: String?) -> NSColor? {
        guard let text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        if text.hasPrefix("#") {
            var digits = String(text.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
            let value = digits.count == 8 ? number : number << 8 | 0xFF
            func channel(_ shift: UInt64) -> CGFloat { CGFloat((value >> shift) & 0xFF) / 255 }
            return rgb(channel(24), channel(16), channel(8), channel(0))
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") {
            let parts = text[text.index(after: open)..<close].split(whereSeparator: { ", /".contains($0) })
            let numbers = parts.compactMap { part -> CGFloat? in
                part.hasSuffix("%") ? Double(part.dropLast()).map { CGFloat($0) * 2.55 } : Double(part).map { CGFloat($0) }
            }
            guard numbers.count >= 3 else { return nil }
            return rgb(numbers[0] / 255, numbers[1] / 255, numbers[2] / 255, numbers.count > 3 ? numbers[3] : 1)
        }
        if text.hasPrefix("hsl"), let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") {
            let parts = text[text.index(after: open)..<close].split(whereSeparator: { ", /".contains($0) })
                .compactMap { Double($0.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "")) }
            guard parts.count >= 3 else { return nil }
            let (saturation, light) = (parts[1] / 100, parts[2] / 100)
            let chroma = (1 - abs(2 * light - 1)) * saturation
            func channel(_ shift: Double) -> CGFloat {
                let k = (shift + parts[0] / 30).truncatingRemainder(dividingBy: 12)
                return CGFloat(light - chroma / 2 * max(-1, min(k - 3, 9 - k, 1)))
            }
            return rgb(channel(0), channel(8), channel(4), parts.count > 3 ? CGFloat(parts[3]) : 1)
        }
        return switch text {
        case "transparent": rgb(0, 0, 0, 0)
        case "navy": rgb(0, 0, 0.5)
        case "maroon": rgb(0.5, 0, 0)
        case "purple": rgb(0.5, 0, 0.5)
        case "teal": rgb(0, 0.5, 0.5)
        case "olive": rgb(0.5, 0.5, 0)
        case "silver": rgb(0.75, 0.75, 0.75)
        case "lime": rgb(0, 1, 0)
        case "aqua", "cyan": rgb(0, 1, 1)
        case "fuchsia", "magenta": rgb(1, 0, 1)
        case "brown": rgb(0.65, 0.16, 0.16)
        case "pink": rgb(1, 0.75, 0.8)
        case "gold": rgb(1, 0.84, 0)
        case "beige": rgb(0.96, 0.96, 0.86)
        case "ivory": rgb(1, 1, 0.94)
        case "lightgray", "lightgrey": rgb(0.83, 0.83, 0.83)
        case "darkgray", "darkgrey": rgb(0.66, 0.66, 0.66)
        case "black": rgb(0, 0, 0)
        case "white": rgb(1, 1, 1)
        case "red": rgb(1, 0, 0)
        case "green": rgb(0, 0.5, 0)
        case "blue": rgb(0, 0, 1)
        case "gray", "grey": rgb(0.5, 0.5, 0.5)
        case "yellow": rgb(1, 1, 0)
        case "orange": rgb(1, 0.65, 0)
        default: nil
        }
    }

    /// The offset a `transform` moves an element by; nil for anything else,
    /// which can't be placed.
    static func translation(_ value: String?, box: CGSize) -> CGPoint? {
        guard let text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty, text != "none" else { return .zero }
        guard let pattern = try? NSRegularExpression(pattern: #"([a-z0-9]+)\(([^)]*)\)"#) else { return nil }
        let source = text as NSString
        var offset = CGPoint.zero
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            let arguments = source.substring(with: match.range(at: 2)).split(whereSeparator: { ", ".contains($0) }).map(String.init)
            func at(_ index: Int, _ basis: CGFloat) -> CGFloat? {
                arguments.indices.contains(index) ? length(arguments[index], basis: basis) : 0
            }
            switch name {
            case "translate", "translate3d":
                guard let x = at(0, box.width), let y = at(1, box.height) else { return nil }
                offset.x += x
                offset.y += y
            case "translatex":
                guard let x = at(0, box.width) else { return nil }
                offset.x += x
            case "translatey":
                guard let y = at(0, box.height) else { return nil }
                offset.y += y
            case "matrix":
                let numbers = arguments.compactMap { Double($0) }
                guard numbers.count == 6, numbers[0] == 1, numbers[1] == 0, numbers[2] == 0, numbers[3] == 1 else { return nil }
                offset.x += CGFloat(numbers[4])
                offset.y += CGFloat(numbers[5])
            case "rotate":
                guard Double(arguments.first?.replacingOccurrences(of: "deg", with: "") ?? "") == 0 else { return nil }
            case "scale":
                guard arguments.allSatisfy({ Double($0) == 1 }) else { return nil }
            default:
                return nil
            }
        }
        return offset
    }
}
