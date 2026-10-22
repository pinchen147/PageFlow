import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Whole-document formatting preserves a literal visible source line", .serialized)
struct BulkFormattingViewportFidelityTests {
    enum Sequence: String, CaseIterable, Sendable {
        case noFormatting, boldUndo, sixCommandsUndo, nearBottomSixCommandsUndo, partialSpanUndo, consecutiveWorkflows

        var keys: [String] {
            switch self {
            case .noFormatting: []
            case .boldUndo, .partialSpanUndo: ["b"]
            case .sixCommandsUndo, .nearBottomSixCommandsUndo, .consecutiveWorkflows: ["b", "b", "u", "u", "i", "i"]
            }
        }

        var paragraph: Int { self == .nearBottomSixCommandsUndo ? 319 : 160 }
    }

    enum Interruption: String, CaseIterable, Sendable {
        case scroll, selection, equalLengthEdit, documentSwitch
    }

    private static let source: String = {
        (0..<320).map { index in
            let heading = index.isMultiple(of: 16) ? "## Review section \(index)\r\n\r\n" : ""
            let math = index.isMultiple(of: 40) || index == 319 ? "$$x^2 + y^2 = z^2$$\r\n\r\n" : ""
            let table = index.isMultiple(of: 80)
                ? (["| Item | Detail | Value |", "| --- | --- | --- |"]
                   + (0..<8).map { "| row-\($0) | 日本 cafe\u{301} | \($0) anchor |" }).joined(separator: "\r\n") + "\r\n\r\n"
                : ""
            return heading + table
                + "Paragraph \(index) reconcile **yield** 日本 cafe\u{301} [duration](https://example.com/duration/\(index)) and `anchor`. "
                + String(repeating: "Capital reconcile estimate balance review schedule allocation cashflow. ", count: 6)
                + "interior-\(index) duration *forecast* recorded with e\u{301} and é as distinct literal source.\r\n\r\n"
                + math
        }.joined()
    }()

    private struct FormulaRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = CGSize(width: 220, height: 48)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 12)
        }
    }

    @MainActor private final class Document {
        var text = BulkFormattingViewportFidelityTests.source
        let undo = UndoManager()
    }

    private struct Mounted {
        let document: Document
        let window: NSWindow
        let scroll: ClampedScrollView
        let view: NativeTextView
        let coordinator: NativeTextViewCoordinator
    }

    private func configuration() -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 720
        configuration.services.latex = FormulaRenderer()
        return configuration
    }

    private struct LineProbe {
        let range: NSRange
        let source: [UInt16]
        let localOffset: Int
        let documentY: CGFloat
        let windowY: CGFloat
        let fullyVisible: Bool
    }

    private func spinMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spinMainRunLoop()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Uses actual NSTextLineFragment geometry, independently of viewport pin selection.
    private func line(at offset: Int, in view: NativeTextView) -> LineProbe? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let storage = view.textStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let textLine = fragment.textLineFragment(for: location, isUpstreamAffinity: false),
              let elementRange = fragment.textElement?.elementRange,
              textLine.characterRange.location != NSNotFound else { return nil }
        let elementStart = content.offset(from: content.documentRange.location, to: elementRange.location)
        let range = NSRange(location: elementStart + textLine.characterRange.location,
                            length: textLine.characterRange.length)
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let frame = textLine.typographicBounds.offsetBy(
            dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
            dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
        )
        var readable = false
        var raster = false
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            if let font = attributes[.font] as? NSFont, font.pointSize >= 1 { readable = true }
            if attributes[.renderedBlockImage] is NSImage { raster = true }
        }
        guard readable, !raster, frame.height >= 1 else { return nil }
        let visible = view.visibleRect
        let windowY = view.convert(NSPoint(x: frame.minX, y: frame.minY), to: nil).y
        guard windowY.isFinite else { return nil }
        return LineProbe(range: range, source: Array((storage.string as NSString).substring(with: range).utf16),
                         localOffset: textLine.characterRange.location, documentY: frame.minY, windowY: windowY,
                         fullyVisible: frame.minY >= visible.minY && frame.maxY <= visible.maxY)
    }

    private func press(_ key: String, in view: NativeTextView, window: NSWindow, undo: UndoManager) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ))
        undo.beginUndoGrouping()
        let handled = view.performKeyEquivalent(with: event)
        undo.endUndoGrouping()
        try #require(handled, "the native formatting command must execute")
    }

    private func mount() async throws -> Mounted {
        _ = NSApplication.shared
        try #require(Self.source.utf16.count > NativeTextView.estimatedLayoutChainThreshold,
                     "the regression must retain estimated upstream geometry")
        let document = Document()
        document.undo.groupsByEvent = false
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            configuration: configuration(), fontSize: 16,
            documentId: "bulk-format-pin-\(UUID().uuidString)", isEditable: true, undoManager: document.undo
        )
        let coordinator = wrapper.makeCoordinator()
        let scroll = try #require(wrapper.makeNativeView(coordinator: coordinator) as? ClampedScrollView)
        let view = try #require(scroll.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = try #require(window.contentView).bounds
        window.contentView = scroll
        scroll.tile()
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.orderBack(nil)
        window.makeFirstResponder(view)
        await settle()
        return Mounted(document: document, window: window, scroll: scroll, view: view, coordinator: coordinator)
    }

    private func close(_ mounted: Mounted) {
        NativeTextViewWrapper.dismantleNSView(mounted.scroll, coordinator: mounted.coordinator)
        mounted.document.undo.removeAllActions()
        mounted.window.close()
    }

    private func navigate(to range: NSRange, in mounted: Mounted) async throws -> LineProbe {
        let view = mounted.view
        let scroll = mounted.scroll
        view.scrollRangeToVisible(range)
        await settle()
        let targetLine = try #require(line(at: range.location, in: view))
        let alignment = targetLine.documentY - 8 - view.visibleRect.minY
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x,
                                             y: scroll.contentView.bounds.origin.y + alignment))
        scroll.reflectScrolledClipView(scroll.contentView)
        // A witness in the last screen cannot reach top + 8: stay where a reader can scroll.
        scroll.clampToInsets()
        await settle()
        let probe = try #require(line(at: range.location, in: view))
        try #require(probe.fullyVisible && probe.localOffset > 0,
                     "the fixed witness must be an actual readable continuation line")
        return probe
    }

    /// Choose the edit control's witness from existing visible layout before measurement.
    private func unchangedVisibleLine(excluding edited: NSRange, original: NSString, in view: NativeTextView) -> LineProbe? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let start = layout.textViewportLayoutController.viewportRange?.location else { return nil }
        var remainingFragments = 32
        var remainingLines = 128
        var result: LineProbe?
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard remainingFragments > 0 else { return false }
            remainingFragments -= 1
            let top = fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
            if top >= view.visibleRect.maxY { return false }
            guard fragment.state == .layoutAvailable, let elementRange = fragment.textElement?.elementRange else { return true }
            let elementStart = content.offset(from: content.documentRange.location, to: elementRange.location)
            for textLine in fragment.textLineFragments where textLine.characterRange.location != NSNotFound {
                guard remainingLines > 0 else { return false }
                remainingLines -= 1
                guard let candidate = line(at: elementStart + textLine.characterRange.location, in: view),
                      candidate.fullyVisible, NSIntersectionRange(candidate.range, edited).length == 0,
                      NSMaxRange(candidate.range) <= original.length,
                      candidate.source == Array(original.substring(with: candidate.range).utf16) else { continue }
                result = candidate
                return false
            }
            return true
        }
        return result
    }

    private func scrollDiagnostic(_ phase: String, probe: LineProbe, expected: String, mounted: Mounted) {
        let view = mounted.view
        var viewportRange = "missing"
        if let layout = view.textLayoutManager, let content = layout.textContentManager,
           let viewport = layout.textViewportLayoutController.viewportRange {
            viewportRange = "\(content.offset(from: content.documentRange.location, to: viewport.location))"
                + "..<\(content.offset(from: content.documentRange.location, to: viewport.endLocation))"
        }
        let geometry = line(at: probe.range.location, in: view).map {
            "range=\(NSStringFromRange($0.range)) literalMatch=\($0.range == probe.range && $0.source == probe.source) "
                + "visible=\($0.fullyVisible) documentY=\($0.documentY) windowY=\($0.windowY)"
        } ?? "missing"
        print("BULK-SCROLL \(phase) fixedRange=\(NSStringFromRange(probe.range)) "
              + "source=\(String(reflecting: String(decoding: probe.source, as: UTF16.self))) geometry={\(geometry)} "
              + "clip=\(NSStringFromRect(mounted.scroll.contentView.bounds)) viewport=\(viewportRange) "
              + "selection=\(NSStringFromRange(view.selectedRange())) exactSource=\(view.string.utf16.elementsEqual(expected.utf16))")
    }

    @Test("a mid-document source line survives formatting, exact Undo and idle", arguments: Sequence.allCases)
    func wholeDocumentRoundtrip(sequence: Sequence) async throws {
        let mounted = try await mount()
        let (document, window, scroll, view, coordinator) =
            (mounted.document, mounted.window, mounted.scroll, mounted.view, mounted.coordinator)
        defer {
            close(mounted)
        }

        let target = (Self.source as NSString).range(of: "interior-\(sequence.paragraph) ")
        try #require(target.location != NSNotFound)
        let formula = (Self.source as NSString).range(of: "$$x^2 + y^2 = z^2$$", options: [],
            range: NSRange(location: target.location, length: (Self.source as NSString).length - target.location))
        try #require(formula.location != NSNotFound)
        view.setSelectedRange(NSRange(location: formula.location - 2, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        let before = try await navigate(to: target, in: mounted)
        print("BULK-FORMAT setup \(sequence.rawValue) target=\(target.location) witness=\(NSStringFromRange(before.range)) "
              + "localOffset=\(before.localOffset) documentY=\(before.documentY) fullyVisible=\(before.fullyVisible) "
              + "viewport=\(NSStringFromRect(view.visibleRect))")
        try #require(before.fullyVisible && before.localOffset > 0,
                     "the fixed witness must be an actual readable continuation line mid-paragraph")
        if sequence == .nearBottomSixCommandsUndo {
            try #require(before.range.location > Self.source.utf16.count * 9 / 10)
        } else {
            try #require(before.range.location > Self.source.utf16.count / 3
                         && before.range.location < Self.source.utf16.count * 2 / 3)
        }
        var formulaIsRendered = false
        view.textStorage?.enumerateAttribute(.renderedBlockImage, in: formula) { value, _, _ in
            if value is NSImage { formulaIsRendered = true }
        }
        try #require(formulaIsRendered, "the visible neighborhood must include a rendered formula before bulk formatting")
        let originBefore = scroll.contentView.bounds.origin.y

        for key in sequence.keys {
            if sequence == .partialSpanUndo {
                let ns = view.string as NSString
                let selection = ns.paragraphRange(for: NSRange(location: target.location - 10_000, length: 20_000))
                try #require(selection.length > NativeTextViewCoordinator.deferredRestyleThreshold
                             && selection.length < NativeTextView.estimatedLayoutChainThreshold)
                view.setSelectedRange(selection)
            } else {
                view.selectAll(nil)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            try press(key, in: view, window: window, undo: document.undo)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let formatted = view.string
        if !sequence.keys.isEmpty {
            try #require(!formatted.utf16.elementsEqual(Self.source.utf16), "the native commands must change the source")
        }
        for _ in sequence.keys {
            try #require(document.undo.canUndo, "every formatting command must register its own Undo")
            document.undo.undo()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try #require(view.string.utf16.elementsEqual(Self.source.utf16), "Undo must restore exact literal UTF16 source")
        coordinator.commitTextSync(for: view)
        #expect(document.text.utf16.elementsEqual(Self.source.utf16), "the host must receive the restored source")
        let after = try #require(line(at: before.range.location, in: view),
                                 "the original fixed source line must remain laid out after exact Undo")
        #expect(after.range == before.range && after.source == before.source)
        #expect(after.fullyVisible, "the original source line must still be readable in the viewport")
        #expect(abs(after.windowY - before.windowY) < 1,
                "\(sequence.rawValue) moved the fixed source line \(after.windowY - before.windowY)pt")
        print("BULK-FORMAT \(sequence.rawValue) offset=\(before.range.location) windowDelta=\(after.windowY - before.windowY) "
              + "signedOriginDelta=\(scroll.contentView.bounds.origin.y - originBefore)")

        try? await Task.sleep(nanoseconds: 250_000_000)
        let idle = try #require(line(at: before.range.location, in: view))
        #expect(idle.fullyVisible && idle.range == before.range && idle.source == before.source)
        #expect(abs(idle.windowY - after.windowY) < 1, "the same restored line must remain stable through idle")
        #expect(view.string.utf16.elementsEqual(Self.source.utf16))
        if sequence == .consecutiveWorkflows {
            let inverseSelection = view.selectedRange()
            view.selectAll(nil)
            try #require(view.selectedRange() == NSRange(location: 0, length: Self.source.utf16.count))
            try #require(view.selectedRange() != inverseSelection,
                         "Select All must replace the inverse edit's partial source selection")
            try? await Task.sleep(nanoseconds: 50_000_000)
            try press("b", in: view, window: window, undo: document.undo)
            let secondFormatted = view.string
            try #require(!secondFormatted.utf16.elementsEqual(Self.source.utf16))
            try? await Task.sleep(nanoseconds: 250_000_000)
            try #require(document.undo.canUndo)
            document.undo.undo()
            try? await Task.sleep(nanoseconds: 100_000_000)
            try #require(view.string.utf16.elementsEqual(Self.source.utf16),
                         "the second workflow must restore the same exact original UTF16 source")
            coordinator.commitTextSync(for: view)
            #expect(document.text.utf16.elementsEqual(Self.source.utf16))
            let second = try #require(line(at: before.range.location, in: view),
                                      "the original first-workflow witness must remain laid out after the second Undo")
            #expect(second.fullyVisible && second.range == before.range && second.source == before.source)
            #expect(abs(second.windowY - before.windowY) < 1,
                    "the second workflow moved the original literal source line \(second.windowY - before.windowY)pt")
            print("BULK-CONSECUTIVE inverseSelection=\(NSStringFromRange(inverseSelection)) "
                  + "offset=\(before.range.location) windowDelta=\(second.windowY - before.windowY)")
            try? await Task.sleep(nanoseconds: 250_000_000)
            let secondIdle = try #require(line(at: before.range.location, in: view))
            #expect(secondIdle.fullyVisible && secondIdle.range == before.range && secondIdle.source == before.source)
            #expect(abs(secondIdle.windowY - second.windowY) < 1)
            #expect(view.string.utf16.elementsEqual(Self.source.utf16))
            try #require(document.undo.canRedo)
            document.undo.redo()
            #expect(view.string.utf16.elementsEqual(secondFormatted.utf16))
            document.undo.undo()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(view.string.utf16.elementsEqual(Self.source.utf16))
            let final = try #require(line(at: before.range.location, in: view))
            #expect(final.fullyVisible && final.range == before.range && final.source == before.source)
            #expect(abs(final.windowY - before.windowY) < 1)
            return
        }
        if !sequence.keys.isEmpty {
            for _ in sequence.keys {
                try #require(document.undo.canRedo)
                document.undo.redo()
            }
            #expect(view.string.utf16.elementsEqual(formatted.utf16), "Redo must reapply the exact formatted source")
        }
    }

    @Test("pending bulk styling respects subsequent native input and document switches", arguments: Interruption.allCases)
    func pendingFormattingRespectsNewInput(interruption: Interruption) async throws {
        let mounted = try await mount()
        defer { close(mounted) }
        let (document, window, scroll, view, coordinator) =
            (mounted.document, mounted.window, mounted.scroll, mounted.view, mounted.coordinator)
        let target = (Self.source as NSString).range(of: "interior-160 ")
        try #require(target.location != NSNotFound)
        _ = try await navigate(to: target, in: mounted)
        try #require(coordinator.deferredRestyleRanges.isEmpty, "initial styling must finish before the measured bulk edit")
        view.selectAll(nil)
        try press("b", in: view, window: window, undo: document.undo)
        let formatted = view.string
        try #require(!formatted.utf16.elementsEqual(Self.source.utf16))
        try #require(!coordinator.deferredRestyleRanges.isEmpty, "the input must interrupt actual pending bulk styling")
        let oldClip = scroll.contentView.bounds
        let oldSelection = view.selectedRange()
        let ns = formatted as NSString
        var expected = formatted
        var currentDocument = document
        let witnessOffset: Int

        switch interruption {
        case .scroll:
            // Stay above the original focus, in the already styled prefix.
            // Moving into unstyled text would legitimately change line wraps.
            let upper = ns.range(of: "interior-150 ")
            try #require(upper.location != NSNotFound)
            view.scrollRangeToVisible(upper)
            let upperLine = try #require(line(at: upper.location, in: view))
            let alignment = upperLine.documentY - 8 - view.visibleRect.minY
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x,
                                                 y: scroll.contentView.bounds.origin.y + alignment))
            scroll.reflectScrolledClipView(scroll.contentView)
            try #require(abs(scroll.contentView.bounds.origin.y - oldClip.origin.y) > 100,
                         "the native scroll input must establish a different reader viewport")
            witnessOffset = upper.location
        case .selection:
            let word = ns.range(of: "interior-160")
            try #require(word.location != NSNotFound)
            view.setSelectedRange(NSRange(location: word.location + 3, length: 0))
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
            try #require(view.selectedRange() != oldSelection)
            witnessOffset = word.location
        case .equalLengthEdit:
            let word = ns.range(of: "interior-160")
            try #require(word.location != NSNotFound)
            expected = ns.replacingCharacters(in: word, with: "interior-169")
            document.undo.beginUndoGrouping()
            view.insertText("interior-169", replacementRange: word)
            view.breakUndoCoalescing()
            document.undo.endUndoGrouping()
            try #require(view.string.utf16.count == formatted.utf16.count,
                         "this native edit must change source without changing its UTF16 length")
            try #require(view.string.utf16.elementsEqual(expected.utf16))
            let unchanged = try #require(unchangedVisibleLine(excluding: word, original: ns, in: view),
                                         "the native edit must leave an unchanged fully visible literal source line")
            witnessOffset = unchanged.range.location
        case .documentSwitch:
            let replacement = Document()
            replacement.text = "# Replacement document\r\n\r\n"
                + (0..<20).map { "Replacement paragraph \($0) retains 日本 cafe\u{301}." }.joined(separator: "\r\n\r\n")
            expected = replacement.text
            currentDocument = replacement
            let wrapper = NativeTextViewWrapper(
                text: Binding(get: { replacement.text }, set: { replacement.text = $0 }),
                configuration: configuration(), fontSize: 16,
                documentId: "bulk-format-replacement-\(UUID().uuidString)", isEditable: true,
                undoManager: replacement.undo
            )
            wrapper.updateNativeView(scroll, coordinator: coordinator)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try #require(view.string.utf16.elementsEqual(expected.utf16), "the real wrapper must install the replacement source")
            witnessOffset = 0
        }

        let before = try #require(line(at: witnessOffset, in: view))
        try #require(before.fullyVisible, "the new input's fixed literal line must be readable before queued work runs")
        if interruption == .scroll { scrollDiagnostic("beforeDrain", probe: before, expected: expected, mounted: mounted) }
        if interruption != .documentSwitch {
            try #require(!coordinator.deferredRestyleRanges.isEmpty, "queued bulk work must still be pending after the native input")
        }
        var chunks = 0
        while !coordinator.deferredRestyleRanges.isEmpty && chunks < 32 {
            coordinator.flushDeferredRestyle()
            chunks += 1
        }
        try #require(coordinator.deferredRestyleRanges.isEmpty, "the actual deferred styling must finish within the fixture bound")
        if interruption == .scroll { scrollDiagnostic("afterDrain", probe: before, expected: expected, mounted: mounted) }
        await settle(4)
        if interruption == .scroll { scrollDiagnostic("afterPresentation", probe: before, expected: expected, mounted: mounted) }
        let after = try #require(line(at: before.range.location, in: view))
        #expect(after.fullyVisible && after.range == before.range && after.source == before.source)
        #expect(abs(after.windowY - before.windowY) < 1,
                "\(interruption.rawValue) was pulled back \(after.windowY - before.windowY)pt by older bulk work")
        #expect(view.string.utf16.elementsEqual(expected.utf16))
        coordinator.commitTextSync(for: view)
        #expect(currentDocument.text.utf16.elementsEqual(expected.utf16))
        print("BULK-CANCEL \(interruption.rawValue) chunks=\(chunks) offset=\(before.range.location) "
              + "windowDelta=\(after.windowY - before.windowY)")

        try? await Task.sleep(nanoseconds: 250_000_000)
        let idle = try #require(line(at: before.range.location, in: view))
        #expect(idle.fullyVisible && idle.range == before.range && idle.source == before.source)
        #expect(abs(idle.windowY - after.windowY) < 1)
        #expect(view.string.utf16.elementsEqual(expected.utf16))
        if interruption == .documentSwitch {
            #expect(!currentDocument.undo.canUndo, "the replacement document must not inherit the outgoing bulk Undo")
        } else {
            try #require(document.undo.canUndo)
            document.undo.undo()
            let restored = interruption == .equalLengthEdit ? formatted : Self.source
            #expect(view.string.utf16.elementsEqual(restored.utf16), "the native input must preserve the relevant Undo step")
        }
    }
}
