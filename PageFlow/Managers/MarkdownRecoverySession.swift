import Foundation
import MarkdownEngine

/// Keeps recovery independent of binding debounce and original-file saves.
@MainActor
final class MarkdownRecoverySession {
    private weak var content: MarkdownContent?
    private let store: MarkdownRecoveryStore
    private var id = UUID()
    private var originalURL: URL?
    private var originalTitle: String?
    private var timer: Task<Void, Never>?
    private var hasCheckpoint = false
    private var isRetired = false
    private var didReportFailure = false
    var onFailure: ((String) -> Void)?

    init(content: MarkdownContent, store: MarkdownRecoveryStore) {
        self.content = content
        self.store = store
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                self?.checkpoint()
            }
        }
    }

    deinit { timer?.cancel() }

    /// A bounded checkpoint also captures uninterrupted typing, whose ordinary
    /// trailing-edge model publication may not have fired yet.
    func checkpoint() {
        guard !isRetired, let content, !content.documentManager.isClosed else { return }
        let document = content.documentManager
        let body = content.editorController.currentStorageText ?? document.text
        let block = MarkdownContent.commentBlock(
            for: content.editorController.commentThreadsForSaving(text: body), keeping: document.commentBlock
        )
        let source = MarkdownCommentBlock.join(body: body, block: block)
        if source.hasSameSource(as: document.savedText), !document.isDirty {
            if hasCheckpoint { store.remove(id); hasCheckpoint = false }
            return
        }
        hasCheckpoint = true
        let record = MarkdownRecoveryStore.Record(
            id: id, title: document.documentURL == nil ? (originalTitle ?? document.documentTitle) : document.documentTitle,
            originalURL: document.documentURL ?? originalURL, source: body, commentBlock: block, updatedAt: Date()
        )
        store.checkpoint(record) { [weak self] message in
            Task { @MainActor in
                guard let self, !self.isRetired, !self.didReportFailure, let report = self.onFailure else { return }
                self.didReportFailure = true
                report(message)
            }
        }
    }

    func adopt(_ record: MarkdownRecoveryStore.Record) {
        id = record.id
        originalURL = record.originalURL
        originalTitle = record.title
        hasCheckpoint = true
    }

    /// Called only after a deliberate close/discard or approved termination.
    func retire() {
        isRetired = true
        timer?.cancel()
        timer = nil
        if hasCheckpoint { store.remove(id); hasCheckpoint = false }
    }
}
