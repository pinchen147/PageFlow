//
//  GeneralSettingsTab.swift
//  PageFlow
//
//  Settings tab for general app settings
//

import SwiftUI
import AppKit

struct GeneralSettingsTab: View {
    @State private var settingsManager = SettingsManager.shared
    @State private var frontmostTab: TabManager?

    /// The curated font menu (`SettingsManager.markdownFontFamilies`) minus
    /// the app default, which gets its own labeled entry at the top.
    private static let markdownFontFamilies: [String] =
        SettingsManager.markdownFontFamilies
            .filter { $0 != SettingsManager.defaultMarkdownFontFamily }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var toolbarScaleBinding: Binding<Double> {
        Binding(
            get: { settingsManager.toolbarScale },
            set: { settingsManager.toolbarScale = SettingsManager.clampedToolbarScale($0) }
        )
    }

    var body: some View {
        @Bindable var settings = settingsManager

        Form {
            Section {
                HStack(spacing: DesignTokens.spacingMD) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                        Text("PageFlow")
                            .font(.headline)
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, DesignTokens.spacingSM)
            }

            Section {
                VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
                    HStack {
                        Text("Toolbar size")
                        Spacer()
                        Text("\(Int(round(settings.toolbarScale * 100)))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: toolbarScaleBinding,
                        in: SettingsManager.toolbarScaleRange
                    ) {
                        Text("Toolbar size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }

                    HStack {
                        Spacer()
                        Button("Reset Size") {
                            settingsManager.resetToolbarScale()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, DesignTokens.spacingMD)
                        .padding(.vertical, DesignTokens.spacingXS)
                        .pageFlowLiquidGlassSurface(
                            .settingsAction(
                                enabled: abs(settings.toolbarScale - SettingsManager.defaultToolbarScale) >= 0.001,
                                activeTint: 0.08
                            )
                        )
                        .disabled(abs(settings.toolbarScale - SettingsManager.defaultToolbarScale) < 0.001)
                    }
                }

                Toggle("Magnify toolbar icons on hover", isOn: $settings.isToolbarMagnificationEnabled)
                Toggle("Show button tooltips on hover", isOn: $settings.showTooltips)

                Toggle("Always show top bar", isOn: $settings.isTopBarAlwaysVisible)
                Toggle("Always show toolbar", isOn: $settings.isFloatingToolbarAlwaysVisible)
                Toggle("Always show page number", isOn: $settings.isPageIndicatorAlwaysVisible)
                Toggle("Compact tabs", isOn: $settings.isCompactTabsEnabled)

                if let frontmostTab {
                    @Bindable var tab = frontmostTab
                    Toggle("Keep this window on top", isOn: $tab.isAlwaysOnTop)
                } else {
                    Toggle("Keep this window on top", isOn: .constant(false))
                        .disabled(true)
                }
            } header: {
                Text("Window")
            } footer: {
                Text("Applies to the frontmost PageFlow window only. Each window is independent and resets when closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Color scheme", selection: $settings.markdownColorScheme) {
                    Text("System").tag(MarkdownColorScheme.system)
                    Text("Light").tag(MarkdownColorScheme.light)
                    Text("Dark").tag(MarkdownColorScheme.dark)
                }

                Slider(
                    value: $settings.markdownSideMargin,
                    in: SettingsManager.markdownSideMarginRange
                ) {
                    Text("Side margins: \(Int(settings.markdownSideMargin)) px")
                } minimumValueLabel: {
                    Image(systemName: "rectangle.expand.horizontal")
                } maximumValueLabel: {
                    Image(systemName: "rectangle.compress.horizontal")
                }

                Picker("Font", selection: $settings.markdownFontFamily) {
                    Text("Default (SF Pro)").tag(SettingsManager.defaultMarkdownFontFamily)
                    Divider()
                    ForEach(Self.markdownFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                Stepper(value: $settings.markdownFontSize, in: SettingsManager.markdownFontSizeRange, step: 1) {
                    Text("Font size: \(Int(settings.markdownFontSize)) pt")
                }

                Toggle("Page look (centered reading column)", isOn: $settings.markdownPageLook)
                Toggle("Center document when zoomed out", isOn: $settings.markdownCentersZoomedOut)
            } header: {
                Text("Markdown")
            } footer: {
                Text("Applies to the Markdown editor. Side margins set the left/right whitespace around the text (live). Headings and code scale with the base size; bold, italic, and underline work with every offered font. When zoomed out, the document pins left unless centering is on; wide tables and diagrams use the extra width either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
    }
}
