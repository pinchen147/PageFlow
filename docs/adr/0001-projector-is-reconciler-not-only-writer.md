# Projector is the only *reconciler* of PDF View State, not the only *writer* of the view

Status: accepted

CONTEXT.md described the **Projector** as "the only writer to the live `PDFView`," but the code
has always had two interactive paths that write the view directly: control-scroll zoom (sets
`autoScales` + `scaleFactor` + scroll origin together in one event so the point under the cursor
stays fixed) and search-result navigation (`go(to:)` / `setCurrentSelection` to reveal and
highlight a hit). We decided to keep those direct writes and narrow the documented invariant to
"the Projector is the only *reconciler* of durable **PDF View State**," rather than force every
write through the Projector.

## Considered options

- **Force all writes through the Projector (literal single writer).** Rejected: zoom-under-cursor
  needs a same-event scale + scroll-offset change that the durable **PDF View State** does not
  model. Routing it through durable state would either lose the cursor anchor or require modelling
  transient scroll offset in the manager — a larger, riskier change to a piece of live PDFKit code
  that has no test net.
- **Leave the docs claiming "only writer" (status quo).** Rejected: the claim is false as
  implemented and misleads the next refactor (it implies the guard state — `scrollApplyToken`, the
  search-navigation counters — is redundant when it is in fact load-bearing).

## Consequences

- The two exceptions are now named in CONTEXT.md under **Direct view writes**; adding a third
  requires recording it there.
- The guard state that keeps the Projector and the direct writers from fighting is explained, not
  mysterious.
- Routing *search* navigation through `pendingNavigation` (so only control-scroll stays direct)
  remains a reasonable future cleanup — it is not done here because this pass is strictly
  no-behavior-change.
- A June 2026 verification pass confirmed that cleanup is *not* behavior-preserving as a
  mechanical refactor: `go(to: PDFSelection)`'s minimal-reveal scroll differs from the
  projector's destination scroll (which also re-applies after the layout-settle delay); the
  wrapper's `updateNSView` is not a legal place to arm observable state; and routing via
  `goToDestination` would start recording Back-history per search hop. Doing it requires a
  behavior-aware change (e.g. a `pendingSelectionReveal` one-shot armed at the command layer,
  applied by the projector without the settle retry) plus manual QA of search landings.
