import Foundation

/// the reference editor's text anchors (doc 25 §3): a quote with 32 characters either
/// side, at most 4096 characters long; found again by exact match, the
/// prefix and suffix choosing between repeats. While the note is open the
/// anchor's range follows each edit as a decoration does.
enum MarkdownCommentAnchoring {
    /// Characters kept on each side of the quote (the reference editor's `e5t`).
    static let contextLength = 32
    /// A longer selection anchors to its first 4096 characters.
    static let anchorBudget = 4096

    /// The selector for `range` in `text`, the range it covers, and whether
    /// the selection was cut to the anchor budget. Never splits a character.
    static func anchor(for range: NSRange, in text: NSString) -> (anchor: MarkdownCommentAnchor, range: NSRange, clamped: Bool) {
        var covered = clampedRange(range, length: text.length)
        let clamped = covered.length > anchorBudget
        if clamped {
            covered.length = anchorBudget
            covered = composedRange(covered, in: text)
        }
        return (selector(for: covered, in: text), covered, clamped)
    }

    /// The selector for exactly `range`.
    static func selector(for range: NSRange, in text: NSString) -> MarkdownCommentAnchor {
        let covered = clampedRange(range, length: text.length)
        let before = NSRange(location: max(0, covered.location - contextLength),
                             length: covered.location - max(0, covered.location - contextLength))
        let afterStart = NSMaxRange(covered)
        let after = NSRange(location: afterStart, length: min(contextLength, text.length - afterStart))
        return MarkdownCommentAnchor(prefix: text.substring(with: composedRange(before, in: text)),
                                     exact: text.substring(with: covered),
                                     suffix: text.substring(with: composedRange(after, in: text)))
    }

    /// Where `anchor` is in `text`, searching `scope` (the whole text when
    /// nil): every exact match, scored by how much of the prefix's end and the
    /// suffix's start agree; the best wins, ties to the first. Nil when the
    /// quote is gone.
    static func resolve(_ anchor: MarkdownCommentAnchor, in text: NSString, scope: NSRange? = nil) -> NSRange? {
        guard !anchor.exact.isEmpty else { return nil }
        let bounds = clampedRange(scope ?? NSRange(location: 0, length: text.length), length: text.length)
        var best: (range: NSRange, score: Int)?
        var searchStart = bounds.location
        while searchStart < NSMaxRange(bounds) {
            let found = text.range(of: anchor.exact, options: .literal,
                                   range: NSRange(location: searchStart, length: NSMaxRange(bounds) - searchStart))
            guard found.location != NSNotFound else { break }
            let score = contextScore(anchor, at: found, in: text)
            if best == nil || score > best!.score { best = (found, score) }
            // A perfect score cannot be beaten.
            if score == (anchor.prefix as NSString).length + (anchor.suffix as NSString).length { break }
            searchStart = found.location + 1
        }
        return best?.range
    }

    /// How many characters of context agree around `range`: the prefix read
    /// backwards from the quote, the suffix forwards.
    private static func contextScore(_ anchor: MarkdownCommentAnchor, at range: NSRange, in text: NSString) -> Int {
        let prefix = anchor.prefix as NSString
        let suffix = anchor.suffix as NSString
        var score = 0
        var index = 1
        while index <= prefix.length, range.location - index >= 0,
              prefix.character(at: prefix.length - index) == text.character(at: range.location - index) {
            score += 1
            index += 1
        }
        index = 0
        while index < suffix.length, NSMaxRange(range) + index < text.length,
              suffix.character(at: index) == text.character(at: NSMaxRange(range) + index) {
            score += 1
            index += 1
        }
        return score
    }

    private static func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    /// `range` shrunk to whole characters: a character cut at either end is dropped.
    private static func composedRange(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        let start = text.rangeOfComposedCharacterSequence(at: range.location)
        let lastIndex = NSMaxRange(range) - 1
        let last = text.rangeOfComposedCharacterSequence(at: lastIndex)
        var lower = range.location
        var upper = NSMaxRange(range)
        if start.location < lower { lower = NSMaxRange(start) }
        if NSMaxRange(last) > upper { upper = last.location }
        return upper > lower ? NSRange(location: lower, length: upper - lower) : NSRange(location: range.location, length: 0)
    }
}

/// One change to the text: `removedLength` characters at `location` became
/// `insertedLength` characters.
struct MarkdownTextEdit: Equatable {
    var location: Int
    var removedLength: Int
    var insertedLength: Int

    var delta: Int { insertedLength - removedLength }
    var removedEnd: Int { location + removedLength }
    var inserted: NSRange { NSRange(location: location, length: insertedLength) }

    /// From NSTextStorage's post-edit `editedRange` and `changeInLength`.
    init(editedRange: NSRange, changeInLength: Int) {
        location = editedRange.location
        insertedLength = editedRange.length
        removedLength = editedRange.length - changeInLength
    }

    init(location: Int, removedLength: Int, insertedLength: Int) {
        self.location = location
        self.removedLength = removedLength
        self.insertedLength = insertedLength
    }

    /// Maps an anchor through this edit as the reference editor's decorations do: the
    /// start sticks after an insertion at it and the end before one, so
    /// typing at either edge never grows the anchor; text deleted from it
    /// shrinks it; nil when all of it was deleted.
    func map(_ range: NSRange) -> NSRange? {
        let start = range.location
        let end = NSMaxRange(range)
        let mappedStart: Int
        if start < location { mappedStart = start } else if start >= removedEnd { mappedStart = start + delta } else {
            mappedStart = location + insertedLength
        }
        let mappedEnd: Int
        if end <= location { mappedEnd = end } else if end > removedEnd { mappedEnd = end + delta } else {
            mappedEnd = location
        }
        guard mappedEnd > mappedStart else { return nil }
        return NSRange(location: mappedStart, length: mappedEnd - mappedStart)
    }

    /// Whether this edit replaced all of `range` (and maybe more).
    func swallows(_ range: NSRange) -> Bool {
        location <= range.location && removedEnd >= NSMaxRange(range)
    }
}
