//
//  TabModel.swift
//  PageFlow
//
//  Tab data model for multi-document support
//

import Foundation

struct TabModel: Identifiable {
    let id: UUID
    var documentURL: URL?
    var title: String
    var isSecurityScoped: Bool

    // Per-tab view state for restoration (page, zoom, search) lives on the tab's
    // TabSession (`viewSnapshot`), so it travels intact when a tab moves windows.

    var displayTitle: String {
        if let url = documentURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return title.isEmpty ? "New Tab" : title
    }

    var hasDocument: Bool {
        documentURL != nil
    }

    init(
        id: UUID = UUID(),
        documentURL: URL? = nil,
        title: String = "New Tab",
        isSecurityScoped: Bool = false
    ) {
        self.id = id
        self.documentURL = documentURL
        self.title = title
        self.isSecurityScoped = isSecurityScoped
    }
}
