//
//  TableOverlaySourceEditTests.swift
//  MarkdownEngineTests
//
//  A table too wide for the column renders in a horizontal-scroll overlay;
//  editing it still goes through the one cell editor and the source
//  transaction (ADR-0024), touching only the edited cell's bytes.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table overlay source edits", .serialized)
struct TableOverlaySourceEditTests {
    private static let header = (1...12).map { "Column \($0) heading" }
    private static let source = "before\n\n| " + header.joined(separator: " | ") + " |\n|"
        + String(repeating: " --- |", count: header.count) + "\n| one | "
        + (2...header.count).map { "v\($0)" }.joined(separator: " | ") + " |\n\nafter"

    @Test func editingAWideTableCellOnlyTouchesThatCell() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        await editor.settle()
        #expect(editor.main.textStorage?.attribute(
            .scrollableBlockSourceID,
            at: (Self.source as NSString).range(of: "| Column 1").location,
            effectiveRange: nil
        ) != nil, "the table is wide enough to scroll in an overlay")

        let cell = try editor.focusCell(inTableContaining: "| Column 1", row: 1, column: 0)
        editor.replaceCell(cell, with: "changed")

        #expect(editor.main.string == Self.source.replacingOccurrences(of: "| one |", with: "| changed |"))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
    }
}
