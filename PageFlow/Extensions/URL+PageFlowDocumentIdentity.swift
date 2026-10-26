//
//  URL+PageFlowDocumentIdentity.swift
//  PageFlow
//
//  Canonical file URL helpers for document identity comparisons.
//

import Foundation

extension URL {
    var pageFlowCanonicalDocumentURL: URL {
        guard isFileURL else { return self }
        return standardizedFileURL.resolvingSymlinksInPath()
    }

    /// A security-scoped bookmark for cross-launch reopen (S8 session restore) —
    /// the single minting primitive the restore-capture path uses, matching the
    /// `.withSecurityScope` bookmark `RecentFilesManager` creates. Valid while the
    /// app still has access to the file (an open document, or a user-selected URL).
    /// Returns `nil` for a non-file URL or when the sandbox won't vend a scoped
    /// bookmark (non-sandboxed build / no access) — the caller then falls back to
    /// the plain path.
    var pageFlowSecurityScopedBookmark: Data? {
        guard isFileURL else { return nil }
        return try? bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// The Markdown file extensions PageFlow treats as a Markdown document. The
    /// single authority every Markdown classification composes — the openable-document
    /// gate, the open-path content routing (`TabManager.documentKind`), and the open
    /// panel's allowed types — so the set never drifts between entry points. Add a
    /// new Markdown-family extension (or `.html` later) in exactly one place.
    static let pageFlowMarkdownExtensions = ["md", "markdown"]

    /// Whether this URL names a Markdown document by extension.
    var pageFlowIsMarkdown: Bool {
        URL.pageFlowMarkdownExtensions.contains(pathExtension.lowercased())
    }

    /// The file extensions PageFlow opens as a document tab today: PDF plus the
    /// Markdown family. The single authority the OPEN gates (`onOpenURL`,
    /// `application(open:)`, pending-URL enqueue, Recent Files) filter on, so the
    /// set never drifts between entry points. NOT a substitute for the strict
    /// per-engine load firewalls — `PDFManager.loadDocument` stays PDF-only and a
    /// `.md` is still routed exclusively through `MarkdownDocumentManager`.
    var pageFlowIsOpenableDocument: Bool {
        pathExtension.lowercased() == "pdf" || pageFlowIsMarkdown
    }
}
