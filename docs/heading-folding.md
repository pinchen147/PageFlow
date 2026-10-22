# Heading folding

Headings with nonblank content can collapse their section. Click the gutter chevron or use **Option-Command-Return** from a heading or anywhere inside its section. **View → Folding** also offers Collapse All and Expand All. All three commands can be rebound in Settings → Shortcuts; the bulk commands have no default keys.

Hovering anywhere across a heading, including wrapped lines, reveals its gutter chevron and drag handle together, whether the section is expanded or collapsed. The 24-point button has rounded corners and a subtle hover fill. The chevron and collapsed summary row use the pointing-hand cursor when clickable.

A section ends before the next heading at the same or a higher level. Folding a parent preserves its descendants' choices. Whitespace-only sections have no disclosure. Supported heading syntax is the editor's existing ATX `#` through `######` syntax.

The collapsed section shows a quiet gray row across the reading column, with a centered count such as “3 blocks hidden.” Expand appears on hover or keyboard focus. **Settings → General → Markdown → Show hidden-content row** hides that row while keeping folds and chevrons. This preference persists across launches.

The count describes nonblank content blocks, not lines: a paragraph, table, code fence or consecutive list run counts once. Descendant headings count too. Counts reconcile after a typing pause using the canonical parser.

Dragging a collapsed heading moves its entire section, including hidden descendants, and keeps it collapsed at its destination. Nested fold choices travel with it through Undo and Redo. Dragging an expanded heading moves only the heading. Option-drag and cross-document copies carry the same section and fold choices. See [dragging Markdown blocks](block-dragging.md) for all supported blocks and drop behavior.

Fold choices last while the note is open, including switching tabs and moving it between windows. Reopening the file starts expanded. Reloading changed content from disk resets folds; keeping the current content, cancelling a reload or a failed reload preserves them.

Folding leaves the Markdown file and text Undo history unchanged. Copy, Save, recovery and print continue to use complete source. Find, outline and comment navigation reveal the target's ancestors. Ordinary caret arrows skip folded bodies.

For ordinary text edits, deletion and Cut across hidden content, the first action reveals it without editing; a fresh action performs the edit. Holding Delete does not bypass that protection. Explicit folding is refused during composition, Writing Tools, image manipulation and drag tracking; it is never queued to occur later.
