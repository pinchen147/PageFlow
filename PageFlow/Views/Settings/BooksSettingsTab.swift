//
//  BooksSettingsTab.swift
//  PageFlow
//
//  Settings pane for what a new book opens in.
//

import SwiftUI

struct BooksSettingsTab: View {
    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                BookDefaultsSettings(settings: settingsManager)
            } header: {
                Text("New Books")
            } footer: {
                Text("Choosing a theme or font in a book changes these too. A book you've read keeps its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
