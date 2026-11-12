import EPUBKit
import SwiftUI

@MainActor
struct EPUBToolbar: View {
    @Bindable var content: EPUBContent
    let onOpenFilePicker: () -> Void
    @Binding var showingContents: Bool
    let onFind: () -> Void

    @State private var settingsManager = SettingsManager.shared
    @State private var showingTypographyPopover = false

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(icon: "doc", help: "Open a document", action: onOpenFilePicker, label: "Open")
            Divider().frame(height: 16)
            // Zoom sits where PDF and Markdown put it: right after Open.
            let hasBook = content.book != nil
            // The "1" button is EPUB's reflow: pages take the window's size.
            ZoomToolbarGroup(
                canZoomOut: hasBook && content.canZoomOut,
                canZoomIn: hasBook && content.canZoomIn,
                onZoomOut: content.zoomOut,
                onZoomIn: content.zoomIn,
                reset: .init(label: "Reflow to Fit",
                             help: "Reflow to fit: pages take the window's size and the text re-flows",
                             isOn: content.zoom == .reflow,
                             disabled: !hasBook || content.zoom == .reflow,
                             action: content.reflowToFit),
                fit: .init(isFitted: content.zoom == .fit, isAvailable: hasBook, action: content.zoomToFit)
            )
            SidebarFindToolbarGroup(
                showingSidebar: $showingContents,
                canToggleSidebar: hasBook,
                canFind: hasBook,
                onFind: onFind
            )
            // PDF's annotation group, in its place: Underline, Highlight, their colours, then a note.
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: "underline",
                help: "Underline the selected text",
                action: { content.highlights.highlightSelection(style: .underline) },
                disabled: !hasSelection,
                label: "Underline"
            )
            GlassToolbarButton(
                icon: "highlighter",
                help: "Highlight the selected text",
                action: { content.highlights.highlightSelection() },
                disabled: !hasSelection,
                label: "Highlight"
            )
            AnnotationColorMenu(
                isUnderlineColor: { SettingsManager.ColorPreset.colorsMatch($0.hex, content.highlights.underlineColor) },
                isHighlightColor: { SettingsManager.ColorPreset.colorsMatch($0.hex, content.highlights.color) },
                chooseUnderline: { content.highlights.underlineColor = $0.hex },
                chooseHighlight: { content.highlights.color = $0.hex },
                isAvailable: content.book != nil
            )
            GlassToolbarButton(
                icon: "text.bubble",
                help: "Add a note",
                action: { content.addNote() },
                disabled: !hasBook || !content.canAddNote,
                label: "Add Note"
            )
            // PDF's comments toggle: the Notes panel beside the pages.
            GlassToolbarButton(
                icon: content.highlights.isPanelShown ? "bubble.right.fill" : "bubble.right",
                help: "Show or hide notes",
                action: {
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { content.highlights.togglePanel() }
                },
                disabled: !hasBook,
                label: "Notes",
                isOn: content.highlights.isPanelShown
            )
            GlassToolbarButton(
                icon: content.isCurrentLocationBookmarked ? "bookmark.fill" : "bookmark",
                help: "Add or remove a bookmark on this page",
                action: content.toggleBookmarkAtCurrentLocation,
                disabled: content.book == nil,
                label: "Bookmark",
                isOn: content.isCurrentLocationBookmarked
            )
            readAloudButtons
            Divider().frame(height: 16)
            typographyButton
            layoutMenu
            // PDF's closing groups: Back/Forward retrace jumps, then page turns.
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "arrow.uturn.backward", help: "Go back", action: content.goBack,
                               disabled: !content.canGoBack, label: "Back")
            GlassToolbarButton(icon: "arrow.uturn.forward", help: "Go forward", action: content.goForward,
                               disabled: !content.canGoForward, label: "Forward")
            Divider().frame(height: 16)
            // A right-to-left book turns on to the left, as its arrow keys do.
            let leftTurnsOn = content.book?.pageProgression == .rightToLeft
            GlassToolbarButton(icon: "chevron.left", help: leftTurnsOn ? "Next page" : "Previous page",
                               action: { content.turnPage(forward: leftTurnsOn) },
                               disabled: !content.canTurn(forward: leftTurnsOn),
                               label: leftTurnsOn ? "Next Page" : "Previous Page")
            GlassToolbarButton(icon: "chevron.right", help: leftTurnsOn ? "Previous page" : "Next page",
                               action: { content.turnPage(forward: !leftTurnsOn) },
                               disabled: !content.canTurn(forward: !leftTurnsOn),
                               label: leftTurnsOn ? "Previous Page" : "Next Page")
        }
    }

    private var hasSelection: Bool { content.book != nil && content.highlights.canAnnotateSelection }

    /// Read Aloud, and while it reads, Pause or Resume.
    @ViewBuilder
    private var readAloudButtons: some View {
        let reader = content.readAloud
        GlassToolbarButton(
            icon: reader.isActive ? "speaker.slash" : reader.usesNarration ? "headphones" : "speaker.wave.2",
            help: reader.isActive ? "Stop \(reader.helpNoun)" : reader.startHelp,
            action: reader.toggle,
            disabled: content.book == nil,
            label: reader.isActive ? reader.stopTitle : reader.usesNarration ? reader.startTitle : "Read Aloud",
            isOn: reader.isActive
        )
        if reader.isActive {
            GlassToolbarButton(
                icon: reader.state == .paused ? "play" : "pause",
                help: "\(reader.state == .paused ? "Resume" : "Pause") \(reader.helpNoun)",
                action: reader.togglePause,
                label: reader.state == .paused ? reader.resumeTitle : reader.pauseTitle
            )
        }
    }

    // MARK: - Layout

    /// The page layouts, named like PDF's display modes.
    private var layoutMenu: some View {
        Menu {
            Picker("Page Layout", selection: Binding(get: { content.layout }, set: { content.setLayout($0) })) {
                ForEach(EPUBPageLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            GlassToolbarLabel(
                icon: content.layout.pagesPerRow == 2 ? "book.pages" : "doc.text",
                interactive: content.book != nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pageFlowClickCursor()
        .disabled(content.book == nil)
        .toolbarTooltip("Page layout", enabled: settingsManager.showTooltips)
        .accessibilityLabel("Page Layout")
        .accessibilityValue(content.layout.title)
    }

    // MARK: - Typography

    private var typographyButton: some View {
        GlassToolbarButton(
            icon: "textformat.size",
            help: "Text formatting",
            action: { showingTypographyPopover.toggle() },
            disabled: content.book == nil,
            label: "Text Formatting"
        )
        .popover(isPresented: $showingTypographyPopover, arrowEdge: .bottom) {
            typographyPopover
                .padding(DesignTokens.spacingMD)
        }
    }

    private var typographyPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM + 2) {
            Text("Font")
                .font(.caption)
                .foregroundStyle(.secondary)
            EPUBFontPicker(content: content)

            HStack {
                Text("Size")
                Spacer()
                Button {
                    adjustFontSize(by: -1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .accessibilityLabel("Smaller Text")
                .disabled(content.requestedTypography.fontSize <= EPUBTypography.fontSizeRange.lowerBound)
                Text("\(Int(content.requestedTypography.fontSize))")
                    .monospacedDigit()
                    .frame(minWidth: 24)
                Button {
                    adjustFontSize(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .accessibilityLabel("Larger Text")
                .disabled(content.requestedTypography.fontSize >= EPUBTypography.fontSizeRange.upperBound)
            }

            HStack {
                Text("Line height")
                Slider(value: lineHeightBinding, in: EPUBTypography.lineHeightRange, step: 0.1) {
                    Text("Line height")
                }
                .labelsHidden()
                Text(String(format: "%.1f", Double(content.requestedTypography.lineHeight)))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }

            EPUBPageSettingsControls(content: content)

            HStack {
                Text("Theme")
                Spacer()
                themeSwatch(.system, label: "System")
                themeSwatch(.light, label: "Light")
                themeSwatch(.sepia, label: "Sepia")
                themeSwatch(.dark, label: "Dark")
            }
        }
        .frame(width: DesignTokens.epubTypographyPopoverWidth)
    }

    private var lineHeightBinding: Binding<CGFloat> {
        Binding(
            get: { content.requestedTypography.lineHeight },
            set: { lineHeight in content.updateTypography { $0.lineHeight = lineHeight } }
        )
    }

    private func themeSwatch(_ theme: EPUBReaderTheme, label: String) -> some View {
        Button {
            content.chooseTheme(theme)
        } label: {
            ZStack {
                if theme == .system {
                    // Half light, half dark: it follows the Mac.
                    Circle()
                        .fill(LinearGradient(
                            stops: [.init(color: .white, location: 0.5),
                                    .init(color: Color(nsColor: EPUBTextStyling.themeBackgroundColor(for: .dark)),
                                          location: 0.5)],
                            startPoint: .leading, endPoint: .trailing))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                } else {
                    Circle()
                        .fill(Color(nsColor: EPUBTextStyling.themeBackgroundColor(for: theme.palette(isDark: false))))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                }
                if content.requestedTypography.theme == theme {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme == .system ? Color.accentColor
                            : Color(nsColor: EPUBTextStyling.themeTextColor(for: theme.palette(isDark: false))))
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .help(label)
        .accessibilityLabel("\(label) Theme")
        .accessibilityAddTraits(content.requestedTypography.theme == theme ? .isSelected : [])
    }

    private func adjustFontSize(by delta: CGFloat) {
        content.updateTypography {
            $0.fontSize = min(
                max($0.fontSize + delta, EPUBTypography.fontSizeRange.lowerBound),
                EPUBTypography.fontSizeRange.upperBound
            )
        }
    }
}
