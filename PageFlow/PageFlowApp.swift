//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI

@main
struct PageFlowApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // File menu is handled by MainView's fileImporter
            }

            CommandMenu("View") {
                Button("Actual Size") {
                    // Will be handled via FocusedValue in Phase 2
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom In") {
                    // Will be handled via FocusedValue in Phase 2
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    // Will be handled via FocusedValue in Phase 2
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Go to Page...") {
                    // Will be handled via FocusedValue in Phase 2
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }
    }
}
