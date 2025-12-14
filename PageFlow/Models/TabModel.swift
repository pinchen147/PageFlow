//
//  TabModel.swift
//  PageFlow
//
//  Tab data model for multi-document support
//

import Foundation

struct TabModel: Identifiable, Codable {
    let id: UUID
    var documentURL: URL?
    var title: String
    var isSecurityScoped: Bool

    // Per-tab state for restoration
    var savedPageIndex: Int
    var savedScaleFactor: CGFloat
    var savedScrollY: CGFloat?
    var savedSearchQuery: String
    var savedSearchResultIndex: Int

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
        self.savedPageIndex = 0
        self.savedScaleFactor = 1.0
        self.savedScrollY = nil
        self.savedSearchQuery = ""
        self.savedSearchResultIndex = 0
    }
}
