# PageFlow Context

PageFlow is a macOS PDF viewer (SwiftUI + AppKit + PDFKit). This glossary captures the
domain language for how the app drives Apple's `PDFView`, sharpened during the
PDF View State refactor.

## Language

### Viewing state

**PDF View State**:
The desired viewing parameters for a document — current page, scale (zoom), display mode,
and any pending fit. Owned by **PDFManager**; the live `PDFView` is a projection of it.
_Avoid_: "view model", "PDF config".

**Projector**:
The single function that reconciles the live `PDFView` with the **PDF View State**, applying
changes in the required order (display mode → scale → page) and skipping writes already
satisfied (scale compared with a relative tolerance). It is the only *reconciler* of durable
**PDF View State** onto the view — but not literally the only writer: two interactive paths
write the view directly and by design (see **Direct view writes**).
_Avoid_: "sync", "updater"; and the claim that it is the *only writer* of the view (it is the
only reconciler — two documented exceptions write directly).

**Direct view writes** (documented exceptions):
The two interactive paths that write the live `PDFView` directly rather than through the
**Projector**, because each needs a same-event change the durable **PDF View State** does not
model:
- *Control-scroll zoom* sets `autoScales`, `scaleFactor`, and the scroll origin together in one
  event so the point under the cursor stays fixed. It writes the manager's `scale` as the
  source of truth first, then the view. (ADR-0001.)
- *Search-result navigation* calls `go(to:)` / `setCurrentSelection` to reveal and highlight a
  hit. (Routing this through `pendingNavigation` is a possible future cleanup; ADR-0001.)
These exceptions are why the Coordinator keeps `scrollApplyToken` and the search-navigation
counters: guards that keep the **Projector** and the direct writers from fighting.
_Avoid_: adding a new direct writer without recording it here and keeping the **Projector**'s
scope narrowed to *reconciling durable state*.

**Ingest** (typed event):
The path by which user-originated `PDFView` changes (control-scroll zoom, context-menu mode
switch, PDFKit page changes) are folded back into **PDFManager** as typed events, deferred to
the next runloop turn. A notification is a request to update intent, never a direct commit.
_Avoid_: "callback", "notification handler" (too generic).

**Fit Engine**:
The pure, display-mode-aware calculation that turns a geometry snapshot (**Fit Inputs**) into
a fit-to-view scale. Holds the four-branch fit formula; takes no live `PDFView`.
_Avoid_: "fit calculator", "auto sizer".

**Fit Request**:
A transient, one-shot command to fit the current page to the view (replacing the old
`fitOnceRequested` flag). Carries whether to scroll to the page top. Cleared once the
**Projector** applies it.
_Avoid_: "fit mode", "fit state" (it is not durable).

**Auto-Scale**:
A distinct, user-toggled mode that hands sizing to PDFKit's native `autoScales` (which refits
on window resize). Separate from a **Fit Request**: Auto-Scale is durable and PDFKit-driven;
a Fit Request is a one-shot we compute ourselves.
_Avoid_: conflating with **Fit Request**.

### Navigation & page editing

**Navigation History**:
The back/forward page stacks behind PDFManager's Back/Forward, extracted as the pure value type
`NavigationHistory` (depth-capped; a fresh jump clears the forward stack). PDFManager owns one and
forwards `canGoBack`/`canGoForward`/`pushNavigationState`/`goBack`/`goForward`/`clearNavigationHistory`
to it, applying the returned target via the page state. Pure, so the stack behaviour is unit-tested
without a view. SwiftUI still invalidates on change because the stored `var` is the observed property
(same pattern as **TabSession**'s `uiState`).
_Avoid_: external readers of the raw stacks; duplicating the depth/forward-clear rules elsewhere.

**Page-index math**:
The pure arithmetic (`PageIndexMath`) for where the current page lands after a structural edit —
the off-by-one shifts on delete/duplicate/move that were the bug-prone part of PDFManager's page
operations. Only the *index decision* is extracted and exhaustively tested; the effectful
orchestration (PDFKit mutation, undo, dirty/`pageVersion` bumps, the page-mutation fan-out to the
bookmark/comment managers) stays in PDFManager, the source of truth.
_Avoid_: a separate page-operations "mutator module" — the ops are too coupled to observable view
state for that to simplify anything (ADR-0003).

**Visible edit**:
An in-place, page-level edit that changes what a page renders without changing document
structure — annotation/comment add, remove, recolor. Recorded through one fan-in,
`PDFManager.noteVisibleEdit(on:)`, which marks the document dirty and invalidates the page's
rendered artifacts (`pageVersion` for live views, the page's thumbnail). Structural page
edits (insert/delete/move) use `markThumbnailStructureDirty` instead. Deliberate deviations
stay inline at their call sites: a text-only comment edit marks dirty without re-render;
annotation removal bumps `pageVersion` without dirtying on its undo path.
_Avoid_: re-pasting the dirty/`pageVersion`/thumbnail triple at call sites; folding the
deviating sites into the fan-in.

### Tab architecture

**TabSession**:
The owned, lifecycle-bearing bundle of one tab's collaborating managers — PDF, search,
annotation, comment, bookmark, undo — plus that tab's UI state, pending unlock request, and
**view snapshot** (the page/zoom/search captured on switch-away and re-applied on re-activation).
Created once per open tab, cleaned up on close, and moved as a single unit between windows. The
**PDF View State** (Projector/Ingest) lives inside its `pdfManager`. The session wires its
page-mutation fan-out and undo-availability observers once, in its init, and tears them down in
one `cleanup()`. The view snapshot is in-memory and per-activation — *not* the cross-launch
reading-position persistence (`DocumentStateStore`), and *not* the durable **PDF View State**.
_Avoid_: "Context"/"TabContext" (collides with `@Environment`/`NSManagedObjectContext`, and
connotes a passive data bag), "Coordinator", "Controller".

**TabManager**:
The per-window coordinator. Owns the tabs and exactly one **TabSession** per tab in a single
`[UUID: TabSession]` — never parallel per-tab dictionaries. Also holds window-singleton state:
the **Unlock Queue**, the edit-mode key monitor, the open panel, and always-on-top.
_Avoid_: putting per-tab runtime state directly on the manager.

**Unlock Queue**:
The window-level FIFO of tab ids waiting for the single password sheet; the head is the prompt
currently presented. The unlock *payload* (url, security scope, cancel behavior) lives on each
**TabSession** as `pendingUnlock` and rides along on tear-off — the queue carries only order.
_Avoid_: storing the request payload on the window (it would have to be hand-copied on every move).

### UI surfaces

**Liquid Glass (chrome)**:
The translucent navigation material — toolbar, tab strip, traffic-light cluster, and the
sidebar *panels*. Glass is a chrome layer only: it floats above content and is never placed
directly behind body text. Backed by `.glassEffect` / `NSGlassEffectView` on macOS 26+ and an
`NSVisualEffectView` fallback (`HUDGlassFill`) on macOS 15–25.
_Avoid_: putting reading content (comment text) on glass.

**Content card**:
An opaque surface that body text rides on — e.g. a comment bubble. To stay consistent with
PageFlow's *fixed* light-frosted glass chrome, the card is opaque white carrying the same dark
`glassTextPrimary` text the rest of the chrome uses — **not** an appearance-adaptive surface
(`controlBackgroundColor`/`.labelColor` resolve dark in the viewer's dark appearance context
and clash with the light chrome). The companion to **Liquid Glass (chrome)**: glass for chrome,
content cards for text. Stacking a translucent bubble on the translucent sidebar (glass-on-glass
behind text) is what made comments unreadable.
_Avoid_: "glassmorphic bubble" for any text-bearing surface; appearance-adaptive colors that
fight the fixed light-frosted chrome.

**Rail Follow (keep-visible)**:
How the Thumbnails rail tracks the document while reading. The rail highlights the current
page and repositions **only** when that page would leave the rail's visible band, bringing it
back with headroom (so it sits still for many pages between moves) — Apple Preview's model. It
does **not** continuously mirror the PDF's scroll offset. Driven by the discrete current page,
not a per-frame scroll fraction; the reposition is instant (an animated scroll is deferred
during the PDF scroll gesture's event-tracking run loop). Continuous 60 Hz mirroring through
SwiftUI `ScrollPosition` was tried and rejected: it re-ran the whole rail body every frame and
lagged the gesture. The reposition *decision* (page moved from, page moved to, the set of
visible pages → a reposition target + anchor, or no-op) lives in the pure `RailFollow` module
so it is unit-testable in isolation; the view performs the resulting instant `scrollTo`.
_Avoid_: "continuous scroll mirroring" / "minimap sync" for the rail; binding a live scroll
fraction to the rail's scroll offset.

**Shared updater**:
The single app-wide `UpdateManager` (one `SPUStandardUpdaterController`), injected into the
menu and the Settings toggle. The "check for updates automatically" preference is owned and
persisted by Sparkle itself — the UI binds straight to it and keeps no mirrored copy. A second
updater instance, or a local `@State` mirror, is what made the toggle "turn itself off."
_Avoid_: a second `SPUStandardUpdaterController`; a separate UserDefaults key for auto-check.

### Export

**Markdown export (adapter + pure layout)**:
Turning a page into Markdown is split across a **seam**. `MarkdownExporter` is the PDFKit
*adapter*: it reads a live `PDFPage`'s attributed text, per-line positions, and link targets,
and nothing more. `MarkdownLayout` is the *pure pipeline*: it turns those extracted inputs into
Markdown and holds every heuristic — two-column detection/reordering, heading-by-font-size,
monospace code-block fencing, list detection, comment-to-line mapping, output cleanup, link
application. `MarkdownLayout` never touches PDFKit, so the heuristics (and their tuned
thresholds) are unit-tested from a synthetic `NSAttributedString` + positions with no rendered
PDF.
_Avoid_: reaching into a live `PDFPage` from `MarkdownLayout`; duplicating the heuristics at
call sites; a single fused `export(document:)` that mixes extraction with formatting.

**Outline section (boundary)**:
The page range a sidebar outline entry covers: from its own page up to its immediate next
sibling's page, else to the end of the document. The boundary (`nextSiblingPageIndex`) is
linked once when the outline tree is built (`OutlineItem.buildRoot`, the single construction
path), so callers — e.g. **Markdown export**'s section scope — get the range from the item
alone: `ExportScope.outlineSection(OutlineItem)` carries no sibling array.
_Avoid_: threading sibling arrays through `ExportScope` or re-deriving boundaries at call
sites; looking past the immediate next sibling when linking.

## Relationships

- **PDFManager** owns the **PDF View State**; the live `PDFView` is its projection.
- The **Projector** reconciles **PDF View State** onto the `PDFView`; **Ingest** reads the
  `PDFView` and writes **PDF View State**. Together they form one unidirectional loop for
  durable state, with the **Projector** as the sole reconciler — except the two **Direct view
  writes** (control-scroll zoom, search-result navigation), which write the view directly by
  design.
- A **Fit Request** is resolved by the **Projector** using the **Fit Engine**, then cleared.
- **Auto-Scale** bypasses the **Fit Engine** (PDFKit computes the scale); the **Projector**
  picks exactly one sizing owner per pass: Auto-Scale *or* an explicit scale.
- A **TabManager** owns one **TabSession** per tab; the session is the single source of truth for
  per-tab runtime state and the unit moved between windows. Detach/attach is a single
  `sessions.removeValue` / `sessions[id] = session`, so managers, undo history, and observers
  transfer atomically.
- Per-tab/per-document state (managers, UI state, `pendingUnlock`, the tab-activation view
  snapshot) lives in the **TabSession** and travels on tear-off; window-singleton presentation
  (the **Unlock Queue**, key monitor, open panel, always-on-top) stays on **TabManager**.
- Undo availability is cached on the **TabSession** and refreshed by observers bound to the
  session's own `undoManager`, so it survives a window move without reinstalling anything.

## Example dialogue

> **Dev:** "When the user picks Two-Up from the context menu, who updates the display mode?"
> **Maintainer:** "PDFKit changes the live view and posts a notification. We **Ingest** that as
> a typed event and update the **PDF View State**'s display mode — we don't write the view back.
> The **Projector** sees view and intent already agree, so it does nothing."
> **Dev:** "And the re-fit after the mode change?"
> **Maintainer:** "That's a **Fit Request**, resolved through the **Fit Engine** for the new
> mode. One-shot — not **Auto-Scale**, which is the separate PDFKit-driven mode."

## Flagged ambiguities

- "Fit" was used for two different things: the one-shot **Fit Request** (our computed fit) and
  **Auto-Scale** (PDFKit's continuous mode). Resolved: these are distinct and must not be merged.
- "scale" — the durable desired zoom on **PDFManager**, mirrored onto `PDFView.scaleFactor`.
  The **Projector** treats the manager value as authoritative.
- Password presentation vs. ownership: tearing off a tab mid-unlock moves its `pendingUnlock`
  with the **TabSession** and re-queues it in the destination window; the source window's sheet
  simply stops presenting it (no explicit dismiss). Resolved for now — the payload is per-tab and
  follows the tab; presentation is derived from the **Unlock Queue** head. Any change to dismissal
  timing is separate work.
