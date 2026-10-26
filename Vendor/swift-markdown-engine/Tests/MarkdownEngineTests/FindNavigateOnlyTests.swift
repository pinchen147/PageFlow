import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Find rendering and protected input", .serialized)
struct FindNavigateOnlyTests {
    @MainActor
    private final class State {
        var text: String
        let undo = UndoManager()
        init(_ text: String) { self.text = text }
    }

    @MainActor
    private struct Mounted {
        let state: State
        let wrapper: NativeTextViewWrapper
        let coordinator: NativeTextViewCoordinator
        let window: NSWindow
        let scroll: NSScrollView
        let view: NativeTextView

        func paint() throws {
            window.contentView?.layoutSubtreeIfNeeded()
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let bounds = scroll.bounds
            let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: bounds))
            scroll.cacheDisplay(in: bounds, to: bitmap)
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
            if let layout = view.textLayoutManager {
                layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                    fragment.draw(at: .zero, in: context)
                    return true
                }
            }

        }

        func close() {
            NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
            window.close()
        }

        func show(_ range: NSRange, all: [NSRange]? = nil, current: Int = 0) {
            coordinator.handleFindScrollToRange(Notification(
                name: Notification.Name("test.findScroll"), object: coordinator.documentId,
                userInfo: ["range": range, "currentIndex": current, "allRanges": all ?? [range]]
            ))
        }

        func clear() {
            coordinator.handleFindClearHighlights(Notification(
                name: Notification.Name("test.findClear"), object: coordinator.documentId
            ))
        }

        func renderingAttribute(_ key: NSAttributedString.Key, at offset: Int) throws -> Any? {
            let layout = try #require(view.textLayoutManager)
            let content = try #require(layout.textContentManager)
            var attribute: Any?
            layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, range in
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let end = content.offset(from: content.documentRange.location, to: range.endLocation)
                if start <= offset && offset < end { attribute = attributes[key]; return false }
                return start <= offset
            }
            return attribute
        }
        func renderingColor(at offset: Int) throws -> NSColor? {
            try renderingAttribute(.backgroundColor, at: offset) as? NSColor
        }
    }

    private func mount(_ source: String) throws -> Mounted {
        _ = NSApplication.shared
        let state = State(source)
        let wrapper = NativeTextViewWrapper(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontSize: 16, documentId: UUID().uuidString, undoManager: state.undo
        )
        let coordinator = wrapper.makeCoordinator()
        let scroll = wrapper.makeNativeView(coordinator: coordinator)
        let view = try #require(scroll.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = try #require(window.contentView).bounds
        window.contentView = scroll
        scroll.tile()
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.makeFirstResponder(view)
        let editor = Mounted(state: state, wrapper: wrapper, coordinator: coordinator,
                             window: window, scroll: scroll, view: view)
        try editor.paint()
        return editor
    }

    @Test("Find uses transient colors and preserves stored code styling through relayout and clear")
    func findPreservesCodeBackgrounds() throws {
        let source = "body needle\n\ninline `needle code`\n\n```swift\nlet needle = 1\n```\n\n## Section\n"
        let editor = try mount(source)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let body = (source as NSString).range(of: "needle")
        let inline = (source as NSString).range(of: "needle code")
        let code = (source as NSString).range(of: "let needle")
        let inlineBackground = try #require(storage.attribute(.backgroundColor, at: inline.location, effectiveRange: nil) as? NSColor)
        let codeBackground = try #require(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor)
        let layout = try #require(editor.view.textLayoutManager)
        layout.addRenderingAttribute(.spellingState, value: 1, for: layout.documentRange)
        editor.show(body, all: [body, inline, code])
        try editor.paint()
        #expect(storage.attribute(.backgroundColor, at: inline.location, effectiveRange: nil) as? NSColor == inlineBackground)
        #expect(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor == codeBackground)
        #expect(storage.attribute(.backgroundColor, at: body.location, effectiveRange: nil) == nil)
        #expect(try editor.renderingColor(at: body.location) == editor.coordinator.configuration.theme.findCurrentMatchHighlight)
        #expect(try editor.renderingColor(at: inline.location) != nil)
        #expect(try editor.renderingAttribute(.spellingState, at: body.location) as? Int == 1)
        layout.invalidateLayout(for: layout.documentRange)
        try editor.paint()
        #expect(try editor.renderingColor(at: body.location) != nil, "Find survives real fragment relayout")
        let target = NSRange(location: (source as NSString).range(of: "## Section").location, length: 0)
        editor.show(target, all: [])
        try editor.paint()
        #expect(editor.view.selectedRange().location == target.location)
        #expect(try editor.renderingColor(at: body.location) == nil)
        #expect(storage.attribute(.backgroundColor, at: inline.location, effectiveRange: nil) as? NSColor == inlineBackground)
        editor.show(body)
        editor.clear()
        try editor.paint()
        #expect(try editor.renderingColor(at: body.location) == nil)
        #expect(try editor.renderingAttribute(.spellingState, at: body.location) as? Int == 1)
        #expect(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor == codeBackground)
        #expect((editor.view.string as NSString).isEqual(to: source))
        #expect(!editor.state.undo.canUndo)
    }

    @Test("Find defers every presentation change until marked input finishes", arguments: [false, true])
    func findDefersDuringComposition(clearLast: Bool) throws {
        let editor = try mount("needle body\n\ncomposition: ")
        defer { editor.close() }
        let tv = editor.view
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = tv.markedRange()
        try #require(marked.location != NSNotFound && marked.length == 5)
        let storage = try #require(tv.textStorage)
        storage.addAttribute(.backgroundColor, value: NSColor.systemPurple, range: marked)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: marked)
        let selection = tv.selectedRange()
        let origin = editor.scroll.contentView.bounds.origin
        let source = tv.string
        let match = (source as NSString).range(of: "needle")
        editor.show(match)
        editor.clear()
        editor.show(match)
        if clearLast { editor.clear() }
        #expect(tv.hasMarkedText())
        #expect(tv.markedRange() == marked)
        #expect(tv.selectedRange() == selection)
        #expect(editor.scroll.contentView.bounds.origin == origin)
        #expect((tv.string as NSString).isEqual(to: source))
        #expect(storage.attribute(.backgroundColor, at: marked.location, effectiveRange: nil) as? NSColor == .systemPurple)
        #expect(storage.attribute(.underlineStyle, at: marked.location, effectiveRange: nil) as? Int == NSUnderlineStyle.thick.rawValue)
        tv.unmarkText()
        try editor.paint()
        if clearLast {
            #expect(tv.selectedRange() == selection)
            #expect(try editor.renderingColor(at: match.location) == nil)
        } else {
            #expect(tv.selectedRange() == match)
            #expect(try editor.renderingColor(at: match.location) != nil)
        }
    }

    @Test("Changed source and document cancellation discard pending Find", arguments: [false, true])
    func staleCompositionFindIsDiscarded(cancelDocument: Bool) throws {
        let editor = try mount("needle body\n\ncomposition: ")
        defer { editor.close() }
        let tv = editor.view
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        let match = (tv.string as NSString).range(of: "needle")
        editor.show(match)
        if cancelDocument {
            editor.coordinator.cancelDocumentWork()
            tv.unmarkText()
        } else {
            tv.insertText("你", replacementRange: tv.markedRange())
        }
        try editor.paint()
        #expect(tv.selectedRange() != match)
        #expect(try editor.renderingColor(at: match.location) == nil)
    }

    @Test("Writing Tools defers Find and rejects an outdated source snapshot", arguments: [false, true])
    func findDefersDuringWritingTools(changeSource: Bool) throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = try mount("needle body\n\ntail")
        defer { editor.close() }
        let tv = editor.view
        let match = (tv.string as NSString).range(of: "needle")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        let selection = tv.selectedRange()
        editor.coordinator.textViewWritingToolsWillBegin(tv)
        editor.show(match)
        #expect(tv.selectedRange() == selection)
        #expect(try editor.renderingColor(at: match.location) == nil)
        if changeSource {
            tv.insertText("changed ", replacementRange: NSRange(location: 0, length: 0))
        }
        editor.coordinator.textViewWritingToolsDidEnd(tv)
        try editor.paint()
        if changeSource {
            #expect(tv.selectedRange() != match)
            #expect(try editor.renderingColor(at: match.location) == nil)
        } else {
            #expect(tv.selectedRange() == match)
            #expect(try editor.renderingColor(at: match.location) != nil)
        }
    }

    @Test("Native input retires old Find offsets")
    func typingRetiresFind() throws {
        let editor = try mount("needle plain body")
        defer { editor.close() }
        editor.show(NSRange(location: 0, length: 6))
        try editor.paint()
        try #require(try editor.renderingColor(at: 0) != nil)
        editor.view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        try editor.paint()
        #expect(try editor.renderingColor(at: 1) == nil)
        #expect(editor.view.string == "xneedle plain body")
    }

    @Test("Find rejects invalid focused ranges and ignores invalid secondary ranges")
    func invalidRangesAreSafe() throws {
        let editor = try mount("needle plain body")
        defer { editor.close() }
        let selection = editor.view.selectedRange()
        let bad = [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                   NSRange(location: NSNotFound, length: 1), NSRange(location: Int.max - 1, length: 9),
                   NSRange(location: 0, length: Int.max)]
        for range in bad { editor.show(range) }
        #expect(editor.view.selectedRange() == selection)
        #expect(!editor.state.undo.canUndo)
        let valid = NSRange(location: 0, length: 6)
        editor.show(valid, all: bad + [valid], current: bad.count)
        try editor.paint()
        #expect(try editor.renderingColor(at: 0) == editor.coordinator.configuration.theme.findCurrentMatchHighlight)
        let eof = NSRange(location: editor.view.string.utf16.count, length: 0)
        editor.show(eof, all: [])
        #expect(editor.view.selectedRange() == eof)
    }

    @Test("Clear preserves reading position and later visible fragments retain Find")
    func findFollowsViewportWithoutScrollOnClear() throws {
        let source = (0..<250).map { "paragraph-\($0) needle stable content\n" }.joined()
        let editor = try mount(source)
        defer { editor.close() }
        let first = (source as NSString).range(of: "needle")
        let later = (source as NSString).range(of: "paragraph-180 needle")
        let laterMatch = NSRange(location: later.location + "paragraph-180 ".utf16.count, length: 6)
        editor.show(first, all: [first, laterMatch])
        editor.view.scrollRangeToVisible(later)
        try editor.paint()
        #expect(try editor.renderingColor(at: laterMatch.location) != nil)
        let before = try #require(editor.view.readingPosition())
        editor.clear()
        try editor.paint()
        let after = try #require(editor.view.readingPosition())
        #expect(after.anchorOffset == before.anchorOffset)
        #expect(abs(after.offsetInViewport - before.offsetInViewport) < 1)
        #expect(try editor.renderingColor(at: laterMatch.location) == nil)
    }

    @Test("Containing Find ranges survive native fragment relayout", arguments: [false, true])
    func containingRangesSurviveRelayout(currentOuter: Bool) throws {
        let source = "first needle\n\nmiddle plain content\n\nlast needle\n"
        let editor = try mount(source)
        defer { editor.close() }
        let first = (source as NSString).range(of: "needle")
        let last = (source as NSString).range(of: "needle", options: .backwards)
        let outer = NSRange(location: 0, length: source.utf16.count)
        let middle = (source as NSString).range(of: "middle").location
        editor.show(currentOuter ? outer : last, all: currentOuter ? [first, last, outer] : [outer, first, last], current: 2)
        try editor.paint()
        try #require(try editor.renderingColor(at: middle) != nil)
        let layout = try #require(editor.view.textLayoutManager)
        layout.invalidateRenderingAttributes(for: layout.documentRange)
        layout.invalidateLayout(for: layout.documentRange)
        layout.ensureLayout(for: layout.documentRange)
        try editor.paint()
        #expect(try editor.renderingColor(at: middle) != nil)
        #expect(try editor.renderingColor(at: last.location) == editor.coordinator.configuration.theme.findCurrentMatchHighlight)
        editor.window.setContentSize(NSSize(width: 230, height: 450))
        try editor.paint()
        #expect(try editor.renderingColor(at: middle) != nil)
        #expect(try editor.renderingColor(at: last.location) == editor.coordinator.configuration.theme.findCurrentMatchHighlight)
    }

    @Test("Document cancellation preserves marked input presentation until commit")
    func cancellationPreservesMarkedPresentation() throws {
        let editor = try mount("needle body\n\ncomposition: ")
        defer { editor.close() }
        editor.show(NSRange(location: 0, length: 6))
        let tv = editor.view
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = tv.markedRange()
        let layout = try #require(tv.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: marked.location))
        let end = try #require(content.location(start, offsetBy: marked.length))
        let range = try #require(NSTextRange(location: start, end: end))
        layout.addRenderingAttribute(.backgroundColor, value: NSColor.systemPurple, for: range)
        let selection = tv.selectedRange()
        try #require(try editor.renderingColor(at: marked.location) == .systemPurple)
        editor.coordinator.cancelDocumentWork()
        #expect(tv.hasMarkedText())
        #expect(tv.selectedRange() == selection)
        #expect(try editor.renderingColor(at: marked.location) == .systemPurple)
        tv.unmarkText()
        try editor.paint()
        #expect(try editor.renderingColor(at: marked.location) == nil)
    }
    @Test("Native fragment pixels retain Find after reflow and clear back to their original appearance")
    func findPixelsSurviveReflow() throws {
        let source = "first needle\n\nsecond needle ordinary content\n"
        let editor = try mount(source)
        defer { editor.close() }
        let first = (source as NSString).range(of: "needle")
        let second = (source as NSString).range(of: "needle", options: .backwards)
        let layout = try #require(editor.view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: second.location))
        func raster(_ name: String) throws -> Data {
            layout.ensureLayout(for: layout.documentRange)
            let fragment = try #require(layout.textLayoutFragment(for: location))
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 120,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 120))
            context.translateBy(x: 0, y: 120)
            context.scaleBy(x: 1, y: -1)
            fragment.draw(at: CGPoint(x: 12, y: 12), in: context)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/private/tmp/pageflow-find-pixels-\(name).png")
            )
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let original = try raster("original")
        editor.show(first, all: [first, second])
        let highlighted = try raster("highlighted")
        #expect(highlighted != original, "An unselected ordinary match must visibly render its Find background")
        layout.invalidateRenderingAttributes(for: layout.documentRange)
        layout.invalidateLayout(for: layout.documentRange)
        let reflowed = try raster("reflowed")
        #expect(reflowed == highlighted, "Relayout must restore the same visible highlight")
        editor.clear()
        let cleared = try raster("cleared")
        #expect(cleared == original, "Clearing Find must restore the original rendering")
    }
}
