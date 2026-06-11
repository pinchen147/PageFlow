# No generic annotation store across Comment / Annotation / Bookmark managers

Status: accepted

`CommentManager`, `AnnotationManager`, and `BookmarkManager` share a copy-pasted undo + dirty-
marking skeleton (`configure(...)`, `getUndoManager(for:)`, `registerUndoAdd`/`registerUndoRemove`,
`isDirty = true` + `pageVersion += 1`). A tempting refactor is to collapse them onto one generic
`AnnotationStore<T>`. We decided **not** to: the three differ in *storage*, which is the part a
generic store would have to unify, and unifying it would be wrong.

## Why a generic store is the wrong abstraction

- **AnnotationManager** does not own storage at all — annotations live on PDFKit pages
  (`page.addAnnotation`); the manager only drives undo and selection.
- **CommentManager** mirrors live `PDFAnnotation`s into `CommentModel` + a `highlights` map;
  `CommentModel` is not even `Codable`.
- **BookmarkManager** owns plain models persisted to `UserDefaults`.

Folding three storage models behind one generic interface would force a lowest-common-denominator
shape and risks breaking undo identity for live `PDFAnnotation`s. The genuine commonality is only
the undo-registration + dirty-marking ritual.

## Decision

If the duplication is addressed, extract a narrow `UndoableDocumentEdit` / dirty-marking helper
that the three managers call — not a generic store that owns the models. This pass does not even do
that; it is recorded so future architecture reviews don't re-propose the generic store.

## Consequences

- The three managers stay as distinct types over their distinct storage.
- A future "deduplicate the undo ritual" task has a sanctioned shape (a helper, not a store).
