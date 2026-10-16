//
//  FindOverlayPlacementTests.swift
//  PageFlowTests
//
//  The Find bar, with or without its replacement row, sits at the bottom
//  center of the document on every tab, whatever the host's own alignment.
//

import AppKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
struct FindOverlayPlacementTests {
    private struct Host: View {
        let driver: MarkdownSearchManager
        @State var showing = true
        var body: some View {
            // The Markdown tab stacks its layers from the top.
            ZStack(alignment: .top) {
                Color.clear
                FindOverlay(driver: driver, isActive: true, showingSearch: $showing, focusRequest: 0)
            }
            .frame(width: 900, height: 600)
        }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(fields(in:))
    }

    @Test(arguments: [false, true])
    func theBarSitsAtTheBottomCenter(showingReplacement: Bool) throws {
        _ = NSApplication.shared
        let content = MarkdownContent(documentId: UUID().uuidString)
        content.searchManager.setShowingReplacement(showingReplacement)
        let hosting = NSHostingView(rootView: Host(driver: content.searchManager))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let found = fields(in: hosting)
        try #require(found.count == (showingReplacement ? 2 : 1))
        for field in found {
            let frame = field.convert(field.bounds, to: hosting)
            let fromBottom = hosting.isFlipped ? hosting.bounds.height - frame.maxY : frame.minY
            #expect(fromBottom < 120, "the bar hugs the bottom edge")
        }
        let search = try #require(found.first { $0.placeholderString == "Search" } ?? found.first)
        let frame = search.convert(search.bounds, to: hosting)
        #expect(abs(frame.midX - hosting.bounds.midX) < 160, "the bar is centered horizontally")
    }
}
