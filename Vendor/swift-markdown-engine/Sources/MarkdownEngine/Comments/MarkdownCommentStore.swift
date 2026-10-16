import Foundation

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

    /// Moves every anchor through `edit` (`text` is the text after it). An
    /// anchor whose text was replaced whole looks for its quote inside the
    /// replacement (a format command or a table rewrite keeps it); one whose
    /// text is gone detaches, as in the reference editor.
    func textDidChange(_ edit: MarkdownTextEdit, text: NSString) {
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
                liveExact[id] = nil
                if focusID == id { focusID = nil }
                if activeID == id { activeID = nil }
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
