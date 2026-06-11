# Glass stays per-surface (no GlassEffectContainer) and warm tabs stay live (no freeze)

Status: accepted

Two decisions from the June 2026 whole-app performance investigation, both resolving
the same way: keep the current look and behavior exactly; take performance wins only
where they are invisible.

## 1. No `GlassEffectContainer` / `glassEffectUnion`

Apple's macOS 26 guidance is to merge nearby Liquid Glass surfaces into containers
(one backdrop sample instead of N; glass cannot sample glass). PageFlow renders each
chrome surface — tab pills, toolbar panel, sidebars, page indicator — as its own
glass. We evaluated containers for the tab strip and **rejected them**: within a
container, shapes that approach each other visually meld (Apple's intended behavior),
which changes the tab strip's look during reorder. The owner wants the resting and
dragging look exactly as-is.

**Sanctioned alternative for drag cost:** while a tab drag is active, pills drop to
the flat opaque content-card surface (matching the drag pill) and glass returns on
drop — `TabItemView.isDragInProgress`. The floating drag pill itself is permanently
opaque for the same reason (live glass re-samples its backdrop per cursor move).

## 2. Inactive warm tabs stay live

The warm-tab set (up to `TabManager.maxRenderedTabs` mounted tabs) runs the full
Projector + ingest for inactive tabs on every update. We evaluated freezing inactive
tabs (skip projection/ingest, reconcile once on activation) and the owner **rejected
it** — inactive tabs remain fully live; `isHidden` on the inactive `PDFViewHost`
(which removes AppKit hit-testing and display cost) is the only gating.

## Consequences

- Future performance reviews must not re-propose glass containers, glass unions,
  warm-tab freezing, or projector gating on `isActive` without new evidence (e.g.
  a measured regression attributable to these specifically).
- The per-surface glass cost and inactive-tab projection cost are accepted,
  documented baseline costs.
- Known OS-level cost rider: macOS 26 PDFKit runs Vision-based page analysis per
  live `PDFView` with no opt-out — one more reason the warm cap stays small.
