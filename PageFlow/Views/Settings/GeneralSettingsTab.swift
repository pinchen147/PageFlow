//
//  GeneralSettingsTab.swift
//  PageFlow
//
//  Settings tab for general app settings including updates
//

import SwiftUI

struct GeneralSettingsTab: View {
    @State private var updateManager = UpdateManager()
    @State private var autoCheckEnabled = false
    @State private var showingNoUpdatesAlert = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoCheckEnabled = updateManager.automaticallyChecksForUpdates
        }
        .alert("Updates Not Available", isPresented: $showingNoUpdatesAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Automatic updates are only available in the direct download version of PageFlow.")
        }
    }
}
