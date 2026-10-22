import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's lane (doc 24 §5.2.2–3, §8.6): with a reading column, a table
/// wider than the column grows into the right margin; while it fits there it
/// has nothing to scroll and reserves no scroller strip.
@MainActor
@Suite("Table lane", .serialized)
struct TableLaneTests {
    static let source: String = {
        let header = "| " + (0..<5).map { "Heading \($0) here" }.joined(separator: " | ") + " |"
        let delimiter = "|" + String(repeating: " --- |", count: 5)
        let body = "| " + (0..<5).map { "value \($0) text" }.joined(separator: " | ") + " |"
        return "Intro\n\n" + [header, delimiter, body].joined(separator: "\n") + "\n\nAfter"
    }()

    private func strip(_ editor: MountedTableEditor) throws -> CGFloat {
        let storage = try #require(editor.main.textStorage)
        var result: CGFloat?
        storage.enumerateAttribute(.scrollableBlockTotalHeight, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let total = value as? CGFloat,
                  let image = storage.attribute(.renderedBlockImage, at: range.location, effectiveRange: nil) as? NSImage else { return }
            result = total - image.size.height
            stop.pointee = true
        }
        return try #require(result, "the table is hosted as a wide table")
    }

    @Test("a table that fits the lane reserves no strip; narrowing the window brings the strip back")
    func laneStrip() async throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 300
        let editor = try MountedTableEditor(source: Self.source, configuration: configuration)
        defer { editor.close() }
        editor.window.setContentSize(NSSize(width: 1_400, height: 650))
        await editor.settle()
        editor.coordinator.restyleTableNow((Self.source as NSString).range(of: "| Heading 0"))
        await editor.settle()
        #expect(try strip(editor) == 0, "wider than the column, within the lane")
        editor.window.setContentSize(NSSize(width: 560, height: 650))
        // The overlay reconcile and the restyle it asks for run on the main queue.
        // As a live resize does: the column re-centres, the overlays follow.
        editor.main.centerReadingColumn(forClipWidth: editor.scroll.contentView.bounds.width)
        for _ in 0..<4 {
            await editor.settle()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(try strip(editor) == MarkdownTextLayoutFragment.scrollableBlockScrollerStrip, "too wide for the lane now: it scrolls")
    }
}
