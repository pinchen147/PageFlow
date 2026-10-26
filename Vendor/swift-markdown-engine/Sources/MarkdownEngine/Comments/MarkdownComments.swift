import Foundation

/// the reference editor's comments (doc 25), for one local user: no author, no
/// mentions, no server. A thread is anchored to text by a quote, holds a
/// root comment and one level of replies, and is open or resolved.

/// One comment: a thread's root or one of its replies.
public struct MarkdownComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var body: String
    public var createdAt: Date
    /// Saved after an edit: the card shows "(edited)".
    public var edited: Bool
    /// The emoji reacted with, in the order they were added (the reference editor's eight).
    public var reactions: [String]

    public init(id: String = MarkdownComment.newID(), body: String, createdAt: Date = Date(),
                edited: Bool = false, reactions: [String] = []) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.edited = edited
        self.reactions = reactions
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        edited = try values.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        reactions = try values.decodeIfPresent([String].self, forKey: .reactions) ?? []
    }
}

/// Where a thread sits: a W3C TextQuoteSelector over the note's source, the
/// quoted text with up to 32 characters either side ("any offset rots").
public struct MarkdownCommentAnchor: Codable, Equatable, Sendable {
    public var prefix: String
    public var exact: String
    public var suffix: String

    public init(prefix: String, exact: String, suffix: String) {
        self.prefix = prefix
        self.exact = exact
        self.suffix = suffix
    }
}

public struct MarkdownCommentThread: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var anchor: MarkdownCommentAnchor
    /// The text it was on is gone: the thread shows only in the list, "was on:".
    public var detached: Bool
    public var resolved: Bool
    /// A reaction on text: the root's body is one emoji and the rail shows a chip.
    public var reactionOnly: Bool
    /// On a whole table (its "…" menu): outlined, not filled.
    public var table: Bool
    /// On a range of table cells: each cell is filled.
    public var cells: Bool
    public var root: MarkdownComment
    public var replies: [MarkdownComment]

    public init(id: String = MarkdownComment.newID(), anchor: MarkdownCommentAnchor, detached: Bool = false,
                resolved: Bool = false, reactionOnly: Bool = false, table: Bool = false, cells: Bool = false,
                root: MarkdownComment, replies: [MarkdownComment] = []) {
        self.id = id
        self.anchor = anchor
        self.detached = detached
        self.resolved = resolved
        self.reactionOnly = reactionOnly
        self.table = table
        self.cells = cells
        self.root = root
        self.replies = replies
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        anchor = try values.decode(MarkdownCommentAnchor.self, forKey: .anchor)
        detached = try values.decodeIfPresent(Bool.self, forKey: .detached) ?? false
        resolved = try values.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        reactionOnly = try values.decodeIfPresent(Bool.self, forKey: .reactionOnly) ?? false
        table = try values.decodeIfPresent(Bool.self, forKey: .table) ?? false
        cells = try values.decodeIfPresent(Bool.self, forKey: .cells) ?? false
        root = try values.decode(MarkdownComment.self, forKey: .root)
        replies = try values.decodeIfPresent([MarkdownComment].self, forKey: .replies) ?? []
    }

    /// Every comment, root first.
    public var comments: [MarkdownComment] { [root] + replies }
}

/// How a note's comments show (doc 25 §5.6): cards in the margin rail, the
/// list panel, or hidden (highlights too).
public enum MarkdownCommentsMode: Equatable, Sendable {
    case margin, list, hidden
}

/// A note's comments, kept in the note itself: one HTML comment at its end,
///
///     <!-- pageflow-comments
///     {"threads": [ … ], "version": 1}
///     -->
///
/// after a blank line. Markdown renderers (and GitHub) show nothing for it;
/// the host splits it off when the note opens, so the editor never sees it,
/// and joins it back when the note is saved.
public enum MarkdownCommentBlock {
    public static let version = 1
    static let opener = "<!-- pageflow-comments"
    static let closer = "-->"

    private struct File: Codable {
        var version: Int
        var threads: [MarkdownCommentThread]
    }

    /// The note's text and its comment block (empty when it has none). Only a
    /// block that reads as comments, with nothing but white space after it,
    /// counts; anything else stays text.
    public static func split(_ source: String) -> (body: String, block: String) {
        let none = (body: source, block: "")
        let trimmed = source.reversed().drop { $0 == "\n" || $0 == " " || $0 == "\t" }
        guard String(trimmed.prefix(closer.count).reversed()) == closer,
              let open = source.range(of: opener + "\n", options: .backwards),
              open.lowerBound == source.startIndex || source[source.index(before: open.lowerBound)] == "\n" else { return none }
        let block = String(source[open.lowerBound...])
        guard !threads(in: block).isEmpty else { return none }
        var body = String(source[..<open.lowerBound])
        if body.hasSuffix("\n\n") { body.removeLast() }
        return (body, block)
    }

    /// The note's source: `body`, then `block` after a blank line. No block
    /// leaves the text as it is; a block after text with no final line break
    /// adds one.
    public static func join(body: String, block: String) -> String {
        guard !block.isEmpty else { return body }
        guard !body.isEmpty else { return block }
        return body + (body.hasSuffix("\n") ? "\n" : "\n\n") + block
    }

    /// The block holding `threads`; empty for none.
    public static func block(for threads: [MarkdownCommentThread]) -> String {
        guard !threads.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(version: version, threads: threads)),
              let json = String(data: data, encoding: .utf8) else { return "" }
        // "-->" can only appear inside a JSON string, where \u003e reads back as ">".
        return opener + "\n" + json.replacingOccurrences(of: "-->", with: "--\\u003e") + "\n" + closer + "\n"
    }

    /// The threads in `block`; empty when it holds none or can't be read.
    public static func threads(in block: String) -> [MarkdownCommentThread] {
        guard block.hasPrefix(opener + "\n"), let end = block.range(of: closer, options: .backwards) else { return [] }
        let json = block[block.index(block.startIndex, offsetBy: opener.count + 1)..<end.lowerBound]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: Data(json.utf8)))?.threads ?? []
    }
}
