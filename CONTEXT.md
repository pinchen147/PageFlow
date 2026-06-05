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
The single function that writes the live `PDFView` to match the **PDF View State**, applying
changes in the required order (display mode → scale → page) and skipping writes already
satisfied (scale compared with a relative tolerance). The only writer to the live view.
_Avoid_: "sync", "updater".

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

### Tab architecture

**TabSession**:
The owned, lifecycle-bearing bundle of one tab's collaborating managers — PDF, search,
annotation, comment, bookmark, undo — plus that tab's UI state and pending unlock request.
Created once per open tab, cleaned up on close, and moved as a single unit between windows. The
**PDF View State** (Projector/Ingest) lives inside its `pdfManager`. The session wires its
page-mutation fan-out and undo-availability observers once, in its init, and tears them down in
one `cleanup()`.
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

## Relationships

- **PDFManager** owns the **PDF View State**; the live `PDFView` is its projection.
- The **Projector** reads **PDF View State** and writes the `PDFView`; **Ingest** reads the
  `PDFView` and writes **PDF View State**. Together they form one unidirectional loop with a
  single writer on each side.
- A **Fit Request** is resolved by the **Projector** using the **Fit Engine**, then cleared.
- **Auto-Scale** bypasses the **Fit Engine** (PDFKit computes the scale); the **Projector**
  picks exactly one sizing owner per pass: Auto-Scale *or* an explicit scale.
- A **TabManager** owns one **TabSession** per tab; the session is the single source of truth for
  per-tab runtime state and the unit moved between windows. Detach/attach is a single
  `sessions.removeValue` / `sessions[id] = session`, so managers, undo history, and observers
  transfer atomically.
- Per-tab/per-document state (managers, UI state, `pendingUnlock`) lives in the **TabSession** and
  travels on tear-off; window-singleton presentation (the **Unlock Queue**, key monitor, open
  panel, always-on-top) stays on **TabManager**.
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
