# Page operations stay in PDFManager (no separate mutator module)

Status: accepted

PDFManager's page operations (copy / cut / paste / delete / duplicate / move / rotate, ~220 lines)
are tempting to extract into a standalone `PageEditor` / mutator module. We decided not to: the
operations are too coupled to PDFManager's `@Observable` state to extract cleanly, so a module would
be indirection over destructive code rather than simplification.

## Why

Each operation must, in one synchronous step: mutate the `PDFDocument`; adjust `currentPageIndex` +
`currentPage` (with per-op shift math); set `isDirty`; bump `pageVersion`; invalidate thumbnail
versions (`markThumbnailStructureDirty` / `markThumbnailDirty`); fire `pageMutationHandler` so the
Bookmark and Comment managers reconcile their page indices; and register undo whose closures
*re-enter PDFManager* to form the redo chain (delete↔`insertPageForUndo`, duplicate↔`removePageForUndo`,
move↔move, rotate↔rotate). A separate module would have to hand all of that state back to PDFManager
and call back into it for undo — more surface, not less, on code that destructively edits the document.

## What we did instead

Extracted the two genuinely separable pure parts and pinned the rest with tests:

- `NavigationHistory` — the back/forward stacks as a value type (clean: no external readers, no
  observable-state coupling). This precedent does *not* generalize to page operations.
- `PageIndexMath` — the bug-prone current-page-index shift arithmetic (delete/duplicate/move), as
  pure functions tested across every branch.
- Characterization tests (`PageOperationTests`) pinning the full operations: undo round-trips,
  `isDirty`, `pageVersion`, the mutation fan-out, and post-op index correctness.

The effectful orchestration stays in PDFManager, the source of truth for **PDF View State**.

## Consequences

- Page operations remain in PDFManager; future architecture reviews should not re-propose a mutator
  module.
- The risky arithmetic is isolated and exhaustively tested; the destructive ops have a regression net.
