import Foundation
import CoreFoundation

/// Shared only by the deletion, insertion and inverses of one exact block move.
final class MarkdownCommentMove {
    let source: String

    init(source: String) { self.source = source }
}

/// A note's comment threads and where each sits in the live text (doc 25).
/// Host-retained with the editor controller, so threads, drafts and the
/// comments mode outlive a remount. The anchors kept on the threads are the
/// ones the note file on disk matches: they move to the live text only when
/// the note is saved (`threadsForSaving`), so comments written to the
/// sidecar before then still find their text in the file.
@MainActor
final class MarkdownCommentStore {
    typealias Mode = MarkdownCommentsMode
    enum Filter: Equatable { case open, resolved, all }

    /// The comment being written in the composer.
    struct Draft: Equatable {
        var range: NSRange
        var text = ""
        /// The selection was longer than the anchor budget.
        var clamped = false
        /// A whole table (its "…" menu).
        var table = false
        /// A range of table cells.
        var cells = false
    }

    private(set) var threads: [MarkdownCommentThread] = []
    /// The live range of every attached thread.
    private(set) var ranges: [String: NSRange] = [:]
    /// Each attached thread's text now, for finding it inside a replacement.
    private var liveExact: [String: String] = [:]
    private enum ParkedAnchor {
        case context(MarkdownCommentAnchor)
        case move(MarkdownCommentMove, offset: Int, exact: String)
    }
    private struct MoveEdit {
        let receipt: MarkdownCommentMove
        let edit: MarkdownTextEdit
        let core: NSRange
    }
    private var parked: [String: ParkedAnchor] = [:]
    private var pendingMoveEdit: MoveEdit?
    private var parkingObserver: CFRunLoopObserver?
    private weak var observedUndo: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []

    /// Undo starts a new gesture even if a caller invokes it before the run loop waits.
    /// Its own synchronous remove/insert replay still shares the parking window.
    func observeUndoBoundaries(of undo: UndoManager?) {
        guard undo !== observedUndo else { return }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers.removeAll()
        observedUndo = undo
        guard let undo else { return }
        for name: Notification.Name in [.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: undo, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.expireParkedAnchors() }
            })
        }
    }

    deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

    /// A move and its inverse remove and insert synchronously. A later paste must not inherit comments.
    func expireParkedAnchors() {
        pendingMoveEdit = nil
        if let observer = parkingObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        parkingObserver = nil
        for id in parked.keys {
            liveExact[id] = nil
            if focusID == id { focusID = nil }
            if activeID == id { activeID = nil }
        }
        let changed = !parked.isEmpty
        parked.removeAll()
        if changed { onDisplayChange?() }
    }

    private func park(_ id: String, range: NSRange, edit: MarkdownTextEdit, move: MoveEdit?) {
        if let move, range.location >= move.core.location, NSMaxRange(range) <= NSMaxRange(move.core) {
            parked[id] = .move(move.receipt, offset: range.location - move.core.location, exact: liveExact[id] ?? "")
        } else {
            let saved = thread(id)?.anchor
            let prefix = String((saved?.prefix ?? "").suffix(min(32, range.location - edit.location)))
            let suffix = String((saved?.suffix ?? "").prefix(min(32, edit.removedEnd - NSMaxRange(range))))
            parked[id] = .context(MarkdownCommentAnchor(prefix: prefix, exact: liveExact[id] ?? "", suffix: suffix))
        }
        guard parkingObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.expireParkedAnchors() }
        }
        parkingObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    /// The threads were loaded before an editor showed the note.
    private(set) var needsResolve = false

    // MARK: UI state that outlives a remount

    var mode: Mode = .margin {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    var onModeChange: ((Mode) -> Void)?
    var filter: Filter?
    /// The lit thread: hovered, or its card hovered (45 % paint).
    var activeID: String?
    /// The open (expanded) thread: 45 % plus the 2 pt underline.
    var focusID: String?
    var draft: Draft?
    /// Unsent replies, per thread, kept across collapse.
    var replyDrafts: [String: String] = [:]
    /// A `#thread-` link asked for this thread before an editor showed the note.
    var pendingOpenID: String?
    /// The comment being edited and its field's text.
    var editing: (commentID: String, text: String)?

    /// The threads changed in a way the sidecar must keep (post, reply, resolve…).
    var onPersist: (([MarkdownCommentThread]) -> Void)?
    /// Anything shown changed: highlights, the rail, the list.
    var onDisplayChange: (() -> Void)?

    // MARK: - Loading and saving

    /// Takes the sidecar's threads and finds each attached one in `text`, the
    /// live note, or when an editor first shows it (`resolveIfNeeded`).
    func load(_ loaded: [MarkdownCommentThread], text: NSString?) {
        expireParkedAnchors()
        threads = loaded
        focusID = nil
        activeID = nil
        if let text { resolveAll(in: text) } else {
            ranges = [:]
            liveExact = [:]
            needsResolve = true
        }
        onDisplayChange?()
    }

    func resolveIfNeeded(in text: NSString) {
        guard needsResolve else { return }
        resolveAll(in: text)
        onDisplayChange?()
    }

    /// Finds every attached thread in `text` by its quote.
    private func resolveAll(in text: NSString) {
        needsResolve = false
        ranges = [:]
        liveExact = [:]
        for thread in threads where !thread.detached {
            guard let range = MarkdownCommentAnchoring.resolve(thread.anchor, in: text) else { continue }
            ranges[thread.id] = range
            liveExact[thread.id] = thread.anchor.exact
        }
    }

    /// The threads with anchors taken from `text`, the note being saved; the
    /// threads keep these anchors from now on.
    func threadsForSaving(text: NSString) -> [MarkdownCommentThread] {
        for index in threads.indices {
            let id = threads[index].id
            if let range = ranges[id] {
                threads[index].anchor = MarkdownCommentAnchoring.selector(for: range, in: text)
            } else if !threads[index].detached {
                threads[index].detached = true
            }
        }
        return threads
    }

    // MARK: - Following edits

    /// Called immediately before a span mutation. Only the exact moved source,
    /// optionally surrounded by blank separator lines, earns paired offsets.
    func prepareMoveEdit(receipt: MarkdownCommentMove?, range: NSRange, replacement: String, in text: NSString) {
        pendingMoveEdit = nil
        guard let receipt, !receipt.source.isEmpty else { return }
        let fragment: String
        if range.length > 0, replacement.isEmpty {
            guard range.location >= 0, range.location <= text.length,
                  range.length <= text.length - range.location else { return }
            fragment = text.substring(with: range)
        } else if range.length == 0, !replacement.isEmpty {
            fragment = replacement
        } else { return }
        let fragmentText = fragment as NSString
        let core = fragmentText.range(of: receipt.source, options: .literal)
        guard core.location != NSNotFound else { return }
        let prefix = fragmentText.substring(to: core.location)
        let suffix = fragmentText.substring(from: NSMaxRange(core))
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prefix.isEmpty || prefix.last?.isNewline == true,
              suffix.isEmpty || suffix.first?.isNewline == true else { return }
        pendingMoveEdit = MoveEdit(
            receipt: receipt,
            edit: MarkdownTextEdit(location: range.location, removedLength: range.length, insertedLength: replacement.utf16.count),
            core: NSRange(location: range.location + core.location, length: core.length)
        )
    }

    /// Moves every anchor through `edit` (`text` is the text after it). An
    /// anchor whose text was replaced whole looks for its quote inside the
    /// replacement (a format command or a table rewrite keeps it); one whose
    /// text is gone detaches, as in the reference editor.
    func textDidChange(_ edit: MarkdownTextEdit, text: NSString) {
        let move = pendingMoveEdit.flatMap { $0.edit == edit ? $0 : nil }
        pendingMoveEdit = nil
        guard !needsResolve else { return }
        var changed = false
        for (id, range) in ranges {
            if let mapped = edit.map(range) {
                // Text inside it changed: remember what it says now.
                if mapped.length != range.length || (edit.location < NSMaxRange(range) && edit.removedEnd > range.location) {
                    liveExact[id] = text.substring(with: mapped)
                }
                guard mapped != range else { continue }
                ranges[id] = mapped
                changed = true
                continue
            }
            changed = true
            let quote = MarkdownCommentAnchor(prefix: "", exact: liveExact[id] ?? "", suffix: "")
            if edit.swallows(range), edit.insertedLength > 0,
               let found = MarkdownCommentAnchoring.resolve(quote, in: text, scope: edit.inserted) {
                ranges[id] = found
            } else {
                ranges[id] = nil
                if edit.insertedLength == 0, edit.swallows(range) {
                    park(id, range: range, edit: edit, move: move)
                    continue
                }
                liveExact[id] = nil
                if focusID == id { focusID = nil }
                if activeID == id { activeID = nil }
            }
        }
        if edit.removedLength == 0, edit.insertedLength > 0 {
            for (id, anchor) in parked {
                let found: NSRange?
                switch anchor {
                case .context(let context):
                    found = MarkdownCommentAnchoring.resolve(context, in: text, scope: edit.inserted)
                case .move(let receipt, let offset, let exact):
                    if let move, move.receipt === receipt, offset <= move.core.length,
                       exact.utf16.count <= move.core.length - offset {
                        let candidate = NSRange(location: move.core.location + offset, length: exact.utf16.count)
                        found = NSMaxRange(candidate) <= text.length
                            && (text.substring(with: candidate) as NSString).isEqual(to: exact) ? candidate : nil
                    } else { found = nil }
                }
                if let found {
                    ranges[id] = found
                    liveExact[id] = text.substring(with: found)
                    parked[id] = nil
                    changed = true
                }
            }
        }
        if var draft, let mapped = edit.map(draft.range) {
            if mapped != draft.range { draft.range = mapped; self.draft = draft; changed = true }
        }
        if changed { onDisplayChange?() }
    }

    // MARK: - Reading

    func thread(_ id: String) -> MarkdownCommentThread? { threads.first { $0.id == id } }

    /// Whether the thread shows in the text and the rail: open and attached.
    func isSeated(_ thread: MarkdownCommentThread) -> Bool { !thread.resolved && ranges[thread.id] != nil }

    /// The open, attached threads in document order, then by creation.
    var seatedThreads: [MarkdownCommentThread] {
        threads.filter(isSeated).sorted { lhs, rhs in
            let left = ranges[lhs.id]!.location, right = ranges[rhs.id]!.location
            return left != right ? left < right : lhs.root.createdAt < rhs.root.createdAt
        }
    }

    /// Threads whose anchors hold `location` (a caret), shortest anchor first, ties by id.
    func threads(at location: Int) -> [MarkdownCommentThread] {
        threads.filter { thread in
            guard isSeated(thread), let range = ranges[thread.id] else { return false }
            return location >= range.location && location <= NSMaxRange(range) && range.length > 0
        }.sorted { lhs, rhs in
            let left = ranges[lhs.id]!.length, right = ranges[rhs.id]!.length
            return left != right ? left < right : lhs.id < rhs.id
        }
    }

    /// Whether the thread's text is gone (persisted, or since the last save).
    func isDetached(_ thread: MarkdownCommentThread) -> Bool { ranges[thread.id] == nil }

    // MARK: - Changing

    func add(_ thread: MarkdownCommentThread, range: NSRange) {
        threads.append(thread)
        ranges[thread.id] = range
        liveExact[thread.id] = thread.anchor.exact
        persist()
    }

    func update(_ id: String, _ change: (inout MarkdownCommentThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[index])
        persist()
    }

    func remove(_ id: String) {
        parked[id] = nil
        threads.removeAll { $0.id == id }
        ranges[id] = nil
        liveExact[id] = nil
        replyDrafts[id] = nil
        if focusID == id { focusID = nil }
        if activeID == id { activeID = nil }
        persist()
    }

    private func persist() {
        onPersist?(threads)
        onDisplayChange?()
    }
}
