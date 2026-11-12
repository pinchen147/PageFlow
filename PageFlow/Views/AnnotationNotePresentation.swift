import SwiftUI

/// Presentation shared by PDF comments and book notes; each adapter owns its model and palette.
struct AnnotationNoteCard<Content: View>: View {
    let pageLabel: String
    let accessibilityLabel: String
    let deleteLabel: String
    let excerpt: String?
    let annotationColor: NSColor
    let surface: NSColor
    let ink: NSColor
    let colorScheme: ColorScheme
    let isSelected: Bool
    let isEditing: Bool
    let canEdit: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Button(action: onSelect) {
                Text(pageLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.spacingXS)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
                    if let excerpt, !excerpt.isEmpty {
                        HStack(alignment: .top, spacing: DesignTokens.spacingSM) {
                            RoundedRectangle(cornerRadius: DesignTokens.epubNoteColorBarCornerRadius)
                                .fill(Color(nsColor: annotationColor))
                                .frame(width: DesignTokens.epubNoteColorBarWidth)
                            Text(excerpt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(isEditing ? 4 : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, DesignTokens.tabCloseButtonSize)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    content()
                        .padding(.trailing, excerpt?.isEmpty != false ? DesignTokens.tabCloseButtonSize : 0)
                }
                .padding(DesignTokens.spacingSM)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                        .fill(Color(nsColor: surface))
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                                .strokeBorder(isSelected || isEditing ? DesignTokens.commentCardStrokeSelected
                                    : Color(nsColor: ink).opacity(0.08),
                                    lineWidth: isSelected || isEditing ? DesignTokens.epubNoteCardStrokeWidthEditing
                                        : DesignTokens.epubNoteCardStrokeWidth)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(DesignTokens.commentBubbleShadowOpacity),
                        radius: DesignTokens.commentBubbleShadowRadius, y: 2)
                .contentShape(Rectangle())
                .background {
                    if !isEditing {
                        ClickCatcher(onSingleClick: onSelect, onDoubleClick: { if canEdit { onEdit() } })
                    }
                }
                .pageFlowClickCursor(when: !isEditing)
                .contextMenu {
                    Button("Edit", action: onEdit).disabled(!canEdit)
                    Button("Go to Page", action: onSelect)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete).disabled(!canEdit)
                }
                // Keep card actions on their own element, outside the editable child controls.
                .accessibilityElement(children: .contain)
                .accessibilityAction(.default, onSelect)
                .accessibilityAction(named: "Edit") { if canEdit { onEdit() } }

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .padding(.top, DesignTokens.spacingXS)
                .padding(.trailing, DesignTokens.spacingXS)
                .help(deleteLabel)
                .accessibilityLabel(deleteLabel)
                .disabled(!canEdit)
            }
        }
        .environment(\.colorScheme, colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The same native field and sizing for both adapters; typing Undo stays in CustomTextEditor.
struct AnnotationNoteTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var annotationOwner: AnyObject?
    var textColor: NSColor?
    var colorScheme: ColorScheme?
    var focusRevision: Int?
    let onDone: () -> Void
    @FocusState private var isEditing: Bool
    @State private var editorHeight: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: DesignTokens.commentFontSize))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
            CustomTextEditor(text: $text, isFocused: _isEditing, calculatedHeight: $editorHeight,
                             fieldLabel: accessibilityLabel, onCommit: onDone, takesFocusOnAppear: true, annotationOwner: annotationOwner,
                             textColor: textColor, colorScheme: colorScheme, focusRevision: focusRevision)
                .frame(maxWidth: .infinity, minHeight: max(editorHeight, DesignTokens.epubNoteEditorHeight),
                       alignment: .topLeading)
        }
        .onAppear { isEditing = true }
    }
}

/// The current annotation's native picker, with configured colors kept as quick choices.
struct AnnotationNoteColors: View {
    @Binding var color: NSColor
    let presets: [SettingsManager.ColorPreset]

    var body: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            ColorWellView(color: $color, isCircular: true)
                .frame(width: DesignTokens.epubHighlightSwatchSize, height: DesignTokens.epubHighlightSwatchSize)
                .help("Choose a comment color")
                .accessibilityLabel("Comment color")
                .contextMenu {
                    if presets.count == 1, let preset = presets.first {
                        Button(preset.name) { color = preset.color }
                    }
                }
            if presets.count > 1 {
                ForEach(presets) { preset in
                    AnnotationNoteColorSwatch(preset: preset, isSelected: color == preset.color) {
                        color = preset.color
                    }
                }
            }
        }
    }
}

/// Both adapters use the configured preset's color; only their transaction differs.
struct AnnotationNoteColorSwatch: View {
    let preset: SettingsManager.ColorPreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(Color(nsColor: preset.color))
                .overlay(Circle().strokeBorder(
                    Color.primary.opacity(isSelected ? DesignTokens.epubSwatchStrokeOpacityCurrent
                        : DesignTokens.epubSwatchStrokeOpacity),
                    lineWidth: isSelected ? DesignTokens.epubSwatchStrokeWidthCurrent : DesignTokens.epubSwatchStrokeWidth))
                .frame(width: DesignTokens.epubHighlightSwatchSize, height: DesignTokens.epubHighlightSwatchSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
