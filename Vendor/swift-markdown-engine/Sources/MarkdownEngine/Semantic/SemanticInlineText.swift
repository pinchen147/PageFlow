import Foundation

struct SemanticInlineMarks: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let underline = Self(rawValue: 1 << 2)
    static let highlight = Self(rawValue: 1 << 3)
    static let strikethrough = Self(rawValue: 1 << 4)
    static let all: Self = [.bold, .italic, .underline, .highlight, .strikethrough]
}

enum SemanticInlineLink: Equatable, Sendable {
    case url(destination: String, title: String?)
    case wiki(target: String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.url(a, at), .url(b, bt)): return exact(a, b) && exact(at, bt)
        case let (.wiki(a), .wiki(b)): return exact(a, b)
        default: return false
        }
    }
}

enum SemanticInlineObject: Equatable, Sendable {
    case math(String)
    case image(source: String, alt: String, title: String?)
    case embed(String)
    case opaque(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.math(a), .math(b)), let (.embed(a), .embed(b)), let (.opaque(a), .opaque(b)):
            return exact(a, b)
        case let (.image(a, aa, at), .image(b, ba, bt)):
            return exact(a, b) && exact(aa, ba) && exact(at, bt)
        default: return false
        }
    }
}

private func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
private func exact(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case let (.some(a), .some(b)): return exact(a, b)
    case (.none, .none): return true
    default: return false
    }
}

struct SemanticInlineRun: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case text(String)
        case code(String)
        case object(SemanticInlineObject)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.text(a), .text(b)), let (.code(a), .code(b)): return exact(a, b)
            case let (.object(a), .object(b)): return a == b
            default: return false
            }
        }
    }

    let payload: Payload
    let marks: SemanticInlineMarks
    let link: SemanticInlineLink?

    var text: String {
        switch payload {
        case .text(let value), .code(let value): return value
        case .object: return "\u{FFFC}"
        }
    }

    init(text: String, marks: SemanticInlineMarks = [], link: SemanticInlineLink? = nil) {
        self.init(payload: .text(text), marks: marks, link: link)
    }

    init(code: String, marks: SemanticInlineMarks = [], link: SemanticInlineLink? = nil) {
        self.init(payload: .code(code), marks: marks, link: link)
    }

    init(object: SemanticInlineObject, marks: SemanticInlineMarks = [], link: SemanticInlineLink? = nil) {
        self.init(payload: .object(object), marks: marks, link: link)
    }

    init(payload: Payload, marks: SemanticInlineMarks = [], link: SemanticInlineLink? = nil) {
        self.payload = payload
        self.marks = marks
        self.link = link
    }
}

struct SemanticInlineText: Equatable, Sendable {
    enum EditError: Error {
        case invalidRange
        case invalidMark
    }

    let runs: [SemanticInlineRun]

    init(runs: [SemanticInlineRun]) {
        var normalized: [SemanticInlineRun] = []
        var pending: SemanticInlineRun?
        var buffer = ""
        func flush() {
            if let pending {
                let payload: SemanticInlineRun.Payload
                if case .code = pending.payload { payload = .code(buffer) } else { payload = .text(buffer) }
                normalized.append(.init(payload: payload, marks: pending.marks, link: pending.link))
            }
            pending = nil
            buffer = ""
        }
        for run in runs {
            if case .object = run.payload {
                flush()
                normalized.append(run)
                continue
            }
            guard !run.text.isEmpty else { continue }
            if let previous = pending {
                let previousCode: Bool
                let currentCode: Bool
                if case .code = previous.payload { previousCode = true } else { previousCode = false }
                if case .code = run.payload { currentCode = true } else { currentCode = false }
                if previous.marks != run.marks || previous.link != run.link || previousCode != currentCode { flush() }
            }
            pending = run
            buffer.append(contentsOf: run.text)
        }
        flush()
        self.runs = normalized
    }

    init(text: String, marks: SemanticInlineMarks = []) {
        self.init(runs: [SemanticInlineRun(text: text, marks: marks)])
    }

    var text: String { runs.map(\.text).joined() }
    var utf16Count: Int { runs.reduce(0) { $0 + $1.text.utf16.count } }

    func toggling(_ mark: SemanticInlineMarks, in range: NSRange) throws -> Self {
        guard mark.rawValue > 0,
              mark.rawValue & (mark.rawValue - 1) == 0,
              mark.subtracting(.all).isEmpty else {
            throw EditError.invalidMark
        }
        let bounds = try Self.validatedBounds(range, in: text)
        guard !bounds.isEmpty else { return self }
        let selected = runs(in: bounds)
        let remove = selected.allSatisfy { $0.marks.contains(mark) }
        let changed = selected.map {
            SemanticInlineRun(payload: $0.payload, marks: remove ? $0.marks.subtracting(mark) : $0.marks.union(mark), link: $0.link)
        }
        return Self(runs: runs(in: 0..<bounds.lowerBound) + changed
            + runs(in: bounds.upperBound..<utf16Count))
    }

    func replacing(_ range: NSRange, with replacement: Self) throws -> Self {
        let bounds = try Self.validatedBounds(range, in: text)
        return Self(runs: runs(in: 0..<bounds.lowerBound) + replacement.runs
            + runs(in: bounds.upperBound..<utf16Count))
    }

    func slice(in range: NSRange) throws -> Self {
        Self(runs: runs(in: try Self.validatedBounds(range, in: text)))
    }

    static func validatedBounds(_ range: NSRange, in value: String) throws -> Range<Int> {
        let count = value.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= count, range.length <= count - range.location else {
            throw EditError.invalidRange
        }
        let end = range.location + range.length
        var offset = 0
        var foundStart = range.location == 0
        var foundEnd = end == 0
        for character in value {
            offset += String(character).utf16.count
            if offset == range.location { foundStart = true }
            if offset == end { foundEnd = true }
            if offset >= end { break }
        }
        guard foundStart, foundEnd else { throw EditError.invalidRange }
        return range.location..<end
    }

    private func runs(in bounds: Range<Int>) -> [SemanticInlineRun] {
        guard !bounds.isEmpty else { return [] }
        var selected: [SemanticInlineRun] = []
        var offset = 0
        for run in runs {
            let end = offset + run.text.utf16.count
            let start = max(offset, bounds.lowerBound)
            let stop = min(end, bounds.upperBound)
            if start < stop {
                let part = (run.text as NSString).substring(
                    with: NSRange(location: start - offset, length: stop - start)
                )
                let payload: SemanticInlineRun.Payload
                switch run.payload {
                case .text: payload = .text(part)
                case .code: payload = .code(part)
                case .object: payload = run.payload
                }
                selected.append(SemanticInlineRun(payload: payload, marks: run.marks, link: run.link))
            }
            offset = end
            if offset >= bounds.upperBound { break }
        }
        return selected
    }
}
