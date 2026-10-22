import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native table editing", .serialized)
struct NativeTableEditingTests {
    static let prefix = "Before 🧭\r\n\r\n| A deliberately wide first heading | A deliberately wide second heading |\r\n| :--- | ---: |\r\n"
    static let suffix = "\r\n\r\nAfter\r\n\r\n| X | Y |\r\n| --- | --- |\r\n| missing |\r\n| keep | raw\\|pipe | overflow |"
    static let source = prefix + "|   | old\\|value  |" + suffix

    @Test("rendered cell editing retains one native editor and source Undo follows cell A, cell B, then prose")
    func cellAndProseUndoOrder() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let first = try await editor.clickBodyCell()
        #expect(first.string.isEmpty)
        #expect(editor.main.string == Self.source)
        editor.replaceCell(first, with: "日本語 🧭")
        let afterA = Self.prefix + "| 日本語 🧭  | old\\|value  |" + Self.suffix
        #expect(editor.main.string == afterA)
        #expect(editor.state.controller.currentStorageText == afterA)
        #expect(first.string == "日本語 🧭")
        let anchor = (editor.main.string as NSString).range(of: "| A deliberately").location
        let activeImage = try #require(editor.main.textStorage?.attribute(
            .renderedBlockImage, at: anchor, effectiveRange: nil
        ) as? NSImage)
        let activePixels = try #require(activeImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(activePixels.width > 0 && activePixels.height > 0)
        #expect(first.convert(first.bounds, to: editor.scroll).intersects(editor.scroll.bounds))

        let second = try await editor.clickBodyCell(lastColumn: true)
        #expect(second === first, "Changing cells reuses the document's retained native input view")
        #expect(second.string == "old\\|value")
        editor.replaceCell(second, with: "second")
        let afterB = Self.prefix + "| 日本語 🧭  | second  |" + Self.suffix
        #expect(editor.main.string == afterB)

        editor.window.makeFirstResponder(editor.main)
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("Prose ", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.state.undo.endUndoGrouping()
        #expect(editor.main.string == "Prose " + afterB)
        for expected in [afterB, afterA, Self.source] {
            try #require(editor.state.undo.canUndo)
            editor.state.undo.undo()
            #expect(editor.main.string == expected)
        }
        #expect(!editor.state.undo.canUndo)
        for expected in [afterA, afterB, "Prose " + afterB] {
            try #require(editor.state.undo.canRedo)
            editor.state.undo.redo()
            #expect(editor.main.string == expected)
        }
        #expect(!editor.state.undo.canRedo)
    }

    @Test("a synchronous save seals cell edits and failed admission adds no Undo or stale cell state")
    func saveAndRejectedTransactions() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        editor.replaceCell(cell, with: "saved")
        let saved = Self.prefix + "| saved  | old\\|value  |" + Self.suffix
        #expect(editor.state.controller.commitPendingText() == saved)
        #expect(editor.state.text == saved)
        editor.replaceCell(cell, with: "later")
        let later = Self.prefix + "| later  | old\\|value  |" + Self.suffix
        #expect(editor.main.string == later)
        editor.state.undo.undo()
        #expect(editor.main.string == saved)
        #expect(cell.string == "saved")
        let selectionBeforeRejection = cell.selectedRange()
        let undoName = editor.state.undo.undoActionName
        #expect(!editor.state.controller.replaceCharacters(
            in: [NSRange(location: 0, length: 0)], with: "stale", expectedSource: Self.source
        ))
        #expect(editor.main.string == saved)
        #expect(cell.string == "saved")
        #expect(cell.selectedRange() == selectionBeforeRejection)
        #expect(editor.state.undo.undoActionName == undoName)
        try #require(editor.state.undo.canRedo, "Rejected stale admission must not clear Redo")
        editor.state.undo.redo()
        #expect(editor.main.string == later)

        // Exercise real source admission after a native input view has already
        // been obtained, so a missing input view cannot mask the read-only guard.
        try #require(cell.isEditable)
        editor.main.isEditable = false
        editor.replaceCell(cell, with: "denied")
        #expect(editor.main.string == later)
        #expect(cell.string == "later")
        // A refused cell ends editing and returns the keyboard with a caret after
        // the table, never a selection over the hidden cell source.
        await editor.settle()
        #expect(!editor.coordinator.tableEditingSession.isActive)
        #expect(editor.window.firstResponder === editor.main)
        #expect(editor.main.selectedRange().length == 0)
        editor.main.isEditable = true
        let resumed = try await editor.clickBodyCell()
        editor.replaceCell(resumed, with: "accepted")
        let accepted = Self.prefix + "| accepted  | old\\|value  |" + Self.suffix
        #expect(editor.main.string == accepted)
        editor.state.undo.undo()
        #expect(editor.main.string == later)
        editor.state.undo.undo()
        #expect(editor.main.string == saved)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("marked cell input leaves pure source reads unchanged until save synchronously finishes it")
    func markedCellSaveUsesCommittedSource() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        if #available(macOS 15.0, *) { #expect(cell.writingToolsBehavior == .none) }
        cell.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(cell.hasMarkedText())
        #expect(cell.string == "にほん")
        #expect(editor.main.string == Self.source)
        #expect(editor.state.controller.currentStorageText == Self.source)
        #expect(editor.state.controller.currentDisplayText == Self.source)
        #expect(!editor.state.controller.replaceCharacters(
            in: [NSRange(location: 0, length: 0)], with: "blocked", expectedSource: Self.source
        ))
        #expect(cell.hasMarkedText())
        let expected = Self.prefix + "| にほん  | old\\|value  |" + Self.suffix
        #expect(editor.state.controller.commitPendingText() == expected)
        #expect(!cell.hasMarkedText())
        #expect(cell.string == "にほん")
        #expect(editor.main.string == expected)
        #expect(editor.state.text == expected)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
        editor.state.undo.redo()
        #expect(editor.main.string == expected)
    }
    @Test("marked input finishes before hide, document replacement or dismantling", arguments: ["hide", "replacement", "dismantle"])
    func markedInputLifetime(boundary: String) async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        cell.setMarkedText("仮入力", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(cell.hasMarkedText())
        let expected = Self.prefix + "| 仮入力  | old\\|value  |" + Self.suffix
        let incoming = TableEditorState("Replacement document")
        switch boundary {
        case "hide":
            editor.wrapper.isDisplayed = false
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
            #expect(editor.scroll.isHidden)
            #expect(editor.window.firstResponder !== cell)
        case "replacement":
            let replacement = NativeTextViewWrapper(
                text: Binding(get: { incoming.text }, set: { incoming.text = $0 }),
                documentId: "replacement", editorController: incoming.controller, undoManager: incoming.undo
            )
            replacement.updateNativeView(editor.scroll, coordinator: editor.coordinator)
            #expect(editor.main.string == "Replacement document")
        default:
            NativeTextViewWrapper.dismantleNSView(editor.scroll, coordinator: editor.coordinator)
        }
        await editor.settle()
        #expect(!cell.hasMarkedText())
        #expect(editor.state.text == expected)
        if boundary == "replacement" {
            cell.insertText("stale", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.main.string == "Replacement document")
            #expect(incoming.text == "Replacement document")
            #expect(!incoming.undo.canUndo)
        }
    }

    @Test("encoded pipe and line-break input keeps the native buffer and UTF-16 caret on the admitted source")
    func encodedCellCaretMatchesSource() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        editor.replaceCell(cell, with: "new|🧭\r\nline")
        let encoded = "new\\|🧭<br>line"
        let expected = Self.prefix + "| " + encoded + "  | old\\|value  |" + Self.suffix
        #expect(editor.main.string == expected)
        // The editor shows the line break the source writes as `<br>`.
        #expect(cell.string == "new\\|🧭\nline")
        #expect(cell.selectedRange() == NSRange(location: 12, length: 0))
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        editor.state.undo.redo()
        #expect(editor.main.string == expected)
    }

    @Test("a narrow raster table opens an in-place native cell without a horizontal overlay")
    func narrowTableNativeHit() async throws {
        let source = "Before\n\n| A | B |\n| --- | --- |\n|  | x |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        try #require(editor.main.wideTableOverlays.isEmpty)
        let storage = try #require(editor.main.textStorage)
        let anchor = (source as NSString).range(of: "| A").location
        let image = try #require(storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage)
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try #require(pixels.width > 0 && pixels.height > 0)
        let bridge = try #require(editor.main.layoutBridge)
        let container = try #require(bridge.firstTextContainer)
        let anchorRect = bridge.boundingRect(forCharacterRange: NSRange(location: anchor, length: 1), in: container)
        let imageRect = NSRect(x: editor.main.textContainerOrigin.x + anchorRect.minX,
                               y: editor.main.textContainerOrigin.y + anchorRect.midY - image.size.height / 2,
                               width: image.size.width, height: image.size.height)
        try #require(try editor.routeClick(at: NSPoint(x: imageRect.minX + 10, y: imageRect.maxY - 10)))
        let cell = try #require(editor.window.firstResponder as? NSTextView)
        try #require(cell !== editor.main)
        #expect(cell.string.isEmpty)
        #expect(imageRect.contains(editor.main.convert(cell.bounds, from: cell)))
        editor.replaceCell(cell, with: "inside")
        #expect(editor.main.string == "Before\n\n| A | B |\n| --- | --- |\n| inside | x |\n\nAfter")
        // The grid draws the edited text and no source glyphs leak around it.
        let bitmap = try #require(editor.main.bitmapImageRepForCachingDisplay(in: imageRect))
        editor.main.cacheDisplay(in: imageRect, to: bitmap)
        var inked = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.brightnessComponent < 0.5 { inked += 1 }
            }
        }
        #expect(inked > 20, "The cell's text and borders are drawn")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("moving the same native surface between windows retains marked cell input")
    func transferRetainsMarkedInput() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        cell.setMarkedText("候補", selectedRange: NSRange(location: 1, length: 1),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(cell.hasMarkedText())
        let selection = cell.selectedRange()
        let destination = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        destination.animationBehavior = .none
        defer { destination.close() }
        editor.scroll.removeFromSuperview()
        destination.contentView = editor.scroll
        destination.orderBack(nil)
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        try #require(cell.acceptsFirstResponder)
        destination.makeFirstResponder(cell)
        #expect(destination.firstResponder === cell)
        #expect(cell.hasMarkedText())
        #expect(cell.selectedRange() == selection)
        #expect(editor.main.string == Self.source)
        #expect(!editor.state.undo.canUndo)
        cell.insertText("確定", replacementRange: NSRange(location: NSNotFound, length: 0))
        let expected = Self.prefix + "| 確定  | old\\|value  |" + Self.suffix
        #expect(editor.main.string == expected)
        editor.state.undo.undo()
        #expect(editor.main.string == Self.source)
        editor.state.undo.redo()
        #expect(editor.main.string == expected)
    }


    @Test("a narrow table that turns wide mid-edit keeps the keyboard in the cell")
    func narrowTurnsWideKeepsKeyboard() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let cell = try editor.clickRenderedCell(inTableContaining: "| A", row: 1, column: 1)
        try #require(cell === session.editor)
        try #require(editor.main.wideTableOverlays.isEmpty)
        for _ in 0..<12 { cell.insertText("wide words ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        try await Task.sleep(for: .milliseconds(450))
        await editor.settle()
        #expect(!editor.main.wideTableOverlays.isEmpty, "the table re-rendered wide")
        #expect(editor.window.firstResponder === session.editor)
        session.editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.main.string.contains("wide words !"))
    }

    @Test("editing preserves the header fill without an inset input box", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func activeCellPreservesHeaderFill(appearanceName: NSAppearance.Name) async throws {
        let source = "Intro\n\n| 观察 | B |\n| --- | --- |\n| a long body value to keep the first column generous | 2 |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        editor.main.appearance = NSAppearance(named: appearanceName)
        _ = try editor.focusCell(inTableContaining: "| 观察", row: 0, column: 0)
        let session = editor.coordinator.tableEditingSession
        let grid = try #require(session.editor.enclosingScrollView?.superview as? MarkdownTableGridView)
        let cell = grid.geometry.cellRects[0][0]
        let image = try #require(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / grid.bounds.width
        func color(_ x: CGFloat) throws -> NSColor {
            try #require(image.colorAt(x: Int(x * scale), y: Int(cell.midY * scale))?.usingColorSpace(.sRGB))
        }
        let padding = try color(cell.maxX - 3)
        let input = try color(cell.maxX - MarkdownTableLayout.horizontalPadding - 3)
        let difference = abs(padding.redComponent - input.redComponent)
            + abs(padding.greenComponent - input.greenComponent) + abs(padding.blueComponent - input.blueComponent)
        #expect(difference < 0.02, "the editable content and header padding must paint the same surface")
        #expect(editor.main.string == source)
        // Clearing the live editor must also erase the raster text beneath it.
        // Sample beyond the caret, including the former CJK glyphs, before the
        // 300 ms raster timer can fire.
        editor.replaceCell(session.editor, with: "")
        let cleared = try #require(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
        grid.cacheDisplay(in: grid.bounds, to: cleared)
        var largestDifference: CGFloat = 0
        for x in stride(from: Int(20 * scale), to: Int((cell.maxX - 12) * scale), by: 2) {
            for y in stride(from: Int((cell.minY + 8) * scale), to: Int((cell.maxY - 8) * scale), by: 2) {
                let color = try #require(cleared.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                largestDifference = max(largestDifference,
                    abs(color.redComponent - padding.redComponent) + abs(color.greenComponent - padding.greenComponent)
                    + abs(color.blueComponent - padding.blueComponent))
            }
        }
        #expect(largestDifference < 0.02, "clearing a cell must leave no duplicate glyphs from its raster")
    }

    @Test("shrinking a column removes old border lines before the deferred render")
    func shrinkingColumnDoesNotLeaveOldRasterBorders() async throws {
        let source = "Intro\n\n| Longest heading that sets the width |\n| --- |\n| x |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "| Longest", row: 0, column: 0)
        let anchor = (editor.main.string as NSString).range(of: "| Longest").location
        let oldImage = try #require(editor.main.textStorage?.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage)
        editor.replaceCell(cell, with: "观察")
        let grid = try #require(cell.enclosingScrollView?.superview as? MarkdownTableGridView)
        try #require(grid.geometry.size.width < oldImage.size.width)
        let image = try #require(editor.main.textStorage?.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage)
        #expect(image.size.width == grid.geometry.size.width,
                "a narrower live grid must not expose the old raster's column borders")
        #expect(editor.main.string == source.replacingOccurrences(of: "Longest heading that sets the width", with: "观察"))
    }

    @Test("a live table preserves input through scrolling after its column shrinks", arguments: [false, true])
    func editedTableSurvivesScrollOutAndBack(composing: Bool) async throws {
        let source = "Intro\n\n| Longest heading that sets the width |\n| --- |\n| x |\n\n" + String(repeating: "Ordinary prose after the table.\n\n", count: 100)
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "| Longest", row: 0, column: 0)
        editor.replaceCell(cell, with: "观察")
        let committed = source.replacingOccurrences(of: "Longest heading that sets the width", with: "观察")
        if composing {
            cell.setMarkedText("候選", selectedRange: NSRange(location: 1, length: 1),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            try #require(cell.hasMarkedText())
        }
        let selection = cell.selectedRange()
        let input = cell.string
        let session = editor.coordinator.tableEditingSession
        let origin = editor.scroll.contentView.bounds.origin
        for offset: CGFloat in [30, 700, 0] {
            editor.scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + offset))
            editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
            await editor.settle()
            #expect(abs(editor.scroll.contentView.bounds.origin.y - (origin.y + offset)) < 1,
                    "remounting the cell must not undo the user's scroll")
            #expect(cell.hasMarkedText() == composing)
            #expect(cell.selectedRange() == selection)
            #expect(cell.string == input)
            #expect(editor.main.string == committed, "scrolling must not commit provisional input")
        }
        try #require(session.isActive)
        let grid = try #require(session.editor.enclosingScrollView?.superview as? MarkdownTableGridView)
        #expect(grid.visibleRect.height > 0)
        let anchor = (editor.main.string as NSString).range(of: "| 观察").location
        let image = try #require(editor.main.textStorage?.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage)
        #expect(image.size == grid.geometry.size)
        if composing { session.editor.insertText("確認", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        session.editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!cell.hasMarkedText())
        #expect(editor.main.string == source.replacingOccurrences(
            of: "Longest heading that sets the width", with: composing ? "观察確認!" : "观察!"
        ))
    }

    @Test("the grid draws nothing outside its bounds")
    func gridDrawsInsideItsBounds() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        _ = try editor.clickRenderedCell(inTableContaining: "| A", row: 1, column: 0)
        let grid = try #require(editor.main.subviews.compactMap { $0 as? MarkdownTableGridView }.first)
        #expect(grid.clipsToBounds)
        let margin: CGFloat = 20
        let size = NSSize(width: grid.bounds.width + margin * 2, height: grid.bounds.height + margin * 2)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: margin, y: margin)
        grid.draw(NSRect(x: -margin, y: -margin, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        #expect(bitmap.colorAt(x: 2, y: 2)?.alphaComponent == 0, "outside the grid stays untouched")
        #expect(bitmap.colorAt(x: Int(size.width / 2), y: Int(size.height / 2))?.alphaComponent ?? 0 > 0)
    }

    @Test("a double-click selects a word in the cell; Shift-click from prose leaves the table rendered")
    func doubleAndShiftClicks() async throws {
        let source = "Intro\n\n| A | B |\n| --- | --- |\n| hello world | 2 |\n\nAfter"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let session = editor.coordinator.tableEditingSession
        let point = try editor.renderedCellPoint(inTableContaining: "| A", row: 1, column: 0)
        #expect(try !editor.routeClick(at: point, modifiers: .shift), "Shift-click from prose is native text selection")
        #expect(!session.isActive)
        #expect(try editor.routeClick(at: point, clickCount: 2))
        #expect(session.isActive)
        let selected = (session.editor.string as NSString).substring(with: session.editor.selectedRange())
        #expect(selected == "hello" || selected == "world")
    }

    @Test("⌘Z in a cell reaches the document's Undo history")
    func cellUndoManagerIsTheDocuments() async throws {
        let editor = try MountedTableEditor(source: Self.source)
        defer { editor.close() }
        let cell = try await editor.clickBodyCell()
        // The app's Edit menu drives the tab's manager; AppKit asks the cell's delegate.
        #expect(editor.coordinator.tableEditingSession.undoManager(for: cell) === editor.state.undo)
    }
}
