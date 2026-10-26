//
//  TabRender.swift
//  PageFlow
//
//  The view-layer projection types a TabManager exposes to the window: a PDF tab's
//  runtime bundle, a Markdown tab's live content handle, and the content-
//  discriminated render unit the mount sites switch over.
//

import Foundation

struct TabRuntime {
    let tabID: UUID
    let pdfManager: PDFManager
    let searchManager: SearchManager
    let annotationManager: AnnotationManager
    let commentManager: CommentManager
    let bookmarkManager: BookmarkManager
    let undoManager: UndoManager
}

/// The view-layer projection of a Markdown tab: the stable tab id plus the live
/// `MarkdownContent` backend the editor binds to. Peer of `TabRuntime`, but the
/// markdown editor needs only the durable document + controller, not a PDF
/// manager bundle.
struct MarkdownRuntime: Identifiable {
    let tabID: UUID
    let content: MarkdownContent
    var id: UUID { tabID }
}

/// The content-discriminated unit the window iterates to mount a tab's view: a
/// PDF runtime drives `PDFTabView`, a markdown runtime drives `MarkdownTabView`.
/// The single switch the view layer makes — so a future content type is a
/// compile error at every mount site, never a silent fallthrough.
enum TabRender: Identifiable {
    case pdf(TabRuntime)
    case markdown(MarkdownRuntime)

    var id: UUID {
        switch self {
        case .pdf(let runtime): return runtime.tabID
        case .markdown(let runtime): return runtime.tabID
        }
    }
}
