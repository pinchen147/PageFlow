//
//  SidebarBookmarkRow.swift
//  PageFlow
//
//  The ONE bookmark row of the glass sidebars (PDF `SidebarView`, EPUB
//  `EPUBReaderSidebar`): icon, a title that renames in place on click, the
//  page, and a remove button. EPUB rows also show the passage they mark.
//

import SwiftUI

@MainActor
struct SidebarBookmarkRow: View {
    let id: UUID
    let title: String
    /// The passage the bookmark marks, shown under the title (EPUB). A row
    /// with one aligns on the title's baseline and sets its page in tabular
    /// digits; nil keeps PDF's centered row.
    var excerpt: String?
    let pageLabel: String
    /// The list's row being renamed, if any. While one is, clicks on rows
    /// don't navigate.
    @Binding var editingID: UUID?
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var draft = ""
    @FocusState private var isTitleFocused: Bool

    private var isEditing: Bool { editingID == id }

    var body: some View {
        HStack {
            Button {
                if editingID == nil { onSelect() }
            } label: {
                HStack(alignment: excerpt == nil ? .center : .firstTextBaseline) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        titleView
                        if let excerpt, !excerpt.isEmpty {
                            Text(excerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(pageLabel)
                        .monospacedDigit(excerpt != nil)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignTokens.spacingXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor(when: editingID == nil)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .opacity(0.6)
            .help("Remove bookmark")
            .accessibilityLabel("Remove Bookmark")
        }
        // Clicking away from a rename keeps the new name, as Return does;
        // without it the row stayed a field and the list stopped navigating.
        .onChange(of: isTitleFocused) { _, focused in
            if !focused, isEditing { commit() }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onSubmit(commit)
                .onExitCommand { editingID = nil }
        } else {
            Text(title)
                .lineLimit(1)
                .onTapGesture {
                    draft = title
                    editingID = id
                    isTitleFocused = true
                }
        }
    }

    private func commit() {
        onRename(draft)
        editingID = nil
    }
}

private extension Text {
    func monospacedDigit(_ enabled: Bool) -> Text {
        enabled ? monospacedDigit() : self
    }
}
