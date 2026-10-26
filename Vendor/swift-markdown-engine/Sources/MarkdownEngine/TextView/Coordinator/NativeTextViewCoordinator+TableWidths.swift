import AppKit

/// The view-only widths behind a lock: the controller writes them on the main
/// thread, the styler may read them from a styling pass anywhere.
final class TableWidthsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [CGFloat?]] = [:]
    var widths: [String: [CGFloat?]] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// View-only table column widths (doc 24 §7.3.6, deviation a): Markdown has
/// nowhere to keep them, so they live with the document's view state under a
/// key that survives cell edits: the header line's hash and the table's
/// ordinal among tables with that header.
extension NativeTextViewCoordinator {

    /// FNV-1a over the header line's UTF-16, stable across launches (Swift's `Hasher` is not).
    static func headerHash(ofTableAt range: NSRange, in text: NSString) -> UInt64 {
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: range.location, length: 0))
        var hash: UInt64 = 0xcbf29ce484222325
        for index in range.location..<min(end, NSMaxRange(range)) {
            hash ^= UInt64(text.character(at: index))
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Every table's key, by its source location, for tables in document order.
    static func tableKeys(for tables: [NSRange], in text: NSString) -> [Int: String] {
        var seen: [UInt64: Int] = [:]
        var keys: [Int: String] = [:]
        for range in tables where NSMaxRange(range) <= text.length {
            let hash = headerHash(ofTableAt: range, in: text)
            let ordinal = seen[hash, default: 0]
            seen[hash] = ordinal + 1
            keys[range.location] = String(hash, radix: 16) + "-" + String(ordinal)
        }
        return keys
    }

    /// The key of the table at `range` in the current text.
    func tableKey(forTableAt range: NSRange) -> String? {
        guard let textView else { return nil }
        let text = textView.string
        let tables = parsedDocument(for: text).tokens.filter { $0.kind == .table && $0.range.location <= range.location }.map(\.range)
        return Self.tableKeys(for: tables, in: text as NSString)[range.location]
    }

    /// The widths set for the table at `range` (empty: all Auto).
    func columnWidths(forTableAt range: NSRange) -> [CGFloat?] {
        guard let widths = editorController?.tableWidthsStore.widths, !widths.isEmpty,
              let key = tableKey(forTableAt: range) else { return [] }
        return widths[key] ?? []
    }
}
