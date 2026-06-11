//
//  GeneralSettingsTab.swift
//  PageFlow
//
//  Settings tab for general app settings including updates
//

import SwiftUI
import AppKit

struct GeneralSettingsTab: View {
    @Environment(UpdateManager.self) private var updateManager
    @State private var settingsManager = SettingsManager.shared
    @State private var showingNoUpdatesAlert = false
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
                if updateManager.isSparkleEnabled {
                    // Bind straight to the shared updater. Sparkle persists this in
                    // the app's UserDefaults itself, so there is no separate local
                    // @State to fall out of sync — the previous code mirrored it into
                    // an @State that reset to false whenever this tab was re-created
                    // (e.g. switching Settings tabs), which is why it "turned off by
                    // itself." Hidden entirely when Sparkle isn't compiled in, so the
                    // toggle can never be a no-op that silently reverts.
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updateManager.automaticallyChecksForUpdates },
                        set: { updateManager.automaticallyChecksForUpdates = $0 }
                    ))
                }

                HStack {
                    Spacer()
                    Button("Check Now") {
                        if updateManager.isSparkleEnabled {
                            updateManager.checkForUpdates()
                        } else {
                            showingNoUpdatesAlert = true
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.spacingMD)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassSurface(.settingsRow)
                }
            } header: {
                Text("Updates")
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

                Toggle("Always show top bar", isOn: $settings.isTopBarAlwaysVisible)
                Toggle("Always show toolbar", isOn: $settings.isFloatingToolbarAlwaysVisible)
                Toggle("Always show page number", isOn: $settings.isPageIndicatorAlwaysVisible)

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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            frontmostTab = WindowRegistry.shared.frontmostTabManager()
        }
        .alert("Updates Not Available", isPresented: $showingNoUpdatesAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Automatic updates are only available in the direct download version of PageFlow.")
        }
    }
}
