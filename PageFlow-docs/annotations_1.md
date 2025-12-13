# Annotation, Underline, Bookmark, and Comment Implementation Plan (Apple PDFKit)

Scope: Implement F012–F019 (highlights/underlines), F020–F023 (bookmarks), F024–F028 (comments) using supported Apple PDFKit APIs (no deprecated classes). Keep architecture minimal, robust, and consistent with existing PageFlow patterns (@Observable managers, DesignTokens, glass UI). No autosave; mark dirty on mutations to align with future save flows.

## Architecture

- **Managers (new)**
  - `AnnotationManager`: selection-based highlight/underline CRUD; tracks active color/preset; sets `pdfManager.isDirty = true` on changes.
  - `BookmarkManager`: per-document bookmarks (title, pageIndex, date); in-memory first; optional sidecar persistence later.
  - `CommentManager`: text comments anchored to pages/selections via PDFText annotations; marks dirty on change.
- **Views (new)**
  - `AnnotationToolbar` (buttons for highlight/underline/default/presets/custom color, delete/recolor).
  - `BookmarkSidebar` (list/navigate/rename/delete).
  - `CommentsSidebar` (list/navigate/edit/delete).
  - `ColorPickerView` (presets + custom RGB).
- **Bridging**
  - `PDFViewWrapper` Coordinator exposes:
    - `currentSelection` and `currentPage`.
    - `selectedAnnotation` via hit-test (convert view point to page and call `page.annotation(at:)`).
    - A closure for managers to fetch selection/page on demand.
  - Annotations created with `PDFAnnotation(bounds:forType:withProperties:)` using subtypes `.highlight`, `.underline`, `.text` and setting `markupType`/`quadrilateralPoints` for markup.

## Highlights (F012–F016)

- Use `PDFAnnotation` (not deprecated `PDFAnnotationMarkup`) with subtype `.highlight`, plus `markupType` and `quadrilateralPoints` to cover multi-line selections as a single annotation.
- Default: `.highlight`, color `DesignTokens.highlightYellow` (alpha ~0.4).
- Presets: DesignTokens highlight colors; Custom RGB via `ColorPickerView`.
- Remove: remove the selected annotation (`page.removeAnnotation`).
- Recolor: update `annotation.color`.
- Implementation steps:
  - Get `selection` and `page`; compute the union of all line rects (`selection.bounds(for: page)`) for the annotation `bounds`.
  - Create `PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)` and set `annotation.markupType = .highlight`.
  - Build `quadrilateralPoints` from `selection.selectionsByLine()`: for each line rect, create four points (TL, TR, BL, BR) in page coordinates (origin bottom-left), offset them relative to the union bounds’ origin, and assign as `[NSValue]` to `annotation.quadrilateralPoints` (points must be relative to the annotation’s bounds).
  - Set color; add to page via `page.addAnnotation`; mark dirty; track `selectedAnnotation` via hit-test.

## Underlines (F017–F019)

- Same flow as highlights but use `PDFAnnotation` subtype `.underline` with `markupType = .underline` and `quadrilateralPoints`.
- Default color: `DesignTokens.underlineColor` (alpha as needed).
- Remove/recolor: same as highlights.

## Bookmarks (F020–F023)

- Model: `{ id: UUID, page: PDFPage?, title: String, createdAt: Date }` with a computed `pageIndex` for UI (`doc.index(for: page)+1`). Using a weak page reference avoids index drift during a session. For persistence, store page index and resolve on load; consider `PDFOutline.insertChild` if cross-app sharing is desired.
- Add: use current page; default title “Page X”.
- View: `BookmarkSidebar` (navigate via `pdfManager.goToPage` using the page or resolved index).
- Rename/Delete: inline editing/remove.
- Persistence: Phase 1 in-memory; later sidecar JSON keyed by document URL (and file fingerprint when available).

## Comments (F024–F028)

- Single source of truth: derive comments from the `PDFDocument` by filtering annotations of subtype `.text` on each page (no drifting arrays).
- Add: create `PDFAnnotation` of type `.text` anchored near selection or page center; set `contents`, `iconType` (e.g., `.comment`), color from DesignTokens; add to page via `addAnnotation`; mark dirty.
- View/edit/delete: via sidebar or annotation tap; update `contents` or remove annotation.
- List all: `CommentsSidebar` iterates current document annotations (subtype `.text`) with pageIndex + rect for navigation.

## UI Integration

- Toolbar: add buttons for Highlight, Underline, Color presets/custom, Delete/Recolor (if selection/annotation exists). Respect DesignTokens sizes and spacing; no autosave.
- Sidebars: glass styling (ultraThinMaterial + tint + border + shadow) consistent with existing components. Toggle via toolbar; push-layout with overlay shift (current pattern).
- Dirty indicator: already present in TabBar; ensure managers set `pdfManager.isDirty = true` on mutations; clearing on save is already implemented.
- Saving: no autosave. Annotations/underlines/bookmarks/comments must set `pdfManager.isDirty = true`; users trigger Save/Cmd+S or Save As/Cmd+Shift+S (see docs/save.md for flow). Save clears dirty; Save As updates URL and title. If Save As remains broken, ensure a defensive code path before wiring annotations.

## Safety & Reliability (Apple PDFKit specifics)

- Guards: require both `PDFSelection` and `PDFPage`; early-return otherwise.
- Multi-rect selections: use `selection.selectionsByLine()` to avoid spanning multiple lines with one rect.
- Alpha: use DesignTokens opacity (e.g., 0.4) for highlights; underline color with suitable alpha.
- Selection safety: `PDFView.currentSelection` is a live object—call `copy()` before you mutate it.
- Threading: all mutations on main thread.
- Hit-testing: convert view points to page space (`pdfView.convert(_, to: page)`) and call `page.annotation(at:)` to set `selectedAnnotation` for delete/recolor.
- Security-scoped: no change; saving handled by existing save/saveAs.

## Minimal APIs to Add

### AnnotationManager
- `func highlightSelection(color: NSColor)` using `PDFAnnotation` (.highlight) + `markupType` + `quadrilateralPoints`
- `func underlineSelection(color: NSColor)` using `PDFAnnotation` (.underline) + `markupType` + `quadrilateralPoints`
- `func removeSelectedAnnotation()`
- `func updateSelectedAnnotationColor(_ color: NSColor)`
- `func setSelectionProvider(_ provider: @escaping () -> (PDFSelection?, PDFPage?))`
- `func setAnnotationProvider(_ provider: @escaping () -> PDFAnnotation?)`
- `@MainActor` on mutation methods (add/remove/update) to keep UI-safe.

### BookmarkManager
- `func addBookmark(title: String?, page: PDFPage)`
- `func deleteBookmark(id: UUID)`
- `func renameBookmark(id: UUID, title: String)`
- `var bookmarks: [BookmarkModel] { get }`
- `func resolvePageIndex(for bookmark: BookmarkModel, in document: PDFDocument) -> Int?`

### CommentManager
- `func addComment(text: String)`
- `func editComment(id: UUID, text: String)`
- `func deleteComment(id: UUID)`
- `var comments: [CommentModel] { get }` (store pageIndex + rect + annotation ref if needed)

### PDFViewWrapper Coordinator
- Expose `currentSelection`, `currentPage`.
- Hit-test helper: `annotation(at point: CGPoint, page: PDFPage) -> PDFAnnotation?`.
- Provide selection/page closures to managers.

## UI Hooks

- FloatingToolbar: buttons (Highlight default, Underline default, Preset colors dropdown, Custom color, Delete/Recolor).
- Sidebars: Bookmarks, Comments with glass styling; toggles similar to Outline; push-layout with overlay offset.

## Out of Scope (for now)

- Auto-save (per user: none).
- Persistence for bookmarks/comments (Phase 2 sidecar).
- Undo/redo (Phase 9 per PRD; keep mutations centralized to ease future work).
