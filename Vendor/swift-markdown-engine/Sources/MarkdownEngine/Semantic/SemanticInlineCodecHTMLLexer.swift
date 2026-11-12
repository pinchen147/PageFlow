import Foundation

/// Lexical tokens and paired extents only; nothing here renders or activates HTML.
enum SemanticInlineCodecHTMLLexer {
    struct Token {
        let range: NSRange
        let name: String?
        let closing: Bool
        let selfClosing: Bool
    }

    struct Index {
        let tokens: [Int: Token]
        let elements: [Int: NSRange]

        init(_ text: NSString, protected: [NSRange]) {
            var scanner = Scanner(text)
            var scanned: [Token] = []
            var cursor = 0
            var protectedIndex = 0
            while cursor < text.length {
                let next = scanner.delimiters.less[cursor]
                guard next >= 0 else { break }
                cursor = next
                while protectedIndex < protected.count, NSMaxRange(protected[protectedIndex]) <= cursor { protectedIndex += 1 }
                if protectedIndex < protected.count, NSLocationInRange(cursor, protected[protectedIndex]) {
                    cursor = NSMaxRange(protected[protectedIndex])
                    continue
                }
                if let token = scanner.token(at: cursor) {
                    scanned.append(token)
                    cursor = NSMaxRange(token.range)
                } else { cursor += 1 }
            }
            tokens = Dictionary(uniqueKeysWithValues: scanned.map { ($0.range.location, $0) })
            var nextClose: [String: Int] = [:]
            var rawEnds: [Int: Int] = [:]
            for index in scanned.indices.reversed() {
                let token = scanned[index]
                guard let name = token.name else { continue }
                if token.closing { nextClose[name] = index
                } else if rawTextNames.contains(name), let end = nextClose[name] { rawEnds[index] = end }
            }
            var stacks: [String: [Token]] = [:]
            var extents: [Int: NSRange] = [:]
            var index = 0
            while index < scanned.count {
                let token = scanned[index]
                extents[token.range.location] = token.range
                guard let name = token.name, !token.selfClosing, !voidNames.contains(name) else { index += 1; continue }
                if !token.closing, rawTextNames.contains(name), let end = rawEnds[index] {
                    extents[token.range.location] = NSRange(location: token.range.location,
                        length: NSMaxRange(scanned[end].range) - token.range.location)
                    index = end + 1
                    continue
                }
                if token.closing {
                    if let opening = stacks[name]?.popLast() {
                        extents[opening.range.location] = NSRange(location: opening.range.location,
                            length: NSMaxRange(token.range) - opening.range.location)
                    }
                } else { stacks[name, default: []].append(token) }
                index += 1
            }
            elements = extents
        }

        func elementRange(starting token: Token) -> NSRange { elements[token.range.location] ?? token.range }
    }

    /// Suffix delimiter indexes prevent repeated incomplete quotes/comments from rescanning input.
    private struct Delimiters {
        let less: [Int]
        let greater: [Int]
        let single: [Int]
        let double: [Int]
        let comment: [Int]
        let cdata: [Int]
        let instruction: [Int]

        init(_ units: [unichar]) {
            func positions(_ sequence: [unichar]) -> [Int] {
                var result = [Int](repeating: -1, count: units.count + 1)
                for index in units.indices.reversed() {
                    let matches = index + sequence.count <= units.count && sequence.indices.allSatisfy { units[index + $0] == sequence[$0] }
                    result[index] = matches ? index : result[index + 1]
                }
                return result
            }
            less = positions([60]); greater = positions([62]); single = positions([39]); double = positions([34])
            comment = positions([45, 45, 62]); cdata = positions([93, 93, 62]); instruction = positions([63, 62])
        }
    }

    private enum Tail {
        case end(Int, Bool)
        case invalid
    }

    private struct Scanner {
        let text: NSString
        let units: [unichar]
        let delimiters: Delimiters
        var tails: [Int: Tail] = [:]
        var declarations: [Int: Int] = [:]

        init(_ text: NSString) {
            self.text = text
            units = Array((text as String).utf16)
            delimiters = Delimiters(units)
        }

        mutating func token(at offset: Int) -> Token? {
            for (open, ends, width) in [("<!--", delimiters.comment, 3), ("<![CDATA[", delimiters.cdata, 3), ("<?", delimiters.instruction, 2)] {
                if matches(open, at: offset) {
                    let end = ends[offset + open.utf16.count]
                    guard end >= 0 else { return nil }
                    return Token(range: NSRange(location: offset, length: end + width - offset), name: nil,
                                 closing: false, selfClosing: true)
                }
            }
            if matches("<!DOCTYPE", at: offset, options: .caseInsensitive) {
                let start = offset + 9
                guard start < units.count, whitespace(units[start]), let end = declarationEnd(from: start) else { return nil }
                return Token(range: NSRange(location: offset, length: end - offset), name: nil, closing: false, selfClosing: true)
            }
            var cursor = offset + 1
            guard cursor < units.count else { return nil }
            let closing = units[cursor] == 47
            if closing { cursor += 1 }
            let start = cursor
            guard cursor < units.count, letter(units[cursor]) else { return nil }
            cursor += 1
            while cursor < units.count, nameUnit(units[cursor]) { cursor += 1 }
            let name = text.substring(with: NSRange(location: start, length: cursor - start)).lowercased()
            if closing {
                while cursor < units.count, whitespace(units[cursor]) { cursor += 1 }
                guard cursor < units.count, units[cursor] == 62 else { return nil }
                return Token(range: NSRange(location: offset, length: cursor + 1 - offset), name: name, closing: true, selfClosing: false)
            }
            guard case .end(let end, let selfClosing) = attributeTail(from: cursor) else { return nil }
            return Token(range: NSRange(location: offset, length: end - offset), name: name, closing: false, selfClosing: selfClosing)
        }

        mutating func attributeTail(from start: Int) -> Tail {
            var cursor = start
            var visited: [Int] = []
            var result: Tail = .invalid
            while cursor < units.count {
                if let cached = tails[cursor] { result = cached; break }
                visited.append(cursor)
                let beforeSpace = cursor
                while cursor < units.count, whitespace(units[cursor]) { cursor += 1 }
                guard cursor < units.count else { break }
                if units[cursor] == 62 { result = .end(cursor + 1, false); break }
                if units[cursor] == 47, cursor + 1 < units.count, units[cursor + 1] == 62 { result = .end(cursor + 2, true); break }
                guard cursor > beforeSpace, attributeStart(units[cursor]) else { break }
                cursor += 1
                while cursor < units.count, attributeUnit(units[cursor]) { cursor += 1 }
                let attributeEnd = cursor
                while cursor < units.count, whitespace(units[cursor]) { cursor += 1 }
                guard cursor < units.count else { break }
                if units[cursor] != 61 { cursor = attributeEnd; continue }
                cursor += 1
                while cursor < units.count, whitespace(units[cursor]) { cursor += 1 }
                guard cursor < units.count else { break }
                if units[cursor] == 34 || units[cursor] == 39 {
                    let end = units[cursor] == 34 ? delimiters.double[cursor + 1] : delimiters.single[cursor + 1]
                    guard end >= 0 else { break }
                    cursor = end + 1
                } else {
                    let valueStart = cursor
                    while cursor < units.count, !whitespace(units[cursor]), units[cursor] != 62 {
                        if [34, 39, 61, 60, 96].contains(units[cursor]) { break }
                        cursor += 1
                    }
                    guard cursor > valueStart else { break }
                }
            }
            for offset in visited { tails[offset] = result }
            return result
        }

        mutating func declarationEnd(from start: Int) -> Int? {
            var cursor = start
            var visited: [Int] = []
            var result = -1
            while cursor < units.count {
                if let cached = declarations[cursor] { result = cached; break }
                visited.append(cursor)
                let candidates = [delimiters.greater[cursor], delimiters.single[cursor], delimiters.double[cursor]].filter { $0 >= 0 }
                guard let next = candidates.min() else { break }
                cursor = next
                if units[cursor] == 62 { result = cursor + 1; break }
                let end = units[cursor] == 34 ? delimiters.double[cursor + 1] : delimiters.single[cursor + 1]
                guard end >= 0 else { break }
                cursor = end + 1
            }
            for offset in visited { declarations[offset] = result }
            return result < 0 ? nil : result
        }

        private func matches(_ value: String, at offset: Int, options: NSString.CompareOptions = []) -> Bool {
            let count = value.utf16.count
            guard offset + count <= units.count else { return false }
            return text.compare(value, options: options, range: NSRange(location: offset, length: count)) == .orderedSame
        }
    }

    private static let voidNames: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let rawTextNames: Set<String> = ["script", "style", "textarea", "title", "code"]
    private static func whitespace(_ unit: unichar) -> Bool { unit == 32 || (9...13).contains(unit) }
    private static func letter(_ unit: unichar) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
    private static func nameUnit(_ unit: unichar) -> Bool { letter(unit) || (48...57).contains(unit) || unit == 45 }
    private static func attributeStart(_ unit: unichar) -> Bool { letter(unit) || unit == 95 || unit == 58 }
    private static func attributeUnit(_ unit: unichar) -> Bool { attributeStart(unit) || (48...57).contains(unit) || unit == 45 || unit == 46 }
}
