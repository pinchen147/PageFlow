//
//  GeneralSettingsTab.swift
//  PageFlow
//
//  Settings pane for what every document shares: the window, the toolbar and the rail.
//

import SwiftUI
import AppKit

struct GeneralSettingsTab: View {
    @State private var settingsManager = SettingsManager.shared
    @State private var frontmostTab: TabManager?

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
                            .frame(width: 48, height: 48)
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
            }

            Section("Window") {
                Toggle("Always show top bar", isOn: $settings.isTopBarAlwaysVisible)
                Toggle("Always show toolbar", isOn: $settings.isFloatingToolbarAlwaysVisible)
                Toggle("Always show page number", isOn: $settings.isPageIndicatorAlwaysVisible)
                Toggle("Compact tabs", isOn: $settings.isCompactTabsEnabled)

                VStack(alignment: .leading, spacing: 2) {
                    if let frontmostTab {
                        @Bindable var tab = frontmostTab
                        Toggle("Keep this window on top", isOn: $tab.isAlwaysOnTop)
                    } else {
                        Toggle("Keep this window on top", isOn: .constant(false))
                            .disabled(true)
                    }
                    Text("Only the frontmost PageFlow window, until it closes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Toolbar") {
                Slider(value: toolbarScaleBinding, in: SettingsManager.toolbarScaleRange) {
                    HStack(spacing: DesignTokens.spacingXS) {
                        Text("Size")
                        Text("\(Int(round(settings.toolbarScale * 100)))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if abs(settings.toolbarScale - SettingsManager.defaultToolbarScale) >= 0.001 {
                    Button("Reset Size") {
                        settingsManager.resetToolbarScale()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Toggle("Magnify icons on hover", isOn: $settings.isToolbarMagnificationEnabled)
                Toggle("Show button tooltips", isOn: $settings.showTooltips)
            }

            Section {
                Toggle("Show navigation rail", isOn: $settings.showNavigationRail)
                Toggle("Show the rail only at the edge", isOn: $settings.navigationRailRevealsOnHover)
                    .disabled(!settings.showNavigationRail)
            } header: {
                Text("Navigation")
            } footer: {
                Text("Page and section markers with previews. The sidebar stays available from the toolbar and View menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
    }
}
