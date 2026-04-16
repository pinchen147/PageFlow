//
//  GeneralSettingsTab.swift
//  PageFlow
//
//  Settings tab for general app settings including updates
//

import SwiftUI
import AppKit

struct GeneralSettingsTab: View {
    @State private var updateManager = UpdateManager()
    @State private var settingsManager = SettingsManager.shared
    @State private var autoCheckEnabled = false
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
                Toggle("Check for updates automatically", isOn: $autoCheckEnabled)
                    .onChange(of: autoCheckEnabled) { _, newValue in
                        updateManager.automaticallyChecksForUpdates = newValue
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
                        .disabled(abs(settings.toolbarScale - SettingsManager.defaultToolbarScale) < 0.001)
                    }
                }

                Toggle("Pin toolbar", isOn: $settings.isToolbarPinned)

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
            autoCheckEnabled = updateManager.automaticallyChecksForUpdates
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
