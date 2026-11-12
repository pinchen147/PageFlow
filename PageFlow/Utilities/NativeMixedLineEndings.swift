import AppKit
import MarkdownEngine

/// Tracks physical line breaks through the real text storage's UTF-16 replacements.
/// Equal adjacent blank lines cannot be distinguished by comparing save snapshots alone.
@MainActor
final class NativeMixedLineEndings {
    private static let separator = NSAttributedString.Key("PageFlowPhysicalLineEnding")
    private let body: NSMutableAttributedString
    private let defaultEnding: LineEnding
    private weak var undoManager: UndoManager?
    private var waitingForInitialSource: Bool
    private var observer: NSObjectProtocol?

    init(storage: NSTextStorage, source: String, layout: MixedLineEndings, defaultEnding: LineEnding, undoManager: UndoManager?) {
        self.undoManager = undoManager
        self.defaultEnding = defaultEnding
        body = NSMutableAttributedString(string: source)
        waitingForInitialSource = !storage.string.hasSameSource(as: source)
        let original = MarkdownCommentBlock.split(layout.source).body
        let originalCount = original.utf8.count { $0 == 10 }
        let originalLayout = MixedLineEndings(source: original, separators: Array(layout.separators.prefix(originalCount)))
        let separators = original.hasSameSource(as: source) ? originalLayout.separators
            : originalLayout.expanding(source, default: defaultEnding).layout.separators
        Self.mark(body, separators: separators, defaultEnding: defaultEnding)
        if !waitingForInitialSource {
            synchronizeMarkers(in: storage, range: NSRange(location: 0, length: storage.length))
        }
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification,
                                                           object: storage, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let storage = notification.object as? NSTextStorage else { return }
                self.apply(storage)
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func snapshot(matching source: String) -> MixedLineEndings? {
        guard !waitingForInitialSource, body.string.hasSameSource(as: source) else { return nil }
        return layout(in: body)
    }

    private func layout(in string: NSAttributedString) -> MixedLineEndings {
        var separators: [LineEnding] = []
        for (offset, unit) in string.string.utf16.enumerated() where unit == 10 {
            let raw = string.attribute(Self.separator, at: offset, effectiveRange: nil) as? String
            separators.append(raw.flatMap(LineEnding.init(rawValue:)) ?? defaultEnding)
        }
        return MixedLineEndings(source: string.string, separators: separators)
    }

    private static func mark(_ string: NSMutableAttributedString, separators: [LineEnding], defaultEnding: LineEnding) {
        var endings = separators.makeIterator()
        for (offset, unit) in string.string.utf16.enumerated() where unit == 10 {
            if let ending = endings.next(), ending != defaultEnding {
                string.addAttribute(separator, value: ending.rawValue, range: NSRange(location: offset, length: 1))
            }
        }
    }

    private func apply(_ storage: NSTextStorage) {
        if waitingForInitialSource {
            waitingForInitialSource = !body.string.hasSameSource(as: storage.string)
            if !waitingForInitialSource {
                synchronizeMarkers(in: storage, range: NSRange(location: 0, length: storage.length))
            }
            return
        }
        let range = storage.editedRange
        guard storage.editedMask.contains(.editedCharacters) else {
            if range.location != NSNotFound, NSMaxRange(range) <= body.length {
                synchronizeMarkers(in: storage, range: range)
            }
            return
        }
        let length = range.length - storage.changeInLength
        guard range.location != NSNotFound, length >= 0, NSMaxRange(range) <= storage.length,
              range.location + length <= body.length else {
            waitingForInitialSource = true
            return
        }
        let oldRange = NSRange(location: range.location, length: length)
        let replacement = storage.mutableString.substring(with: range)
        let previous = body.attributedSubstring(from: oldRange)
        defer { synchronizeMarkers(in: storage, range: range) }
        guard !previous.string.hasSameSource(as: replacement) else { return }
        let new = NSMutableAttributedString(string: replacement)
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            // AppKit's native undo restores the deleted attributed substring.
            Self.mark(new, separators: layout(in: storage.attributedSubstring(from: range)).separators,
                      defaultEnding: defaultEnding)
        } else if previous.string.utf8.contains(10), replacement.utf8.contains(10) {
            // A structural editor command can replace several lines in one transaction.
            let updated = layout(in: previous).expanding(replacement, default: defaultEnding)
            Self.mark(new, separators: updated.layout.separators, defaultEnding: defaultEnding)
        }
        body.replaceCharacters(in: oldRange, with: new)
    }

    /// Keep only line-ending metadata in native Undo. Restyling can erase these
    /// markers, and ordinary insertion can inherit one from an adjacent newline.
    private func synchronizeMarkers(in storage: NSTextStorage, range: NSRange) {
        body.enumerateAttribute(Self.separator, in: range) { marker, run, _ in
            storage.enumerateAttribute(Self.separator, in: run) { existing, part, _ in
                let expected = marker as? String
                guard (existing as? String) != expected else { return }
                if let expected {
                    storage.addAttribute(Self.separator, value: expected, range: part)
                } else {
                    storage.removeAttribute(Self.separator, range: part)
                }
            }
        }
    }
}
