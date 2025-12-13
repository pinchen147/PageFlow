//
//  BookmarkModel.swift
//  PageFlow
//
//  Model representing a user bookmark on a specific page.
//

import Foundation

struct BookmarkModel: Identifiable, Codable, Equatable {
    let id: UUID
    let pageIndex: Int
    var title: String
    let createdAt: Date

    init(pageIndex: Int, title: String? = nil) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.title = title ?? "Page \(pageIndex + 1)"
        self.createdAt = Date()
    }
}
