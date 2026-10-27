import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Canonical section navigation", .serialized)
struct SectionNavigationTests {
    private func mount(_ source: String, configuration: MarkdownEditorConfiguration = .default,
                       magnification: CGFloat? = nil) throws -> MountedTableEditor {
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        if let magnification {
            editor.wrapper.magnificationRange = 0.5...4
            editor.wrapper.magnification = magnification
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        }
        editor.state.controller.isSectionNavigationEnabled = true
        editor.main.ensureVisibleLayout()
        return editor
    }

    @Test("Targets use canonical empty, duplicate and Unicode CRLF headings")
    func canonicalTargets() throws {
        let source = "preamble\r\n# \r\n# Same\r\n## Same\r\n### 日本 e\u{301} 👩🏽‍💻\r\n```\r\n# fenced\r\n```\r\n#\r\n##\tinvalid\r\n####### invalid\r\nSetext\r\n======\r\n# Last\r\nbody"
        let editor = try mount(source)
        defer { editor.close() }
        let snapshot = try #require(editor.state.controller.sectionNavigationSnapshot)
        #expect(snapshot.targets.map(\.title) == ["Untitled heading", "Same", "Same", "日本 e\u{301} 👩🏽‍💻", "Last"])
        #expect(snapshot.targets.map(\.rank) == [0, 1, 2, 3, 4])
        #expect(snapshot.targets.map(\.level) == [1, 1, 2, 3, 1])
        #expect(Set(snapshot.targets).count == 5)
        #expect(editor.state.controller.sectionPreview(for: snapshot.targets[1])?.body == "")
        #expect(editor.state.controller.sectionPreview(for: snapshot.targets[4])?.body == "body")
    }

    @Test("Preview bounds UTF-16 at Unicode boundaries and stays inside its section")
    func boundedPreview() throws {
        let title = String(repeating: "é", count: 159) + "👩🏽‍💻tail"
        let source = "# " + title + "\r\n" + String(repeating: "x", count: 2047) + "😀tail\r\n# Next\r\nprivate next body"
        let editor = try mount(source)
        defer { editor.close() }
        let target = try #require(editor.state.controller.sectionNavigationSnapshot?.targets.first)
        let preview = try #require(editor.state.controller.sectionPreview(for: target))
        #expect(preview.title == String(repeating: "é", count: 159))
        #expect(preview.body == String(repeating: "x", count: 2047))
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
    }

    @Test("Edit then Undo to identical bytes retires old targets")
    func sourceRevisionSurvivesUndo() async throws {
        let source = "# A\nbody\n# B\ntail"
        let editor = try mount(source)
        defer { editor.close() }
        let controller = editor.state.controller
        let old = try #require(controller.sectionNavigationSnapshot?.targets.last)
        editor.state.undo.beginUndoGrouping()
        editor.main.insertText("change", replacementRange: NSRange(location: source.utf16.count, length: 0))
        editor.main.breakUndoCoalescing()
        editor.state.undo.endUndoGrouping()
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(controller.sectionPreview(for: old) == nil)
        var departures = 0
        controller.scrollToSection(old, whileValid: { true }, didNavigate: { _ in departures += 1 })
        #expect(departures == 0)
        for _ in 0..<100 where controller.sectionNavigationSnapshot == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.sectionNavigationSnapshot?.targets.map(\.title) == ["A", "B"])
    }

    @Test("Re-enabling publication during marked replacement waits for committed heading offsets")
    func publicationDuringMarkedReplacement() async throws {
        let editor = try mount("# First\nBody text.\n# Second\nMore body.\n")
        defer { editor.close() }
        let controller = editor.state.controller
        let previous = try #require(controller.sectionNavigationSnapshot)
        try #require(previous.targets.count == 2)
        let generation = editor.coordinator.nativeSourceGeneration
        let replacement = NSRange(location: 0, length: editor.main.string.utf16.count)
        editor.state.undo.beginUndoGrouping()
        editor.main.setSelectedRange(replacement)
        editor.main.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: replacement)
        try #require(editor.main.hasMarkedText())
        try #require(editor.main.string == "a")
        try #require(editor.coordinator.nativeSourceGeneration == generation)
        let selection = editor.main.selectedRanges
        controller.isSectionNavigationEnabled = false
        controller.isSectionNavigationEnabled = true
        #expect(controller.sectionNavigationSnapshot == nil)
        #expect(editor.main.hasMarkedText())
        #expect(editor.main.selectedRanges == selection)
        #expect(editor.main.string == "a")

        editor.main.insertText("# Committed\nbody\n", replacementRange: editor.main.markedRange())
        editor.state.undo.endUndoGrouping()
        for _ in 0..<100 where controller.sectionNavigationSnapshot == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.sectionNavigationSnapshot?.targets.map(\.title) == ["Committed"])
        #expect(controller.sectionPreview(for: previous.targets[0]) == nil)
    }

    @Test("Hidden, disabled, rebound and detached editors retire targets")
    func lifecycleInvalidatesTargets() throws {
        let editor = try mount("# A\nbody\n# B\ntail")
        defer { editor.close() }
        let controller = editor.state.controller
        let old = try #require(controller.sectionNavigationSnapshot?.targets.first)
        editor.wrapper.isDisplayed = false
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        #expect(controller.sectionNavigationSnapshot == nil)
        editor.wrapper.isDisplayed = true
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        #expect(controller.sectionPreview(for: old) == nil)
        let current = try #require(controller.sectionNavigationSnapshot?.targets.first)
        controller.isSectionNavigationEnabled = false
        #expect(controller.sectionNavigationSnapshot == nil)
        controller.isSectionNavigationEnabled = true
        let rebound = MarkdownEditorController()
        rebound.isSectionNavigationEnabled = true
        editor.wrapper.editorController = rebound
        editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        #expect(controller.sectionNavigationSnapshot == nil)
        #expect(rebound.sectionPreview(for: current) == nil)
        let detached = try #require(rebound.sectionNavigationSnapshot?.targets.first)
        editor.scroll.removeFromSuperview()
        #expect(rebound.sectionNavigationSnapshot == nil)
        editor.window.contentView = editor.scroll
        #expect(rebound.sectionPreview(for: detached) == nil)
    }

    @Test("Visible membership excludes folded children and includes all visible sections")
    func foldedVisibility() throws {
        let editor = try mount("# A\nbody\n## Child\nchild body\n# B\ntail\n")
        defer { editor.close() }
        let controller = editor.state.controller
        #expect(controller.sectionNavigationSnapshot?.visibleRanks == [0, 1, 2])
        editor.main.setSelectedRange(NSRange(location: 0, length: 0))
        try #require(controller.performFoldingCommand(.toggleFold))
        #expect(controller.sectionNavigationSnapshot?.visibleRanks == [0, 2])
        let child = try #require(controller.sectionNavigationSnapshot?.targets[1])
        controller.scrollToSection(child, whileValid: { true }, didNavigate: { _ in })
        #expect(editor.coordinator.foldLayout.hiddenRanges.isEmpty)
        #expect(editor.main.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test("Activation clears top chrome at every zoom, preserves input and records one departure",
          arguments: [CGFloat(1), CGFloat(0.5), CGFloat(1.75)])
    func neutralActivation(magnification: CGFloat) async throws {
        let source = "# A\nneedle\n" + String(repeating: "paragraph\n\n", count: 80)
            + "# B\nmiddle body\n" + String(repeating: "trailing paragraph\n\n", count: 80) + "# C\ntail\n"
        var configuration = MarkdownEditorConfiguration.default
        configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
        let editor = try mount(source, configuration: configuration, magnification: magnification)
        defer { editor.close() }
        // Test a settled native zoom, rather than its 200 ms deferred re-fit.
        let scroll = try #require(editor.scroll as? ClampedScrollView)
        for _ in 0..<100 where editor.main.pendingZoomRefit || scroll.isZoomInProgress {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!editor.main.pendingZoomRefit && !scroll.isZoomInProgress)
        await editor.settle()
        let controller = editor.state.controller
        let target = try #require(controller.sectionNavigationSnapshot?.targets[1])
        let needle = (source as NSString).range(of: "needle")
        editor.coordinator.handleFindScrollToRange(Notification(name: .init("test.find"), object: editor.coordinator.documentId,
            userInfo: ["range": needle, "currentIndex": 0, "allRanges": [needle]]))
        editor.main.setSelectedRange(NSRange(location: 2, length: 3))
        let selection = editor.main.selectedRanges
        let highlights = editor.coordinator.activeFindHighlights.map(\.range)
        // A saved Back position may deliberately sit above the raw clip top.
        let backAnchor = (source as NSString).range(of: "paragraph", options: [],
            range: NSRange(location: 400, length: source.utf16.count - 400)).location
        try #require(controller.restore(.init(anchorOffset: backAnchor, offsetInViewport: -13,
                                             magnification: magnification)))
        let departure = try #require(controller.readingPosition)
        let departureLine = try #require(editor.main.lineFrame(at: departure.anchorOffset))
        try #require(abs(departureLine.minY - editor.main.visibleRect.minY - departure.offsetInViewport) < 0.5)
        try #require(abs(editor.scroll.magnification - magnification) < 0.001)
        try #require(editor.scroll.contentInsets.top == 90)
        var departures: [ReadingPosition] = []
        controller.scrollToSection(target, whileValid: { true }, didNavigate: { departures.append($0) })
        #expect(editor.main.string == source)
        #expect(editor.main.selectedRanges == selection)
        #expect(editor.coordinator.activeFindHighlights.map(\.range) == highlights)
        #expect(!editor.state.undo.canUndo)
        #expect(departures == [departure])
        let line = try #require(editor.main.lineFrame(at: (source as NSString).range(of: "# B").location))
        let visible = editor.main.visibleRect
        try #require(visible.minY > 100, "The target must have room above it for an unconstrained landing")
        try #require(editor.scroll.documentView!.bounds.maxY - editor.scroll.contentView.bounds.maxY > 100,
                     "Trailing content must prevent bottom clamping from hiding the alignment error")
        let viewportTop = editor.main.convert(NSPoint(x: 0, y: visible.minY), to: nil).y
        let headingTop = editor.main.convert(NSPoint(x: 0, y: line.minY), to: nil).y
        #expect(abs(viewportTop - headingTop - 90) < 0.5,
                "The actual heading line must clear the configured 90-point chrome at native zoom")
        #expect(line.maxY < visible.maxY)
        let arrivedY = editor.scroll.contentView.bounds.minY
        controller.scrollToSection(target, whileValid: { true }, didNavigate: { departures.append($0) })
        #expect(departures.count == 1)
        #expect(abs(editor.scroll.contentView.bounds.minY - arrivedY) < 0.5,
                "Repeated activation must keep the settled viewport in place")
        try #require(controller.restore(departure))
        let restored = try #require(editor.main.lineFrame(at: departure.anchorOffset))
        #expect(abs(restored.minY - editor.main.visibleRect.minY - departure.offsetInViewport) < 0.5,
                "Generic Back restore must keep its captured document-point offset, without chrome padding")
        #expect(editor.main.selectedRanges == selection)
        #expect(editor.main.string == source)
    }

    @Test("Writing Tools defers activation and rechecks cancellation", arguments: [false, true])
    func protectedActivation(cancel: Bool) throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try mount("# A\nbody\n" + String(repeating: "paragraph\n", count: 100) + "# B\ntail")
        defer { editor.close() }
        let controller = editor.state.controller
        let target = try #require(controller.sectionNavigationSnapshot?.targets.last)
        let offset = controller.currentScrollOffset
        var valid = true
        var departures = 0
        editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        controller.scrollToSection(target, whileValid: { valid }, didNavigate: { _ in departures += 1 })
        #expect(controller.currentScrollOffset == offset)
        #expect(departures == 0)
        valid = !cancel
        editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        #expect(departures == (cancel ? 0 : 1))
    }

    @Test("Marked table input survives activation and commits reject the old target")
    func tableInputSurvives() async throws {
        let source = "# A\n| H |\n| --- |\n| cell |\n\n# B\n" + String(repeating: "tail\n", count: 100)
        let editor = try mount(source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "cell", row: 1, column: 0)
        let target = try #require(editor.state.controller.sectionNavigationSnapshot?.targets.last)
        cell.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let selection = cell.selectedRanges
        let offset = editor.state.controller.currentScrollOffset
        var departures = 0
        editor.state.controller.scrollToSection(target, whileValid: { true }, didNavigate: { _ in departures += 1 })
        #expect(editor.coordinator.tableEditingSession.isActive)
        #expect(cell.hasMarkedText())
        #expect(cell.selectedRanges == selection)
        #expect(editor.state.controller.currentScrollOffset == offset)
        #expect(departures == 0)
        cell.insertText("你", replacementRange: cell.markedRange())
        #expect(departures == 0)
        #expect(editor.coordinator.tableEditingSession.isActive)
    }

    @Test("Queued activation is cancelled by disable, hiding, replacement and a newer Find command",
          arguments: ["disable", "hide", "replace", "find"])
    func deferredOwnershipCancellation(reason: String) throws {
        guard #available(macOS 15.0, *) else { return }
        let source = "# A\nbody\n" + String(repeating: "paragraph\n", count: 100) + "# B\ntail"
        let editor = try mount(source)
        defer { editor.close() }
        let controller = editor.state.controller
        let target = try #require(controller.sectionNavigationSnapshot?.targets.last)
        var departures = 0
        editor.coordinator.textViewWritingToolsWillBegin(editor.main)
        controller.scrollToSection(target, whileValid: { true }, didNavigate: { _ in departures += 1 })
        switch reason {
        case "disable": controller.isSectionNavigationEnabled = false
        case "hide":
            editor.wrapper.isDisplayed = false
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        case "replace":
            editor.wrapper.documentId = UUID().uuidString
            editor.wrapper.updateNativeView(editor.scroll, coordinator: editor.coordinator)
        default:
            editor.coordinator.handleFindClearHighlights(Notification(
                name: .init("test.clear"), object: editor.coordinator.documentId))
        }
        editor.coordinator.textViewWritingToolsDidEnd(editor.main)
        #expect(departures == 0)
        #expect(editor.main.string == source)
    }

    @Test("An execution predicate cannot approve a target after it replaces the source")
    func predicateRevalidation() throws {
        let editor = try mount("# A\nbody\n# B\ntail")
        defer { editor.close() }
        let controller = editor.state.controller
        let target = try #require(controller.sectionNavigationSnapshot?.targets.last)
        var departures = 0
        controller.scrollToSection(target, whileValid: {
            editor.state.undo.beginUndoGrouping()
            editor.main.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
            editor.state.undo.endUndoGrouping()
            return true
        }, didNavigate: { _ in departures += 1 })
        #expect(departures == 0)
        #expect(controller.sectionPreview(for: target) == nil)
    }

    @Test("Navigation preserves the active table cell, text selection and keyboard owner")
    func activeTableSurvives() async throws {
        let source = "# A\n| H |\n| --- |\n| cell |\n\n# B\n" + String(repeating: "tail\n", count: 100)
        let editor = try mount(source)
        defer { editor.close() }
        await editor.settle()
        let cell = try editor.focusCell(inTableContaining: "cell", row: 1, column: 0)
        cell.setSelectedRange(NSRange(location: 1, length: 2))
        let selection = cell.selectedRanges
        let target = try #require(editor.state.controller.sectionNavigationSnapshot?.targets.last)
        var departures = 0
        editor.state.controller.scrollToSection(target, whileValid: { true }, didNavigate: { _ in departures += 1 })
        #expect(editor.coordinator.tableEditingSession.isActive)
        #expect(editor.window.firstResponder === cell)
        #expect(cell.selectedRanges == selection)
        #expect(editor.main.string == source)
        #expect(!editor.state.undo.canUndo)
        #expect(departures == 1)
    }

    @Test("Distant activation and previews preserve lazy layout")
    func distantLazyJump() async throws {
        let source = "# First\n" + (0..<1800).map { "Paragraph \($0) " + String(repeating: "readable text ", count: 7) }.joined(separator: "\n\n") + "\n# Last\nlast body"
        let editor = try mount(source)
        defer { editor.close() }
        await editor.settle()
        let controller = editor.state.controller
        let target = try #require(controller.sectionNavigationSnapshot?.targets.last)
        let layout = try #require(editor.main.textLayoutManager)
        func laidOutCount() -> Int {
            var count = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) {
                if $0.state == .layoutAvailable { count += 1 }
                return true
            }
            return count
        }
        let before = laidOutCount()
        #expect(controller.sectionPreview(for: target)?.body == "last body")
        #expect(laidOutCount() == before)
        var departures = 0
        controller.scrollToSection(target, whileValid: { true }, didNavigate: { _ in departures += 1 })
        #expect(departures == 1)
        let anchor = (source as NSString).range(of: "# Last").location
        #expect(try #require(editor.main.lineFrame(at: anchor)).intersects(editor.main.visibleRect))
        #expect(laidOutCount() < 360)
    }
}
