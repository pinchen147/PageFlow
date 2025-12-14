//
//  CommentModel.swift
//  PageFlow
//
//  Data model for PDF comments
//

import Foundation

struct CommentModel: Identifiable, Equatable {
    let id: UUID
    var text: String
    let pageIndex: Int
    let bounds: CGRect
    let createdAt: Date

    init(id: UUID = UUID(), text: String = "", pageIndex: Int, bounds: CGRect, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.createdAt = createdAt
    }

    static func == (lhs: CommentModel, rhs: CommentModel) -> Bool {
        lhs.id == rhs.id
    }
}
