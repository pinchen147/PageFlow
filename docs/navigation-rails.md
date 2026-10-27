# Navigation rails

New in PageFlow 2.1, the marks along the left edge give you quick previews and jumps within the current PDF or Markdown note. The high-contrast marks show the current PDF page or the Markdown sections with visible content.

## PDF pages

Hover over a mark to open a thumbnail panel centered on its page, where the start and end of the document allow. Moving between marks scrolls the same panel to the page under your pointer. Hovering leaves your current PDF page, selection and reading position unchanged.

Click a mark to jump to its page, or move into the panel and click a thumbnail. Back returns to the page you left. Clicking the current page again does not add another Back entry.

### Fitted reading

The PDF rail and its automatic thumbnail preview hide while the PDF is fitted to the window. This includes its initial fit on opening, Zoom to Fit, Auto-Scale and a fit after changing the page layout. A reopened PDF with a saved fixed zoom keeps that manual zoom; a saved Auto-Scale setting keeps the rail hidden.

Use manual zoom, Actual Size, a pinch gesture or Control-scroll to bring the rail back. Turning Auto-Scale off also restores it. Scrolling, page changes, resizing, switching tabs and moving a tab between windows preserve the fitted-reading choice. macOS Full Screen is separate from Zoom to Fit.

## Markdown sections

Each mark represents a heading. Its resting length shows the heading level, with H1 longest and H6 shortest:

| Heading | Resting length |
|---------|----------------|
| H1 (`#`) | 21 points |
| H2 (`##`) | 18 points |
| H3 (`###`) | 15 points |
| H4 (`####`) | 12 points |
| H5 (`#####`) | 9 points |
| H6 (`######`) | 6 points |

These lengths stay the same across notes, including notes that skip heading levels. Hover widens nearby marks without making any shorter than its resting length.

Hover over a mark to see its heading and up to three lines of plain-text content. The excerpt stops at the next heading, including a nested heading. Click the mark or preview card to jump to that heading. Navigation keeps your caret, selection and text Undo history, reveals folded ancestors when needed, and records the departure for Back. Notes without supported headings have no rail.

## Previews and manual sidebars

Move from the rail into its preview across the small gap to keep it open. A passive preview closes promptly when the pointer leaves both areas. Keyboard or accessibility interaction can keep a preview open while it is in use. Escape closes a preview when a menu or active text composition is not using the key.

In long documents or short windows, one mark can represent several consecutive pages or headings. Its preview and click both use the first member of that group. A grouped Markdown mark also uses that heading's level for its length.

For access to every page or heading, open the manual sidebar from the toolbar or View menu, or press **Option-Command-S** with the default shortcuts. It stays open until you close it and hides the rail while open. Keyboard and accessibility activation of the rail also open the manual sidebar.

**Settings → General → Navigation → Show navigation rail** is on by default. Turning it off hides both PDF and Markdown rails and their transient previews. The preference persists across launches, and manual sidebar access remains available, including while a PDF is fitted to the window.
