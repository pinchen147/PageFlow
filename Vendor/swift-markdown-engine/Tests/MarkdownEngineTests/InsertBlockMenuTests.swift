import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's Insert block menu (doc 24 §5.4.8): a right-click on a line
/// with no text offers blocks; a line with text keeps the native menu.
@MainActor
@Suite("Insert block menu", .serialized)
struct InsertBlockMenuTests {
    private func mount(_ source: String) throws -> MountedTableEditor {
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        return try MountedTableEditor(source: source, configuration: configuration)
    }

    private func menus(_ editor: MountedTableEditor) -> [TableMenuView] {
        editor.scroll.subviews.compactMap { $0 as? TableMenuView }
    }

    @Test("an empty line opens Insert block; choosing Table inserts one there")
    func emptyLine() async throws {
        let editor = try mount("First\n\nSecond")
        defer { editor.close() }
        #expect(editor.coordinator.showInsertBlockMenu(for: nil, at: 6, in: editor.main))
        let menu = try #require(menus(editor).first)
        #expect(menu.titles == ["Heading 1", "Heading 2", "Heading 3", "Table", "—", "Bulleted list", "Checklist", "Code block",
                                "Divider", "Numbered list", "Quote"])
        menu.activate(title: "Table")
        #expect(editor.main.string.contains("|"))
        #expect(editor.main.string.hasPrefix("First\n"))
        #expect(editor.main.string.hasSuffix("Second"))
    }

    @Test("a line with text keeps the native menu; after a list item Quote is left out")
    func textLineAndListContext() async throws {
        let editor = try mount("Words here\n- item\n\n")
        defer { editor.close() }
        #expect(!editor.coordinator.showInsertBlockMenu(for: nil, at: 2, in: editor.main))
        #expect(menus(editor).isEmpty)
        #expect(editor.coordinator.showInsertBlockMenu(for: nil, at: 18, in: editor.main))
        let menu = try #require(menus(editor).first)
        #expect(!menu.titles.contains("Quote"))
        menu.close(.dismissed)
    }

    @Test("with an image hook, Image inserts the chosen picture on the empty line")
    func image() async throws {
        let editor = try mount("First\n\nSecond")
        defer { editor.close() }
        #expect(editor.coordinator.showInsertBlockMenu(for: nil, at: 6, in: editor.main))
        #expect(!(menus(editor).first?.titles.contains("Image") ?? true), "no hook, no Image row")
        menus(editor).first?.close(.dismissed)
        var received: URL?
        editor.main.onPasteImage = { board in
            received = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
            return "![](assets/picked.png)"
        }
        #expect(editor.coordinator.showInsertBlockMenu(for: nil, at: 6, in: editor.main))
        let menu = try #require(menus(editor).first)
        #expect(menu.titles == ["Heading 1", "Heading 2", "Heading 3", "Table", "—", "Bulleted list", "Checklist", "Code block",
                                "Divider", "Image", "Numbered list", "Quote"])
        menu.close(.dismissed)
        editor.state.undo.beginUndoGrouping()
        editor.main.insertImageFromPicker(at: 6) { URL(fileURLWithPath: "/tmp/picked.png") }
        editor.state.undo.endUndoGrouping()
        #expect(received?.lastPathComponent == "picked.png")
        #expect(editor.main.string.contains("![](assets/picked.png)"))
        #expect(editor.main.string.hasPrefix("First\n") && editor.main.string.hasSuffix("Second"))
    }
}
