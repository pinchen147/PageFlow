import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's docked table scroller (doc 24 §5.2.4).
@MainActor
@Suite("Docked table scroller", .serialized)
struct TableProxyScrollerTests {
    private func source() -> String {
        let header = "| " + (0..<8).map { "Column heading number \($0)" }.joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: " --- |", count: 8)
        let rows = (0..<60).map { r in "| " + (0..<8).map { "value \(r) in column \($0)" }.joined(separator: " | ") + " |" }
        return "Intro\n\n" + ([header, delimiter] + rows).joined(separator: "\n") + "\n\nAfter"
    }

    @Test("it shows only while the table's own scroller is below the window, and follows the table both ways")
    func dockedScroller() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: source(), configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        let proxy = try #require(editor.coordinator.tableProxy)
        let overlay = try #require(editor.main.wideTableOverlays.values.first)
        proxy.update()
        #expect(!proxy.scroller.isHidden, "the table runs past the window's bottom")
        #expect(proxy.overlay === overlay)
        for step in 1...20 {
            overlay.horizontalOffset = CGFloat(step * 13)
            proxy.tableDidScroll(overlay)
            let range = (overlay.documentView?.frame.width ?? 0) - overlay.contentView.bounds.width
            #expect(abs(proxy.scroller.doubleValue * range - overlay.horizontalOffset) < 1)
        }
        proxy.scroller.doubleValue = 0.5
        _ = proxy.scroller.sendAction(proxy.scroller.action, to: proxy.scroller.target)
        let range = (overlay.documentView?.frame.width ?? 0) - overlay.contentView.bounds.width
        #expect(abs(overlay.horizontalOffset - range * 0.5) < 1, "the table follows the docked scroller")
        // Scrolled to the end, the table's own scroller is in view: no docked copy.
        editor.main.scrollToEndOfDocument(nil)
        await editor.settle()
        proxy.update()
        #expect(proxy.scroller.isHidden)
    }
}
