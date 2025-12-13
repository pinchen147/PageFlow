# Comments Implementation Plan (PDFKit)

This outlines the approach for adding PDF comments (sticky notes) with a translucent grey highlight and a right-side glassmorphic sidebar.

## Goals
- Add, edit, delete, and view comments anchored to text selections or page locations.
- Persist comments in the PDF (annotation of subtype `.text`) with a paired grey highlight (subtype `.highlight`).
- Surface comments in a glass sidebar on the right; toggle via toolbar button and Cmd+E.

## Architecture
- `CommentModel`: Identifiable model `{ id, text, pageIndex, bounds, createdAt }`.
- `CommentManager` (`@Observable`, `@MainActor`):
  - Configured with `pdfManager` and a selection provider `(PDFSelection?, PDFPage?)`.
  - Holds `comments`, `selectedCommentID`, `editingCommentID`, `annotationMap: [UUID: PDFAnnotation]`.
  - Marks `pdfManager.isDirty = true` on mutations.
  - Undo/redo registered via `NSUndoManager`.
- `PDFViewWrapper`:
  - Supplies selection/page to `CommentManager`.
  - On document change: loads or clears comments via `commentManager.loadComments(from:)`.
- `CommentsSidebar`:
  - Right-aligned glass panel; speech-bubble rows; lists comments sorted by `createdAt`.
  - Allows select → jump to page, edit text, delete.
- Toolbar:
  - Cmd+E: add comment.
  - Buttons: add comment (text.bubble), toggle sidebar (bubble.right/bubble.right.fill).

## Comment Creation Flow
1) Capture selection/page from provider.
2) Determine anchor bounds:
   - If selection exists: use `selection.bounds(for: page)` and quad-points from `selectionsByLine()`.
   - Else: use a small centered rect on the page (e.g., 140×32 in media box).
3) Create highlight annotation:
   - `PDFAnnotation(bounds: ..., forType: .highlight, ...)`
   - `color = DesignTokens.commentHighlightColor` (grey @ ~0.6 alpha)
   - `quadrilateralPoints`: from line rects; fallback to bounds.
   - `userName = commentID.uuidString` to link comment ↔ highlight.
4) Add highlight to page; store in `annotationMap`.
5) Append `CommentModel`, select + set editing; mark dirty.
6) Register undo for add.

## Edit/Delete
- Edit: update `CommentModel.text`, assign to `annotation.contents`, mark dirty, register undo.
- Delete: remove annotation from page, drop model/map, clear selection if needed, mark dirty, register undo.

## Persistence
- `loadComments(from:)`: iterate pages, filter annotations of type `"Highlight"` matching grey color heuristic; reconstruct models from `userName`, `contents`, `bounds`, `pageIndex`; repopulate `annotationMap`.
- Save uses existing PDFManager save logic (`dataRepresentation` → write).

## UI/UX
- Sidebar width via `DesignTokens.commentSidebarWidth`; glassmorphic background lighter than outline.
- Speech bubbles with tail; slightly translucent fill/border.
- Empty state instructs: “Select text and press ⌘E”.

## Shortcuts & Toggles
- Cmd+E: add comment.
- Toolbar button: add comment.
- Toolbar button: toggle comments sidebar.

## Safety
- Guards on selection/page/document; fallback anchor when no selection.
- Main-thread mutations (`@MainActor`).
- Undo/redo via `NSUndoManager`.
- Dirty flag set on all mutations.
