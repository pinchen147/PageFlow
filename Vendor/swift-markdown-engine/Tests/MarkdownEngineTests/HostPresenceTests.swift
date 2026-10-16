//
//  HostPresenceTests.swift
//  MarkdownEngineTests
//
//  The host-parity knobs (doc 18 §4.7): a reading position reads and restores
//  as a location, a hidden editor pauses its viewport observers and releases
//  the keyboard, a position request lands once per token, a width change keeps
//  the reader's paragraph in place, and a document switch with byte-identical
//  text still resets the per-document state.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Host presence knobs: hidden, focused, reading position")
@MainActor
struct HostPresenceTests {

    private static let document = (1...400)
        .map { "Paragraph \($0) of a long note with `code` and *emphasis* so every line wraps differently at another width." }
        .joined(separator: "\n\n")

    final class Host {
        var text: String
        init(text: String) { self.text = text }
    }

    /// Value props only: reassigning `rootView` with a changed value is what
    /// drives `updateNSView` (a reference-only harness never updates).
    struct Harness: View {
        let host: Host
        var documentId = "presence"
        var isDisplayed = true
        var isFocused = false
        var request: ReadingPositionRequest?
        var focusRequests: (() -> Void)?
        var undoManager: UndoManager?
        var magnificationRange: ClosedRange<CGFloat>?

        var nativeWrapper: NativeTextViewWrapper {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: .default,
                fontSize: 16,
                documentId: documentId,
                isEditable: true,
                undoManager: undoManager,
                readingPositionRequest: request,
                isDisplayed: isDisplayed,
                isFocused: isFocused,
                onRequestFocus: focusRequests,
                magnificationRange: magnificationRange
            )
        }

        var body: some View { nativeWrapper }
    }

    private func settle(_ rounds: Int = 6) async {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews { if let found = findEditor(in: sub) { return found } }
        return nil
    }

    private struct Mounted {
        let window: NSWindow
        let hosting: NSHostingView<Harness>
        let textView: NativeTextView
        let scrollView: ClampedScrollView
        let coordinator: NativeTextViewCoordinator
    }

    private func mount(_ harness: Harness, width: CGFloat = 800) async -> Mounted? {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: harness)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting),
              let scrollView = tv.enclosingScrollView as? ClampedScrollView,
              let coordinator = tv.delegate as? NativeTextViewCoordinator else { return nil }
        return Mounted(window: window, hosting: hosting, textView: tv, scrollView: scrollView, coordinator: coordinator)
    }

    private func scroll(_ m: Mounted, to y: CGFloat) async {
        m.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        m.scrollView.reflectScrolledClipView(m.scrollView.contentView)
        await settle(3)
    }

    private func paragraphOffset(_ n: Int) -> Int {
        (Self.document as NSString).range(of: "Paragraph \(n) ").location
    }

    private func windowLineTop(at offset: Int, in textView: NativeTextView) throws -> CGFloat {
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        let y = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + textView.textContainerOrigin.y
        return textView.convert(NSPoint(x: textView.textContainerOrigin.x, y: y), to: nil).y
    }

    @Test("a reading position is a location and lands back where it was read")
    func readingPositionRoundTrip() async throws {
        let m = try #require(await mount(Harness(host: Host(text: Self.document))))
        defer { m.window.orderOut(nil) }
        await scroll(m, to: 3_000)
        let position = try #require(m.textView.readingPosition())
        #expect(position.anchorOffset > 0)
        #expect(position.offsetInViewport <= 8, "the anchor paragraph starts at or above the probe line")

        await scroll(m, to: 0)
        #expect(m.textView.restore(position))
        let landed = try #require(m.textView.readingPosition())
        #expect(landed.anchorOffset == position.anchorOffset)
        #expect(abs(landed.offsetInViewport - position.offsetInViewport) < 1)
        #expect(!m.textView.restore(ReadingPosition(anchorOffset: 1 << 30, offsetInViewport: 0)), "out of range lands nowhere")
    }

    @Test("a hidden editor pauses its observers and releases the keyboard; showing resumes both")
    func hiddenEditorPausesObservers() async throws {
        let host = Host(text: Self.document)
        let m = try #require(await mount(Harness(host: host, isFocused: true)))
        defer { m.window.orderOut(nil) }
        #expect(m.coordinator.viewObserverTokens.count == 2)
        #expect(m.window.firstResponder === m.textView, "the focused editor took the keyboard one turn later")

        m.hosting.rootView = Harness(host: host, isDisplayed: false, isFocused: true)
        await settle()
        #expect(m.scrollView.isHidden)
        #expect(m.coordinator.viewObserverTokens.isEmpty)
        #expect(m.window.firstResponder !== m.textView)

        m.hosting.rootView = Harness(host: host, isDisplayed: true, isFocused: true)
        await settle()
        #expect(!m.scrollView.isHidden)
        #expect(m.coordinator.viewObserverTokens.count == 2)
        #expect(m.window.firstResponder === m.textView)
    }

    enum DeferredLayout: String, CaseIterable {
        case noQueuedWork
        case exactHeight
        case zoomRefit
    }

    private final class MeasuredLayoutManager: NSTextLayoutManager {
        var fullLayoutRequests = 0
        var observedTableAnchor: Int?
        var tableLayoutRequests = 0

        override func ensureLayout(for range: NSTextRange) {
            let isFullDocument = range.location.compare(documentRange.location) == .orderedSame
                && range.endLocation.compare(documentRange.endLocation) == .orderedSame
            if isFullDocument {
                fullLayoutRequests += 1
            } else if let anchor = observedTableAnchor, let content = textContentManager {
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let end = content.offset(from: content.documentRange.location, to: range.endLocation)
                if start != NSNotFound, end != NSNotFound, start <= anchor, anchor < end {
                    tableLayoutRequests += 1
                }
            }
            super.ensureLayout(for: range)
        }
    }

    private struct RetainedMount {
        let window: NSWindow
        let container: NSView
        let textView: NativeTextView
        let scrollView: ClampedScrollView
        let coordinator: NativeTextViewCoordinator
        let layout: MeasuredLayoutManager
    }

    private func mountRetained(_ wrapper: NativeTextViewWrapper) async throws -> RetainedMount {
        _ = NSApplication.shared
        let coordinator = wrapper.makeCoordinator()
        let scrollView = try #require(wrapper.makeNativeView(coordinator: coordinator) as? ClampedScrollView)
        let textView = try #require(scrollView.nativeTextView)
        let previousLayout = try #require(textView.textLayoutManager)
        let textContainer = try #require(textView.textContainer)
        let storage = try #require(textView.textStorage)
        let content = try #require(previousLayout.textContentManager)
        let viewportDelegate = previousLayout.textViewportLayoutController.delegate
        let layout = MeasuredLayoutManager()
        layout.delegate = previousLayout.delegate
        layout.usesFontLeading = previousLayout.usesFontLeading
        layout.usesHyphenation = previousLayout.usesHyphenation
        layout.limitsLayoutForSuspiciousContents = previousLayout.limitsLayoutForSuspiciousContents
        layout.renderingAttributesValidator = previousLayout.renderingAttributesValidator
        content.addTextLayoutManager(layout)
        previousLayout.textContainer = nil
        layout.textContainer = textContainer
        layout.textSelections = previousLayout.textSelections
        content.primaryTextLayoutManager = layout
        content.removeTextLayoutManager(previousLayout)
        layout.textViewportLayoutController.delegate = viewportDelegate
        let bridge = LayoutBridge(layout)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge
        try #require(textView.textLayoutManager === layout)
        try #require(textView.textStorage === storage)
        try #require(textView.textContainer === textContainer)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        scrollView.tile()
        wrapper.updateNativeView(scrollView, coordinator: coordinator)
        window.orderBack(nil)
        container.layoutSubtreeIfNeeded()
        await settle()
        return RetainedMount(window: window, container: container, textView: textView,
                             scrollView: scrollView, coordinator: coordinator, layout: layout)
    }

    private func queue(_ work: DeferredLayout, in m: RetainedMount) {
        switch work {
        case .noQueuedWork:
            break
        case .exactHeight:
            m.textView.refreshOverscrollAfterTextEdit(for: m.scrollView)
        case .zoomRefit:
            m.textView.magnificationDidSettle()
        }
    }

    private func settlePastLayoutDebounces() async {
        try? await Task.sleep(nanoseconds: 1_150_000_000)
        await settle(3)
    }

    @Test("queued full layout waits while hidden, then catches up without losing source or Undo",
          arguments: DeferredLayout.allCases)
    func hiddenEditorPausesQueuedLayout(work: DeferredLayout) async throws {
        let host = Host(text: Self.document)
        let undo = UndoManager()
        var wrapper = Harness(
            host: host, documentId: "presence-deferred-\(work.rawValue)-\(UUID().uuidString)",
            undoManager: undo, magnificationRange: 0.5...4.0
        ).nativeWrapper
        let m = try await mountRetained(wrapper)
        defer {
            NativeTextViewWrapper.dismantleNSView(m.scrollView, coordinator: m.coordinator)
            undo.removeAllActions()
            m.window.orderOut(nil)
        }

        undo.beginUndoGrouping()
        m.textView.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
        m.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
        m.coordinator.commitTextSync(for: m.textView)
        let edited = "Edited " + Self.document
        try #require(host.text == edited)
        try #require(undo.canUndo)
        await settle()

        await settlePastLayoutDebounces()
        let beforeVisibleWork = m.layout.fullLayoutRequests
        queue(work, in: m)
        await settlePastLayoutDebounces()
        if work == .noQueuedWork {
            try #require(m.layout.fullLayoutRequests == beforeVisibleWork,
                         "the control must not manufacture a full-layout request")
        } else {
            try #require(m.layout.fullLayoutRequests > beforeVisibleWork,
                         "the forwarding observer must see the real visible deferred callback")
        }

        if work == .zoomRefit {
            m.scrollView.magnification = 0.5
        }
        queue(work, in: m)
        // The retained host uses this same presence transition when an edited
        // editor leaves its mount. Hide before either debounce can expire.
        wrapper.isDisplayed = false
        wrapper.updateNativeView(m.scrollView, coordinator: m.coordinator)
        m.scrollView.removeFromSuperview()
        let beforeHiddenWork = m.layout.fullLayoutRequests
        await settlePastLayoutDebounces()

        #expect(m.scrollView.isHidden)
        #expect(m.layout.fullLayoutRequests == beforeHiddenWork,
                "\(work.rawValue) requested whole-document layout while hidden")
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
        #expect(undo.canUndo)

        m.container.addSubview(m.scrollView)
        wrapper.isDisplayed = true
        wrapper.updateNativeView(m.scrollView, coordinator: m.coordinator)
        await settlePastLayoutDebounces()

        #expect(!m.scrollView.isHidden)
        let content = try #require(m.layout.textContentManager)
        let tailLocation = try #require(content.location(
            content.documentRange.location, offsetBy: (edited as NSString).length - 1
        ))
        let tail = try #require(m.layout.textLayoutFragment(for: tailLocation))
        #expect(tail.state == .layoutAvailable,
                "showing must finish the deferred offscreen layout")
        #expect(tail.layoutFragmentFrame.maxY <= m.textView.frame.height + 1,
                "the final paragraph must fit inside the refreshed scrollable frame")
        if work == .zoomRefit {
            let container = try #require(m.scrollView.documentView as? NativeTextViewContainer)
            #expect(abs(container.frame.width - m.scrollView.contentView.bounds.width) < 2,
                    "the resumed zoom refit must grow the document to the effective viewport")
        }
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
        undo.undo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect(m.textView.string == Self.document)
        #expect(host.text == Self.document)
        #expect(undo.canRedo)
        undo.redo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
    }

    @Test("a queued wide-table refresh waits while hidden and resumes with current presentation",
          arguments: [false, true])
    func hiddenEditorPausesQueuedTableLayout(changesFont: Bool) async throws {
        let source = """
        Introduction above the wide table.

        | First wide column | Second wide column | Third wide column | Fourth wide column |
        | --- | --- | --- | --- |
        | A deliberately long first cell that cannot fit beside the other columns | A deliberately long second cell that cannot fit beside the other columns | A deliberately long third cell that cannot fit beside the other columns | A deliberately long fourth cell that cannot fit beside the other columns |

        """ + "\n" + Self.document
        let host = Host(text: source)
        let undo = UndoManager()
        var wrapper = Harness(
            host: host, documentId: "presence-table-\(UUID().uuidString)", undoManager: undo
        ).nativeWrapper
        let m = try await mountRetained(wrapper)
        defer {
            NativeTextViewWrapper.dismantleNSView(m.scrollView, coordinator: m.coordinator)
            undo.removeAllActions()
            m.window.orderOut(nil)
        }

        undo.beginUndoGrouping()
        m.textView.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
        m.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
        m.coordinator.commitTextSync(for: m.textView)
        let edited = "Edited " + source
        try #require(host.text == edited)
        try #require(undo.canUndo)
        await settlePastLayoutDebounces()

        let storage = try #require(m.textView.textStorage)
        let anchor = (edited as NSString).range(of: "| First wide column |").location
        try #require(anchor != NSNotFound)
        try #require(storage.attribute(.scrollableBlockSourceID, at: anchor, effectiveRange: nil) is Int,
                     "the actual styler must classify the fixture as a wide table")
        // The retained harness replaces the layout manager before mounting.
        // Establish its real viewport, as the other overlay harnesses do.
        revealWideTable(m.textView, needle: "| First wide column |")
        m.layout.textViewportLayoutController.layoutViewport()
        m.textView.updateWideTableOverlays()
        await settle()
        let band = try #require(m.textView.viewportCharacterRange)
        try #require(NSLocationInRange(anchor, band), "the table must be inside the real viewport")
        try #require(m.textView.wideTableOverlays.count == 1,
                     "the actual mounted renderer must create the wide-table overlay")
        let originalOverlay = try #require(m.textView.wideTableOverlays.values.first)
        try #require(originalOverlay.anchorTextLocation == anchor)
        let initialImage = try #require(storage.attribute(
            .renderedBlockImage, at: anchor, effectiveRange: nil
        ) as? NSImage)
        try #require((originalOverlay.documentView as? NSImageView)?.image === initialImage)
        m.layout.observedTableAnchor = anchor

        let beforeVisibleWork = m.layout.tableLayoutRequests
        m.textView.updateWideTableOverlays()
        await settle()
        try #require(m.layout.tableLayoutRequests > beforeVisibleWork,
                     "the forwarding observer must see the visible queued table-anchor layout")

        // Exercise an unchanged viewport as well as a real presentation
        // change, which may invalidate the viewport before the editor hides.
        if changesFont {
            wrapper.fontSize = 20
            wrapper.updateNativeView(m.scrollView, coordinator: m.coordinator)
        }
        let currentImage = try #require(storage.attribute(
            .renderedBlockImage, at: anchor, effectiveRange: nil
        ) as? NSImage)
        if changesFont {
            try #require(currentImage !== initialImage, "the font update must regenerate the table image")
        } else {
            try #require(currentImage === initialImage)
        }
        let currentHeight = try #require(storage.attribute(
            .scrollableBlockTotalHeight, at: anchor, effectiveRange: nil
        ) as? CGFloat)
        let position = try #require(m.textView.readingPosition())
        m.textView.updateWideTableOverlays()
        try #require(m.textView.pendingWideTableOverlayUpdate,
                     "the visible table must have an actual queued overlay callback")
        if !changesFont {
            let beforeHideBand = try #require(m.textView.viewportCharacterRange)
            try #require(NSLocationInRange(anchor, beforeHideBand),
                         "the unchanged table must remain in the actual viewport before hiding")
        }
        wrapper.isDisplayed = false
        wrapper.updateNativeView(m.scrollView, coordinator: m.coordinator)
        try #require(m.textView.pendingWideTableOverlayUpdate,
                     "the actual overlay callback must still be queued after hiding")
        let beforeHiddenWork = m.layout.tableLayoutRequests
        await settlePastLayoutDebounces()

        #expect(m.scrollView.isHidden)
        #expect(!m.textView.pendingWideTableOverlayUpdate,
                "the queued callback must drain while the retained editor stays hidden")
        #expect(m.layout.tableLayoutRequests == beforeHiddenWork,
                "the queued table reconcile requested bounded anchor layout after the editor was hidden")
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
        #expect(undo.canUndo)

        let beforeResume = m.layout.tableLayoutRequests
        wrapper.isDisplayed = true
        wrapper.updateNativeView(m.scrollView, coordinator: m.coordinator)
        await settlePastLayoutDebounces()

        #expect(!m.scrollView.isHidden)
        #expect(m.layout.tableLayoutRequests > beforeResume,
                "showing must reconcile the table refresh that was deferred while hidden")
        try #require(m.textView.wideTableOverlays.count == 1)
        let overlay = try #require(m.textView.wideTableOverlays.values.first)
        #expect(!overlay.isHidden)
        #expect(overlay.anchorTextLocation == anchor)
        #expect((overlay.documentView as? NSImageView)?.image === currentImage,
                "the retained overlay must display the current font's table image")
        #expect(abs(overlay.frame.height - currentHeight) < 1)
        #expect(overlay.documentView?.frame.size == currentImage.size)
        let landed = try #require(m.textView.readingPosition())
        #expect(landed.anchorOffset == position.anchorOffset)
        #expect(abs(landed.offsetInViewport - position.offsetInViewport) < 1)
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
        undo.undo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect(m.textView.string == source)
        #expect(host.text == source)
        #expect(undo.canRedo)
        undo.redo()
        m.coordinator.commitTextSync(for: m.textView)
        #expect(m.textView.string == edited)
        #expect(host.text == edited)
    }

    @Test("a position request lands after the first styled layout, once per token")
    func requestLandsOncePerToken() async throws {
        let host = Host(text: Self.document)
        let target = ReadingPosition(anchorOffset: paragraphOffset(200), offsetInViewport: 0)
        let request = ReadingPositionRequest(target)
        let m = try #require(await mount(Harness(host: host, request: request)))
        defer { m.window.orderOut(nil) }
        let landed = try #require(m.textView.readingPosition())
        #expect(landed.anchorOffset == target.anchorOffset)
        #expect(abs(landed.offsetInViewport) < 1)

        await scroll(m, to: 0)
        m.hosting.rootView = Harness(host: host, isFocused: true, request: request)   // same token, another update
        await settle()
        #expect(m.textView.readingPosition()?.anchorOffset == 0, "an unchanged request never scrolls again")

        m.hosting.rootView = Harness(host: host, isFocused: true, request: ReadingPositionRequest(target))
        await settle()
        #expect(m.textView.readingPosition()?.anchorOffset == target.anchorOffset, "a new token lands again")
    }

    @Test("a width change keeps the reader's source line at the same place")
    func widthChangeKeepsTheParagraph() async throws {
        let m = try #require(await mount(Harness(host: Host(text: Self.document))))
        defer { m.window.orderOut(nil) }
        await scroll(m, to: 3_000)
        let before = try #require(m.textView.readingPosition())
        #expect(m.coordinator.lastReadingPosition == before)
        let lineBefore = try windowLineTop(at: before.anchorOffset, in: m.textView)

        m.window.setContentSize(NSSize(width: 500, height: 500))
        m.hosting.layoutSubtreeIfNeeded()
        await settle(8)
        let lineAfter = try windowLineTop(at: before.anchorOffset, in: m.textView)
        #expect(abs(lineAfter - lineBefore) < 1)
        #expect(m.scrollView.contentView.bounds.origin.y != 3_000, "the raw offset moved with the reflow; the paragraph did not")
    }

    @Test("a document switch with byte-identical text still resets the per-document state")
    func byteIdenticalNodeSwitchResets() async throws {
        let host = Host(text: Self.document)
        let m = try #require(await mount(Harness(host: host)))
        defer { m.window.orderOut(nil) }
        m.coordinator.deferredRestyleRanges = [NSRange(location: 0, length: 10)]
        m.coordinator.previousCaretLocation = 5
        m.coordinator.lastReadingPosition = ReadingPosition(anchorOffset: 9, offsetInViewport: 0)

        m.hosting.rootView = Harness(host: host, documentId: "other")
        await settle()
        #expect(m.coordinator.documentId == "other")
        #expect(m.coordinator.deferredRestyleRanges.isEmpty)
        #expect(m.coordinator.previousCaretLocation == nil)
        #expect(m.coordinator.didInitialFormatting, "the new document was styled")
    }

    @Test("the host's focus request reaches the coordinator the text view's mouse-down fires")
    func clickRequestsFocus() async throws {
        // `NSTextView.mouseDown` runs AppKit's tracking loop until a mouse-up, so
        // the test drives the callback the override fires rather than the click.
        let host = Host(text: Self.document)
        var requests = 0
        let m = try #require(await mount(Harness(host: host, focusRequests: { requests += 1 })))
        defer { m.window.orderOut(nil) }
        m.coordinator.onRequestFocus?()
        #expect(requests == 1)
        m.hosting.rootView = Harness(host: host, focusRequests: nil)
        await settle()
        #expect(m.coordinator.onRequestFocus == nil, "the wrapper keeps the callback current")
    }
}
