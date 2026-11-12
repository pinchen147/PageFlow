//
//  EPUBLandmarkRows.swift
//  PageFlow
//
//  The book's landmarks (cover, contents, start of the text…) under the
//  Contents list: a short way to its structural places.
//

import EPUBKit
import SwiftUI

struct EPUBLandmarkRows: View {
    let landmarks: [EPUBLandmark]
    let select: (EPUBLandmark) -> Void

    var body: some View {
        Text("Landmarks")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, DesignTokens.spacingMD)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        ForEach(landmarks) { landmark in
            Button {
                select(landmark)
            } label: {
                Label(landmark.title, systemImage: Self.symbol(for: landmark.type))
                    .lineLimit(1)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .help(landmark.title)
        }
    }

    static func symbol(for type: String) -> String {
        switch type.lowercased() {
        case "cover": "book.closed"
        case "toc": "list.bullet"
        case "bodymatter", "text", "start": "text.alignleft"
        case "index", "glossary": "character.book.closed"
        case "loi": "photo"
        case "lot": "tablecells"
        default: "bookmark"
        }
    }
}
