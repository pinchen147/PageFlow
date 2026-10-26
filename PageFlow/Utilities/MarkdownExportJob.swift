import Foundation
import PDFKit

/// Owns one PDF-to-Markdown request for a document session. Workers receive
/// immutable bytes and create their own PDFKit document, never a live UI PDF.
@MainActor
final class MarkdownExportJob {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    deinit { task?.cancel() }

    func start(scope: ExportScope, document: PDFDocument, comments: [CommentModel] = [],
               isCurrent: @escaping () -> Bool, completion: @escaping (String) -> Void) {
        cancel()
        guard PDFPermissions(document).copy, isCurrent() else { return }
        let range = scope.pageIndices(in: document)
        guard !range.isEmpty else { return }
        let requestGeneration = generation
        task = Task { [weak self] in
            defer { if self?.generation == requestGeneration { self?.task = nil } }
            do {
                try Task.checkCancellation()
                guard isCurrent(), PDFPermissions(document).copy else { return }
                var result: String?
                // Serializing an unlocked encrypted PDF may re-lock its bytes.
                // Keep those live objects on main and yield between pages.
                if !document.isEncrypted, let data = document.dataRepresentation() {
                    let worker = Task.detached(priority: .userInitiated) { () throws -> String? in
                        try Task.checkCancellation()
                        guard let snapshot = PDFDocument(data: data), !snapshot.isLocked,
                              range.upperBound <= snapshot.pageCount else { return nil }
                        return try MarkdownExporter.exportPages(range, document: snapshot, comments: comments)
                    }
                    result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                }
                if result == nil {
                    var pages: [String] = []
                    for index in range {
                        try Task.checkCancellation()
                        guard isCurrent(), PDFPermissions(document).copy else { return }
                        let page = try MarkdownExporter.exportPages(index..<(index + 1), document: document, comments: comments)
                        if !page.isEmpty { pages.append(page) }
                        await Task.yield()
                    }
                    result = pages.joined(separator: "\n\n---\n\n")
                }
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration, isCurrent(), PDFPermissions(document).copy,
                      let result, !result.isEmpty else { return }
                completion(result)
            } catch is CancellationError {
                // Superseded, closed or changed documents deliver nothing.
            } catch {
                assertionFailure("Unexpected Markdown export error: \(error)")
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
