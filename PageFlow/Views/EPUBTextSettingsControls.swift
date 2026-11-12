//
//  EPUBTextSettingsControls.swift
//  PageFlow
//
//  The typography popover's font picker and page settings: margins,
//  justification, hyphenation and paragraph spacing. Each change re-lays
//  the book out in the new settings, as a size change does.
//

import SwiftUI

/// A font the reader can pick: a preset, or an installed family.
enum EPUBFontChoice: Hashable {
    case preset(EPUBFontFamily)
    case named(String)

    init(_ typography: EPUBTypography) {
        self = typography.fontName.map(EPUBFontChoice.named) ?? .preset(typography.family)
    }

    func apply(to typography: inout EPUBTypography) {
        switch self {
        case .preset(let family):
            typography.family = family
            typography.fontName = nil
        case .named(let name):
            typography.fontName = name
        }
    }
}

/// The font menu: System and Serif, then every installed family.
struct EPUBFontPicker: View {
    let content: EPUBContent
    @State private var families: [String] = []

    var body: some View {
        Picker("Font", selection: Binding(
            get: { EPUBFontChoice(content.requestedTypography) },
            set: { choice in content.chooseFont(choice) }
        )) {
            Text("System").tag(EPUBFontChoice.preset(.system))
            Text("Serif").tag(EPUBFontChoice.preset(.serif))
            Divider()
            // A family saved on another Mac still shows as the choice.
            if let name = content.requestedTypography.fontName, !families.contains(name) {
                Text(name).tag(EPUBFontChoice.named(name))
            }
            ForEach(families, id: \.self) { Text($0).tag(EPUBFontChoice.named($0)) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Font")
        .task { families = EPUBTextStyling.installedFamilies() }
    }
}

/// Settings' Books section: the theme and font a new book opens in. Picking
/// either in a book's own controls changes these too; a book already read
/// keeps its own.
struct BookDefaultsSettings: View {
    @Bindable var settings: SettingsManager
    @State private var families: [String] = []

    var body: some View {
        Picker("Theme", selection: $settings.bookTheme) {
            Text("System").tag(EPUBReaderTheme.system)
            Text("Light").tag(EPUBReaderTheme.light)
            Text("Sepia").tag(EPUBReaderTheme.sepia)
            Text("Dark").tag(EPUBReaderTheme.dark)
        }
        Picker("Font", selection: Binding(
            get: { EPUBFontChoice(settings.newBookTypography) },
            set: { choice in
                var typography = settings.newBookTypography
                choice.apply(to: &typography)
                settings.bookFontFamily = typography.family
                settings.bookFontName = typography.fontName
            }
        )) {
            Text("System").tag(EPUBFontChoice.preset(.system))
            Text("Serif").tag(EPUBFontChoice.preset(.serif))
            Divider()
            if let name = settings.bookFontName, !families.contains(name) {
                Text(name).tag(EPUBFontChoice.named(name))
            }
            ForEach(families, id: \.self) { Text($0).tag(EPUBFontChoice.named($0)) }
        }
        .task { families = EPUBTextStyling.installedFamilies() }
    }
}

/// Margins, justification, hyphenation and paragraph spacing.
struct EPUBPageSettingsControls: View {
    let content: EPUBContent

    private var typography: EPUBTypography { content.requestedTypography }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM + 2) {
            HStack {
                Text("Margins")
                Spacer()
                Picker("Margins", selection: Binding(
                    get: { typography.margins },
                    set: { margins in content.updateTypography { $0.margins = margins } }
                )) {
                    ForEach(EPUBPageMargins.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack {
                Text("Paragraph spacing")
                Slider(value: Binding(
                    get: { typography.paragraphSpacing },
                    set: { spacing in content.updateTypography { $0.paragraphSpacing = spacing } }
                ), in: EPUBTypography.paragraphSpacingRange, step: DesignTokens.epubParagraphSpacingStep) {
                    Text("Paragraph spacing")
                }
                .labelsHidden()
                Text(typography.paragraphSpacing == 0 ? "Book" : String(format: "+%.2g", Double(typography.paragraphSpacing)))
                    .monospacedDigit()
                    .frame(minWidth: DesignTokens.epubSettingValueWidth, alignment: .trailing)
            }

            Toggle("Justify text", isOn: Binding(
                get: { typography.isJustified },
                set: { justified in content.updateTypography { $0.isJustified = justified } }
            ))
            Toggle("Hyphenate words", isOn: Binding(
                get: { typography.isHyphenated },
                set: { hyphenated in content.updateTypography { $0.isHyphenated = hyphenated } }
            ))
        }
        .toggleStyle(.checkbox)
    }
}
