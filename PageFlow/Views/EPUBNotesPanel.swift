//
//  EPUBNotesPanel.swift
//  PageFlow
//
//  The book's notes beside the pages, in PDF's comments panel: the note
//  being written opens here rather than over the text, and the others are
//  listed to jump back to. A note acts as a comment does: one click goes to
//  it, a second edits it, and its menu and close button delete it.
//

import SwiftUI

struct EPUBNotesPanel: View {
    let content: EPUBContent
    @Bindable var highlights: EPUBHighlights
    let onClose: () -> Void

    /// The note being edited. Every change is saved to the book as it is
    /// typed, so quitting mid-sentence never loses it; the draft only keeps
    /// what the editor shows (a blank in progress is no note).
    @State private var draft: EPUBNoteDraft?

    private var cardInk: NSColor { EPUBTextStyling.themeTextColor(for: content.requestedPalette) }
    private var cardScheme: ColorScheme { content.requestedPalette == .dark ? .dark : .light }

    private var shown: [EPUBHighlight] {
        highlights.items.filter { $0.isNote || $0.id == highlights.editingID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // PDF's comments list: its insets, spacing and cards.
                    LazyVStack(spacing: DesignTokens.spacingSM) {
                        if shown.isEmpty {
                            emptyState
                        } else {
                            ForEach(shown) { highlight in
                                card(highlight).id(highlight.id)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.spacingSM)
                    .padding(.bottom, DesignTokens.spacingMD)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: highlights.selectedNoteID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(width: DesignTokens.commentSidebarWidth)
        .pageFlowLiquidGlassPanel(.sidebar)
        .onChange(of: highlights.editingRevision, initial: true) { startDraft(highlights.editingID) }
    }

    private var header: some View {
        HStack {
            Text("Notes")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            GlassSidebarCloseButton(label: "Close Notes", action: onClose)
                .help("Close")
                .accessibilityLabel("Close Notes")
        }
        .padding(.leading, DesignTokens.spacingMD)
        .padding(.trailing, DesignTokens.spacingSM)
        .padding(.top, DesignTokens.spacingSM)
    }

    /// PDF's empty comments list, with the Add Note shortcut as it is set now.
    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "text.bubble")
                .font(.system(size: DesignTokens.epubNotesEmptyIconSize))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(emptyHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacingXL)
        .accessibilityElement(children: .combine)
    }

    private var emptyHint: String {
        let shortcut = ShortcutModel.current(for: "comment")
        return shortcut.isNone ? "Select text and choose Tools > Add Note"
            : "Select text and press \(shortcut.displayString)"
    }

    /// A note as PDF shows a comment: its page above an opaque card, the
    /// card outlined in the accent colour while it is selected or edited.
    @ViewBuilder
    private func card(_ highlight: EPUBHighlight) -> some View {
        let isEditing = highlight.id == highlights.editingID
        let page = content.pageListLabel(of: highlight)
        let select = { content.goToNote(highlight) }
        let edit = { highlights.edit(highlight.id) }
        let delete = { highlights.remove(highlight.id) }
        AnnotationNoteCard(
            pageLabel: content.pagination.isExcluded(highlight.chapterIndex) ? page : "Page \(page)",
            accessibilityLabel: "Note on page \(page)", deleteLabel: "Delete Note",
            excerpt: highlight.excerpt, annotationColor: highlight.nsColor,
            surface: EPUBTextStyling.themeBackgroundColor(for: content.requestedPalette),
            ink: cardInk, colorScheme: cardScheme,
            isSelected: highlight.id == highlights.selectedNoteID, isEditing: isEditing, canEdit: true,
            onSelect: select, onEdit: edit, onDelete: delete
        ) {
            if isEditing, let draft {
                EPUBNoteEditor(
                    draft: draft, annotationOwner: highlights, textColor: cardInk, colorScheme: cardScheme,
                    focusRevision: highlights.editingRevision, presets: highlight.presets(asNote: true),
                    onText: { highlights.setNote($0, of: highlight.id) },
                    onColor: { highlights.setColor($0, of: highlight.id) },
                    onDone: { highlights.endEditing() },
                    onStyle: { highlights.setStyle($0, of: highlight.id) }
                )
            } else if highlight.hasNote, let note = highlight.note {
                MathTextView(text: note, textColor: cardInk)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Add a note")
                    .font(.system(size: DesignTokens.commentFontSize))
                    .foregroundStyle(.tertiary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func startDraft(_ id: UUID?) {
        draft = id.flatMap(highlights.highlight).map {
            EPUBNoteDraft(text: $0.note ?? "", color: $0.color, style: $0.style)
        }
    }
}
