//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI

@main
struct PageFlowApp: App {
    @State private var pdfManager = PDFManager()

    var body: some Scene {
        WindowGroup {
            MainView(pdfManager: pdfManager)
                .navigationTitle(pdfManager.documentTitle)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .importExport) {
                Button("Print...") {
                    pdfManager.print()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!pdfManager.hasDocument)
            }
        }
    }
}
