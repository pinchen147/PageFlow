//
//  EPUBNoteEditor.swift
//  PageFlow
//
//  The editor a highlight's card opens in the Notes panel: its colour, tint
//  or underline, and its note in PDF's comment editor (Return commits,
//  Shift-Return breaks the line). The note is saved as it is typed.
//

import SwiftUI

/// What the Notes panel's editor shows: the note as typed (a blank in
/// progress included, which the book keeps as no note) and its colour.
@Observable
final class EPUBNoteDraft {
    var text: String
    var color: String
    var style: EPUBHighlightStyle

    init(text: String, color: String, style: EPUBHighlightStyle = .tint) {
        self.text = text
        self.color = color
        self.style = style
    }
}

struct EPUBNoteEditor: View {
    @Bindable var draft: EPUBNoteDraft
    var annotationOwner: AnyObject? = nil
    var textColor: NSColor? = nil
    var colorScheme: ColorScheme? = nil
    var focusRevision: Int? = nil
    let presets: [SettingsManager.ColorPreset]
    /// Each edit of the note's text, as it is typed.
    let onText: (String) -> Void
    let onColor: (String) -> Void
    let onDone: () -> Void
    var onStyle: (EPUBHighlightStyle) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            HStack(spacing: DesignTokens.spacingSM) {
                AnnotationNoteColors(color: Binding(
                    get: { SettingsManager.ColorPreset.color(fromHex: draft.color) ?? .black },
                    set: { color in
                        let hex = SettingsManager.ColorPreset.hex(from: color)
                        draft.color = hex
                        onColor(hex)
                    }), presets: presets)
                Spacer()
                underlineToggle
            }
            AnnotationNoteTextEditor(text: $draft.text, placeholder: "Add a note", accessibilityLabel: "Note",
                                     annotationOwner: annotationOwner, textColor: textColor,
                                     colorScheme: colorScheme, focusRevision: focusRevision, onDone: onDone)
            .onChange(of: draft.text) { _, text in onText(text) }
        }
    }

    /// Underline instead of the tint, in the same colour.
    private var underlineToggle: some View {
        let isOn = draft.style == .underline
        return Button {
            draft.style = isOn ? .tint : .underline
            onStyle(draft.style)
        } label: {
            Image(systemName: "underline")
                .frame(width: DesignTokens.epubHighlightSwatchSize, height: DesignTokens.epubHighlightSwatchSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .pageFlowClickCursor()
        .help(isOn ? "Show as a highlight" : "Show as an underline")
        .accessibilityLabel("Underline")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
