//
//  NotesSettingsTab.swift
//  PageFlow
//
//  Settings pane for how Markdown notes look.
//

import SwiftUI

struct NotesSettingsTab: View {
    @State private var settingsManager = SettingsManager.shared

    /// The curated font menu (`SettingsManager.markdownFontFamilies`) minus
    /// the app default, which gets its own labeled entry at the top.
    private static let fontFamilies: [String] =
        SettingsManager.markdownFontFamilies
            .filter { $0 != SettingsManager.defaultMarkdownFontFamily }

    var body: some View {
        @Bindable var settings = settingsManager

        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: $settings.markdownColorScheme) {
                    Text("System").tag(MarkdownColorScheme.system)
                    Text("Light").tag(MarkdownColorScheme.light)
                    Text("Dark").tag(MarkdownColorScheme.dark)
                }

                Picker("Font", selection: $settings.markdownFontFamily) {
                    Text("Default (SF Pro)").tag(SettingsManager.defaultMarkdownFontFamily)
                    Divider()
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                Stepper(value: $settings.markdownFontSize, in: SettingsManager.markdownFontSizeRange, step: 1) {
                    HStack(spacing: DesignTokens.spacingXS) {
                        Text("Font size")
                        Text("\(Int(settings.markdownFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Slider(value: $settings.markdownSideMargin, in: SettingsManager.markdownSideMarginRange) {
                    HStack(spacing: DesignTokens.spacingXS) {
                        Text("Side margins")
                        Text("\(Int(settings.markdownSideMargin)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Page look", isOn: $settings.markdownPageLook)
                Toggle("Center when zoomed out", isOn: $settings.markdownCentersZoomedOut)
                Toggle("Show hidden-content row", isOn: $settings.markdownShowsHiddenContentRow)
            } header: {
                Text("Layout")
            } footer: {
                Text("Page look centers a reading column. Zoomed out, a note pins left unless centered; wide tables and diagrams use the extra width either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
