import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Collapsed section dragging", .serialized)
struct CollapsedSectionDragTests {
    private let section = "# Folded\n\nAlpha e\u{301} 😀\n\n## Nested\n\nHidden child\n\n## Open child\n\nVisible when parent opens"
    private let destination = "# Destination\n\nDestination body"
    private let unrelated = "# Unrelated\n\nUnrelated body"
    private let end = "# End\n\nEnd body"

    private func close(_ title: String, in editor: MountedTableEditor) throws {
        let location = (editor.main.string as NSString).range(of: title).location
        #expect(editor.coordinator.performFolding(.toggleFold, heading: location))
    }

    private func closedOffsets(in source: String) -> Set<Int> {
        Set(["# Folded", "## Nested", "# Unrelated"].map { (source as NSString).range(of: $0).location })
    }

    @Test("a collapsed heading grip moves its entire section and retains nested folds through Undo", arguments: [false, true])
    func moveSection(_ upward: Bool) async throws {
        let source = destination + "\n\n" + section + "\n\n" + unrelated + "\n\n" + end
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        try close("## Nested", in: editor)
        try close("# Unrelated", in: editor)
        try close("# Folded", in: editor)
        await editor.settle()
        let region = try #require(editor.coordinator.foldControls?.accessibilityControls.first {
            $0.accessibilityLabel()?.hasPrefix("Expand Folded") == true
        })
        editor.coordinator.blockMover.hover(at: NSPoint(x: editor.main.textContainerOrigin.x + 35,
                                                       y: region.frame.midY))
        let entry = try #require(editor.coordinator.blockMover.hovered)
        #expect(entry.kind == .heading)
        #expect(entry.range == (source as NSString).range(of: section))
        let payload = try #require(editor.coordinator.blockMovePayload(range: entry.range, kind: entry.kind))
        #expect(payload.markdown.source == section)
        let target = upward ? 0 : (source as NSString).range(of: "# End").location
        #expect(editor.coordinator.moveBlock(payload, to: target))
        await editor.settle()
        let moved = upward ? section + "\n\n" + destination + "\n\n" + unrelated + "\n\n" + end
            : destination + "\n\n" + unrelated + "\n\n" + section + "\n\n" + end
        #expect(editor.main.string == moved)
        #expect(editor.coordinator.foldSession.collapsedHeadings == closedOffsets(in: moved))
        let movedBody = (moved as NSString).range(of: "Hidden child").location
        #expect(editor.coordinator.foldLayout.hiddenRange(containing: movedBody) != nil)
        editor.state.undo.undo()
        await editor.settle()
        #expect(editor.main.string == source)
        #expect(editor.coordinator.foldSession.collapsedHeadings == closedOffsets(in: source))
        #expect(!editor.state.undo.canUndo, "moving a folded section is one Undo")
        editor.state.undo.redo()
        await editor.settle()
        #expect(editor.main.string == moved)
        #expect(editor.coordinator.foldSession.collapsedHeadings == closedOffsets(in: moved))
    }

    @Test("a final collapsed section preserves CRLF source and Undo", arguments: [false, true])
    func finalSection(_ terminated: Bool) async throws {
        let section = "# Folded\r\n\r\nBody\r\n\r\n## Nested\r\n\r\nChild"
        let prefix = "# First\r\n\r\nBefore"
        let source = prefix + "\r\n\r\n" + section + (terminated ? "\r\n" : "")
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        try close("## Nested", in: editor)
        try close("# First", in: editor)
        try close("# Folded", in: editor)
        let payload = try #require(editor.coordinator.blockMovePayload(
            range: (source as NSString).range(of: "# Folded"), kind: .heading))
        #expect(payload.markdown.source == section)
        #expect(editor.coordinator.moveBlock(payload, to: 0))
        await editor.settle()
        #expect(editor.main.string.hasPrefix(section))
        #expect(editor.coordinator.foldSession.collapsedHeadings == Set([0, (section as NSString).range(of: "## Nested").location,
            (editor.main.string as NSString).range(of: "# First").location]))
        editor.state.undo.undo()
        await editor.settle()
        #expect(editor.main.string == source)
        #expect(editor.coordinator.foldSession.collapsedHeadings == Set([0,
            (source as NSString).range(of: "# Folded").location,
            (source as NSString).range(of: "## Nested").location]))
    }

    @Test("folded section copy transfers collapse state, including after image-path rebasing", arguments: [false, true])
    func copySection(_ crossEditor: Bool) async throws {
        struct Images: EmbeddedImageProvider {
            let baseFolderURL: URL?
            func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
            func fingerprint() -> AnyHashable { baseFolderURL?.path ?? "none" }
        }
        let section = "# Folded\n\n![picture](pic.png)\n\n## Nested\n\nHidden child"
        let source = section + "\n\n# End\n\nTail"
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.images = Images(baseFolderURL: URL(fileURLWithPath: "/notes/source"))
        let original = try MountedTableEditor(source: source, configuration: configuration)
        defer { original.close() }
        await original.settle()
        try close("## Nested", in: original)
        try close("# Folded", in: original)
        let payload = try #require(original.coordinator.blockMovePayload(range: (source as NSString).range(of: section), kind: .heading))
        // Exercise portable metadata, not a shared in-memory payload object.
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        payload.write(to: item)
        board.writeObjects([item])
        let transferred = try #require(BlockMovePasteboard.read(from: board))
        configuration.services.images = Images(baseFolderURL: URL(fileURLWithPath: "/notes/target"))
        let other = try MountedTableEditor(source: "# Target\n\nBody", configuration: configuration)
        defer { other.close() }
        await other.settle()
        let target = crossEditor ? other : original
        let before = target.main.string
        #expect(target.coordinator.moveBlock(transferred, to: 0, copying: true))
        await target.settle()
        let copied = crossEditor ? section.replacingOccurrences(of: "(pic.png)", with: "(/notes/source/pic.png)") : section
        let expected = copied + "\n\n" + before
        #expect(target.main.string == expected)
        let nested = (expected as NSString).range(of: "## Nested").location
        #expect(target.coordinator.foldSession.collapsedHeadings.contains(0))
        #expect(target.coordinator.foldSession.collapsedHeadings.contains(nested))
        if crossEditor { #expect(original.main.string == source) }
        target.state.undo.undo()
        await target.settle()
        #expect(target.main.string == before)
        if !crossEditor {
            #expect(target.coordinator.foldSession.collapsedHeadings == Set([0, (source as NSString).range(of: "## Nested").location]))
        }
        target.state.undo.redo()
        await target.settle()
        #expect(target.main.string == expected)
        #expect(target.coordinator.foldSession.collapsedHeadings.contains(0))
        #expect(target.coordinator.foldSession.collapsedHeadings.contains(nested))
    }
}
