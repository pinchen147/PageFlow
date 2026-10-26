//
//  MarkdownFormat.swift
//  MarkdownEngine
//

/// A formatting command a host applies to the editor's selection through
/// ``MarkdownEditorController/apply(_:)``. Each is one undoable source edit.
public enum MarkdownFormat: Equatable, Sendable {
    case bold
    case italic
    case underline
    /// `~~text~~`.
    case strikethrough
    /// `==text==` (the reference editor's highlight).
    case highlight
    /// Normal text: removes heading markers from every selected line.
    case paragraph
    /// An ATX heading (`#`…`######`) on every selected line (the reference editor's setBlock).
    case heading(level: Int)
    /// Toggles `- ` on every selected line.
    case bulletedList
    /// Toggles `1. `, `2. `… on every selected line.
    case numberedList
    /// Toggles `- [ ] ` on every selected line.
    case checklist
    /// Indents the selected list items one level.
    case indent
    /// Outdents the selected list items one level.
    case outdent
    /// Toggles `> ` on every selected line.
    case quote
    /// Toggles backticks around the selection (a fence around several lines).
    case code
    /// Toggles a fenced code block around the selected lines.
    case codeBlock
    /// `[ ]` ↔ `[x]` on the selected checklist lines.
    case toggleChecked
    /// Inserts a divider (`---`) after the caret's line.
    case divider
    /// Inserts an empty 3 × 3 table with a header row and edits its first cell.
    case table
    /// Wraps the selection as a link and puts the caret where typing continues.
    case link
}
