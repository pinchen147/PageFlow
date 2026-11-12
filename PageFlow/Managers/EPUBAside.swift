//
//  EPUBAside.swift
//  PageFlow
//
//  Supplements: spine items marked linear="no" (answers, charts, extra
//  notes) stay out of the reading flow and its page count. A link, a
//  contents entry, a landmark or a Find match that leads into one opens it
//  in its own scrolling reader over the pages; Back closes it, leaving the
//  reader where they were.
//

import AppKit
import EPUBKit
import Foundation

/// A supplement open in its reader.
struct EPUBAside: Identifiable {
    var id = UUID()
    /// The reader owns the snapshot; figures keep only a weak route back.
    weak var document: EPUBContent? = nil
    let chapter: Int
    let title: String
    let text: NSAttributedString
    let palette: EPUBPagePalette
    /// Where it opens: a fragment's place (an empty range) or a Find match.
    let target: NSRange?
    /// Whether `target` is a Find match, shown selected.
    let targetIsMatch: Bool
    /// Find's query when a match opened it, so its own search starts there.
    let query: String
}

/// Read-only text and palette are the entire worker transfer. Recoloring copies
/// text and table blocks; shared attachments retain their immutable styling.
/// Document identity, navigation and publication remain on the main actor.
private nonisolated struct AsideTextSnapshot: @unchecked Sendable {
    let text: NSAttributedString
    let palette: EPUBPagePalette

    init(_ text: NSAttributedString, palette: EPUBPagePalette) {
        self.text = NSAttributedString(attributedString: text)
        self.palette = palette
    }
}

extension EPUBContent {
    /// Opens a supplement at a fragment, a Find match or an offset (a highlight
    /// or bookmark there) once its text is styled. A supplement already open keeps its reader and moves to the
    /// new place.
    func openAside(chapter: Int, fragment: String?, match: NSRange?, offset: Int = 0) {
        guard let book, let lifetime = asideLifetime, book.chapters.indices.contains(chapter) else { return }
        asideOpenTask?.cancel()
        asideOpenRevision &+= 1
        let revision = asideOpenRevision
        let origin = documentURL
        let query = match == nil ? "" : searchManager.query
        invalidateAsideRefresh()
        asideOpenTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, asideLifetime == lifetime, documentURL == origin,
                      asideOpenRevision == revision else { return }
                let (sourcePalette, sourceRevision) = (palette, paginationGeneration)
                guard let styled = await styledChapter(chapter) else { return }
                guard !Task.isCancelled, asideLifetime == lifetime, documentURL == origin,
                      asideOpenRevision == revision else { return }
                // A cache reset can return an old in-flight result. Retry against its
                // current source rather than pairing stale ink with a new palette.
                guard sourceRevision == paginationGeneration, sourcePalette == palette else { continue }
                let anchor = fragment.flatMap { styled.anchors[$0] }.map { NSRange(location: $0, length: 0) }
                let place = offset > 0 ? NSRange(location: offset, length: 0) : nil
                let target = (match ?? anchor ?? place).flatMap { NSMaxRange($0) <= styled.text.length ? $0 : nil }
                var opened = EPUBAside(document: self, chapter: chapter, title: book.chapters[chapter].title, text: styled.text,
                                       palette: sourcePalette, target: target, targetIsMatch: match != nil, query: query)
                if let shown = aside, shown.chapter == chapter { opened.id = shown.id }
                aside = opened
                refreshAsidePalette()
                return
            }
        }
    }

    private func invalidateAsideRefresh() {
        asideRefreshTask?.cancel()
        asideRefreshTask = nil
        asideRefreshRevision &+= 1
    }

    /// The immutable open snapshot supplies both the source text and its ink.
    /// No chapter await or reopen can overwrite the reader's local navigation.
    func refreshAsidePalette() {
        invalidateAsideRefresh()
        guard let source = aside, let lifetime = asideLifetime else { return }
        let requested = requestedPalette
        guard source.palette != requested else { return }
        let revision = asideRefreshRevision
        let origin = documentURL
        let snapshot = AsideTextSnapshot(source.text, palette: source.palette)
        let work = Task.detached(priority: .userInitiated) {
            AsideTextSnapshot(EPUBTextStyling.recoloring(snapshot.text, from: snapshot.palette, to: requested),
                              palette: requested)
        }
        asideRefreshTask = Task { [weak self] in
            let replacement = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, asideLifetime == lifetime, documentURL == origin,
                  asideRefreshRevision == revision, requestedPalette == requested,
                  let current = aside, current.id == source.id, current.text === source.text else { return }
            aside = EPUBAside(id: current.id, document: current.document, chapter: current.chapter, title: current.title, text: replacement.text,
                              palette: requested, target: current.target, targetIsMatch: current.targetIsMatch,
                              query: current.query)
            asideRefreshTask = nil
        }
    }

    func closeAside() {
        asideOpenTask?.cancel()
        asideOpenTask = nil
        asideOpenRevision &+= 1
        invalidateAsideRefresh()
        aside = nil
    }

    /// A link inside a supplement: another place in the book closes the
    /// supplement and goes there (or opens the other supplement). Returns
    /// whether the link was the book's.
    func followAsideLink(_ url: URL) -> Bool {
        guard url.scheme == EPUBBook.internalLinkScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              let chapter = book?.chapters.firstIndex(where: { $0.path == path }) else { return false }
        if !pagination.isExcluded(chapter) { closeAside() }
        jumpToLink(chapter: chapter, fragment: components.fragment)
        return true
    }
}
