# Dragging Markdown blocks

Hover over a block to reveal its six-dot handle, then drag the handle to a visible drop line. Code blocks and Mermaid diagrams reveal their handles on hover without entering source editing first. Heading handles appear with their fold chevrons.

Each move carries the whole block: a paragraph, quote, consecutive list group, table, image, code block, display formula, Mermaid diagram or divider. Images can also be dragged by their rendered body.

## Headings and collapsed sections

An expanded heading moves only its heading text. Collapse a heading first to move its entire section, including hidden tables, paragraphs and nested headings. The section ends before the next heading of equal or higher rank, or at the end of the note.

The moved section stays collapsed. Nested headings retain their individual fold choices, so expanding the parent restores the same nested view. See [heading folding](heading-folding.md) for the summary-row setting and folding shortcuts.

## Copying and Undo

Hold Option while dragging to duplicate a block. A drop into another editor copies the block, leaving the original in place. Copied collapsed sections retain their fold choices. Image references are adjusted for the destination note’s folder.

One Undo restores the move or removes the copy; Redo applies it again. Nested and unrelated fold choices are preserved through a collapsed-section move and its Undo/Redo. Comments inside moved blocks travel with their content.

Drop lines appear at visible block boundaries. Expand a section before dropping inside its hidden content. Folding itself stays session-only and does not change the Markdown file or add a text Undo step.
