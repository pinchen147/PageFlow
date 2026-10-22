//
//  MarkdownPrompts.swift
//  PageFlow
//
//  Modal AppKit prompts for the Markdown lifecycle, kept out of the 1900-line
//  `TabManager` (peer of `PrintPanel.swift`). Each free `@MainActor` function
//  builds and runs one `NSAlert` and returns the user's choice; `TabManager` owns
//  the decision (when to prompt) and the latches, and calls these purely for UI.
//

import AppKit

/// The user's answer to the "file changed on disk" prompt (ADR-0012 D5).
enum MarkdownExternalChangeChoice {
    /// Leave the conflict unresolved when the modal loop is canceled or aborted.
    case cancel
    /// Re-read the file, discarding the in-memory draft.
    case reload
    /// Keep the version open here; adopt the disk baseline so we stop re-prompting.
    case keepMine
}

/// Presents the modal Reload / Keep prompt for an externally-modified Markdown file.
/// On a dirty tab the copy makes clear that Reload discards the local draft. Returns
/// the user's choice; the caller performs the reload/keep action.
@MainActor
func presentMarkdownExternalChangePrompt(title: String, isDirty: Bool) -> MarkdownExternalChangeChoice {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "\"\(title)\" has changed on disk."
    alert.informativeText = isDirty
        ? "Reloading will discard the changes you've made here. Keep My Version to continue editing — it won't match the file on disk until you save."
        : "Reload it, or keep the version open in PageFlow?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Reload")
    alert.addButton(withTitle: "Keep My Version")

    switch alert.runModal() {
    case .alertFirstButtonReturn: return .reload
    case .alertSecondButtonReturn: return .keepMine
    default: return .cancel
    }
}

/// The user's answer when an open note's file was deleted or moved away.
enum MarkdownMissingFileChoice {
    /// Keep the text open as unsaved; Save writes the file back.
    case keepOpen
    /// Close the tab (an edited tab still asks whether to save).
    case close
}

/// Presents the Keep Open / Close prompt for a note whose file disappeared.
@MainActor
func presentMarkdownMissingFilePrompt(title: String, isDirty: Bool) -> MarkdownMissingFileChoice {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "\"\(title)\" was deleted or moved."
    alert.informativeText = isDirty
        ? "PageFlow still has your text. Keep it open and save to write the file back, or close the tab and decide whether to save."
        : "PageFlow still has its text. Keep it open and save to write the file back, or close the tab."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Keep Open")
    alert.addButton(withTitle: "Close Tab")
    return alert.runModal() == .alertSecondButtonReturn ? .close : .keepOpen
}

/// Presents the one-time "saved as UTF-8" note after a save that downgraded a
/// UTF-16/32 (or 8-bit-overflow) source to UTF-8 (ADR-0008). UI only — the caller
/// owns the once-per-document latch (`MarkdownContent.consumeEncodingDowngradeNote`).
/// Shown as a non-blocking sheet on the key window, or app-modal as a fallback.
@MainActor
func presentMarkdownEncodingDowngradeNote(title: String, originalEncoding: String.Encoding) {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "\"\(title)\" was saved as UTF-8"
    alert.informativeText = "It was \(String.localizedName(of: originalEncoding)). PageFlow saved it as UTF-8 so that every character is kept."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    presentAsSheetOrModal(alert)
}

/// Asks before a link in a note opens a local file in its own app.
@MainActor
func presentMarkdownLocalFileLinkPrompt(fileName: String) -> Bool {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "Open \"\(fileName)\"?"
    alert.informativeText = "This link opens a file on your Mac in its default app."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// Asks before opening a note large enough to be slow to open and edit.
@MainActor
func presentMarkdownLargeNotePrompt(title: String, byteCount: Int) -> Bool {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    alert.messageText = "\"\(title)\" is \(size)"
    alert.informativeText = "Notes this large can be slow to open and edit in PageFlow."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Anyway")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// Warns, once per open, that a note's file had damaged UTF-8 bytes.
@MainActor
func presentMarkdownInvalidUTF8Note(title: String) {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "\"\(title)\" has damaged characters"
    alert.informativeText = "Some bytes in this file aren't valid UTF-8, so they show as \u{FFFD}. The rest of the text is intact. Saving replaces the damaged bytes with \u{FFFD}."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    presentAsSheetOrModal(alert)
}

/// Asks before the first save writes U+FFFD over a file's damaged bytes.
@MainActor
func presentMarkdownInvalidUTF8SavePrompt(title: String) -> Bool {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    alert.messageText = "Save \"\(title)\" and replace its damaged characters?"
    alert.informativeText = "Bytes in the file that aren't valid UTF-8 will be saved as \u{FFFD}. Everything else is saved as you see it."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
private func presentAsSheetOrModal(_ alert: NSAlert) {
    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window, completionHandler: nil)
    } else {
        alert.runModal()
    }
}
