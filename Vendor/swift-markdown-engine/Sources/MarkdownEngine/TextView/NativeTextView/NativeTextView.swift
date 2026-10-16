//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//
//  AppKit `NSTextView` subclass used by the markdown editor. Stored state
//  lives here; behavior is split across `NativeTextView+<Feature>.swift`
//  files in this folder (frame & overscroll, caret workarounds, click remap,
//  paste handling, drag-select boost, task checkbox, spelling policy).
//
//  Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
//  Pasteboard image inspection lives in `PasteboardImageReader.swift`.
//

import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    /// Room the comment rail keeps at the right (doc 25 §4.1): the reading
    /// column moves left to end this far from the editor's right edge.
    var commentLaneReserve: CGFloat = 0 {
        didSet {
            guard abs(commentLaneReserve - oldValue) > 0.5, let scrollView = enclosingScrollView else { return }
            if configuration.readingWidth != nil {
                centerReadingColumn(forClipWidth: scrollView.contentView.bounds.width)
                return
            }
            // Full width: the wrap narrows (or widens back) on the right, once.
            preservingViewportAnchor {
                applyZoomWrapPinning()
                containerWidthDidChange()
            }
            pendingFullLayoutMeasure = true
            recalcOverscroll(for: scrollView, debugTag: "commentLane")
        }
    }

    /// How far short of the editor's right edge a breakout wide table stops
    /// while comments keep a lane (the reference editor's `--rail-keepout`).
    var commentTableKeepout: CGFloat = 0 {
        didSet { if abs(commentTableKeepout - oldValue) > 0.5 { updateWideTableOverlays() } }
    }

    /// Wide tables (by source id) the comments let run into their lane: no card is near.
    var tablesFreedIntoCommentLane: Set<Int> = [] {
        didSet { if tablesFreedIntoCommentLane != oldValue { updateWideTableOverlays() } }
    }

    /// How far the comment rail's last card hangs past the text: the
    /// document grows by it so that card can be scrolled to (doc 25 §4.3).
    var commentOverhang: CGFloat = 0 {
        didSet {
            guard abs(commentOverhang - oldValue) > 0.5 else { return }
            applyManagedFrameSize(width: frame.size.width)
        }
    }

    // Rich attributes render Markdown locally; Copy and Cut export literal source.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter {
            $0 == .string || $0.rawValue == "NSStringPboardType"
        }
    }

    // MARK: Frame & overscroll state
    var baseContentHeight: CGFloat = 0
    var activeBottomOverscroll: CGFloat = 0
    var isApplyingManagedFrameSize = false
    /// Set on switch/resize to force full-layout height measurement until the cascade settles.
    var pendingFullLayoutMeasure = false
    /// Net newline delta from the most recent text edit, captured before AppKit
    /// mutates storage. Used for cheap frame-growth estimates on the typing path.
    var pendingTextEditLineDelta = 0
    /// Generation token for the idle exact-height remeasure scheduled after typing.
    var deferredOverscrollRecalcGeneration = 0
    /// A queued exact-height pass stays pending while its editor is hidden.
    var pendingDeferredOverscrollRecalc = false
    /// Coalesces wide-table overlay updates to once per runloop (resize fires many per frame).
    var pendingWideTableOverlayUpdate = false
    /// A hidden editor retains its requested table refresh until it is shown.
    var pendingDeferredWideTableOverlayUpdate = false
    var suppressAutoRevealOnce: Bool = false
    /// Depth of `preservingViewportAnchor` bodies in progress: a pin nested
    /// inside another pin's body runs unmeasured (the outer pin covers it).
    var viewportPinDepth = 0

    /// Above this many UTF-16 characters the editor never forces whole-note
    /// layout (the pin's settle, the exact overscroll measure, the zoom settle,
    /// the rebuild, Find; ADR-0020 amendment): it froze the editor for about a
    /// second per megabyte and left every later keystroke O(document). On a long note
    /// TextKit 2 purges laid-out fragments outside the viewport at the next
    /// pass, so a chain laid out from the document start is discarded one
    /// frame later and every measurement taken in it lands the reader a
    /// screen away (a 490 KB note: the block's top read 18630 → 19977 → 20363
    /// pt across three consecutive passes). The estimated chain TextKit keeps
    /// is the one it draws from; measuring in it is consistent.
    static let estimatedLayoutChainThreshold = 120_000
    var prefersEstimatedLayoutChain: Bool { (textStorage?.length ?? 0) > Self.estimatedLayoutChainThreshold }

    // MARK: Visual-zoom re-fit state (ADR-0019)
    /// Debounces the zoom-settle re-fit: pinch ends, Ctrl-scroll ticks and ⌘±
    /// bursts coalesce into ONE width-fitted-block restyle ~200ms after the
    /// last change (`magnificationDidSettle`).
    var zoomRefitWorkItem: DispatchWorkItem?
    var pendingZoomRefit = false
    /// The block-fit width of the last width-dependent restyle; the settle
    /// re-fit no-ops when the effective width has not actually changed.
    var lastBlockFitRefitWidth: CGFloat?
    /// The requested pixel density of the last block restyle. Renderers own
    /// their cache quantization; core refits follow the public scale contract.
    var lastBlockRasterScale: CGFloat?

    // MARK: Configuration
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent

    /// The host paints the editor's background, around the reading column
    /// too: the text view and its scroll view draw none.
    func drawNoBackground() {
        drawsBackground = false
        backgroundColor = .clear
        enclosingScrollView?.drawsBackground = false
    }
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    // MARK: Editor wiring
    var onPasteImage: ((NSPasteboard) -> String?)?
    /// Files dropped on the editor that the host opens as documents instead.
    var onDropDocuments: (([URL]) -> Bool)?
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)


    override func magnify(with event: NSEvent) {
        // Visual (PDF-style) zoom: hand the pinch to the scroll view so it
        // magnifies the whole document. Explicit forward (not just `super`) so it
        // works regardless of NSTextView's own gesture handling.
        if let scrollView = enclosingScrollView, scrollView.allowsMagnification {
            scrollView.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    // MARK: Print support (PageFlow fork — S9 print seam)
    /// Strong reference to a throwaway print view's custom layout-fragment delegate.
    /// `NSTextLayoutManager.delegate` is `weak`, so a detached print view (built by
    /// `MarkdownPrintRenderer`) must retain the delegate itself or its fragments fall
    /// back to the stock `NSTextLayoutFragment` and math/tables print blank. Always
    /// `nil` on a live, mounted editor (its coordinator owns the delegate).
    var printLayoutDelegate: MarkdownLayoutManagerDelegate?
    /// The print view's own styler (it has no host coordinator).
    var printStyler: NativeTextViewCoordinator?
    /// A detached print view: tables never scroll, so wide ones scale to the page.
    var rendersForPrint = false

    // MARK: Caret-workaround state
    var caretIndicatorObservation: NSKeyValueObservation?
    /// Catches the editor's chords before the window dispatches them (`updateKeyMonitor`).
    private var keyMonitor: Any?
    weak var observedCaretIndicator: NSView?
    var isApplyingCaretShift: Bool = false

    // MARK: Drag-select state
    var dragStartMouseScreenLoc: NSPoint?

    // MARK: Placeholder state
    /// Click-through ghost-text label shown while the document is empty;
    /// managed by `NativeTextView+Placeholder.swift`.
    weak var placeholderView: PlaceholderLabelView?

    // MARK: Wide-table overlay state
    /// Live NSScrollView per wide table; keyed by source-ID hash.
    var wideTableOverlays: [Int: WideTableOverlay] = [:]
    /// The selection the wide tables were last painted for.
    var wideTableSelection = NSRange(location: 0, length: 0)
    /// Persisted horizontal scroll offset per wide table; survives restyles.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder's highlighter via its registered notification.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    var isSettingMarkedText = false
    var isCommittingMarkedText = false

    // AppKit owns provisional input and its attributes until the native commit.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { (delegate as? NativeTextViewCoordinator)?.makeParagraphAfterTableGap(in: self) }
        isSettingMarkedText = true
        defer {
            isSettingMarkedText = false
            if !hasMarkedText() { (delegate as? NativeTextViewCoordinator)?.finishComposition(in: self) }
        }
        (delegate as? NativeTextViewCoordinator)?.pendingCompositionRefresh = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if hasMarkedText(), let coordinator = delegate as? NativeTextViewCoordinator {
            coordinator.applyCompositionAttributes(to: markedRange(), in: self)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !hasMarkedText(), replacementRange.location == NSNotFound {
            (delegate as? NativeTextViewCoordinator)?.makeParagraphAfterTableGap(in: self)
        }
        let committing = hasMarkedText()
        if committing { isCommittingMarkedText = true }
        super.insertText(insertString, replacementRange: replacementRange)
        if committing {
            isCommittingMarkedText = false
            (delegate as? NativeTextViewCoordinator)?.finishComposition(in: self)
        }
    }

    override func unmarkText() {
        let pendingRefresh = (delegate as? NativeTextViewCoordinator)?.pendingCompositionRefresh ?? false
        let committing = (hasMarkedText() || pendingRefresh) && !isCommittingMarkedText
        if committing { isCommittingMarkedText = true }
        super.unmarkText()
        if committing {
            isCommittingMarkedText = false
            (delegate as? NativeTextViewCoordinator)?.finishComposition(in: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let coordinator = delegate as? NativeTextViewCoordinator
        let bar = coordinator?.selectionBar
        bar?.rightClickSuppressed = false
        // F6 (the reference editor): the keyboard moves into the selection bar.
        if coordinator?.keyBindings.command(for: event) == .focusSelectionBar, bar?.focusBar() == true { return }
        super.keyDown(with: event)
    }

    /// The editor's keyboard commands (doc 24 §6.10, §7.7.5) as the host binds
    /// them, caught by the focused editor before the app's menus. Block
    /// commands do nothing in a table cell.
    private func editorCommand(_ event: NSEvent, coordinator: NativeTextViewCoordinator) -> Bool {
        guard let command = coordinator.keyBindings.command(for: event) else { return false }
        let inCell = coordinator.tableEditingSession.isActive
        switch command {
        case .comment:
            guard let comments = coordinator.comments else { return false }
            comments.commandComment()
            return true
        case .toggleComments:
            // Outside the text only, unless it has ⌘ or ⌃ (MarkdownCommentsController's key monitor).
            return false
        case .focusSelectionBar:
            return coordinator.selectionBar?.focusBar() ?? false
        case .tableCellActions:
            return false   // the cell's own key (MarkdownTableCellTextView)
        case .toggleChecked where inCell:
            return false   // ⌘Return in a cell is the cell's own
        default:
            guard let format = command.format else { return false }
            if !(command.isBlock && inCell) { coordinator.apply(format) }
            return true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents visit every view in the window; only the focused
        // editor (or its table cell) acts on them.
        if let coordinator = delegate as? NativeTextViewCoordinator, hasKeyboardFocus(coordinator),
           editorCommand(event, coordinator: coordinator) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// This editor, or its table cell, holds the key window's keyboard.
    private func hasKeyboardFocus(_ coordinator: NativeTextViewCoordinator) -> Bool {
        guard let window, window.isKeyWindow || window.firstResponder === self else { return false }
        return window.firstResponder === self || window.firstResponder === coordinator.tableEditingSession.editor
    }

    /// A host window need not pass key equivalents down to this view (a
    /// SwiftUI window can hand them to the menu bar first), so the focused
    /// editor also catches its chords before any dispatch: they always win
    /// over the menus, as the reference editor's do.
    private func updateKeyMonitor() {
        if window == nil {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            return
        }
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, !self.hasMarkedText(),
                      let coordinator = self.delegate as? NativeTextViewCoordinator,
                      event.modifierFlags.intersection([.command, .control]).isEmpty == false || Self.isFunctionKey(event),
                      self.hasKeyboardFocus(coordinator), self.editorCommand(event, coordinator: coordinator) else { return event }
                return nil
            }
        }
    }

    private static func isFunctionKey(_ event: NSEvent) -> Bool {
        MarkdownKeyChord.namedKeys.contains { $0.key.hasPrefix("f") && $0.value.contains(event.keyCode) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyMonitor()
    }

    deinit {
        caretIndicatorObservation?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

extension NSTextView {
    /// Lays the whole note out, except on a note long enough to keep the
    /// estimated chain TextKit draws from (`estimatedLayoutChainThreshold`,
    /// ADR-0020): there a whole-note layout freezes the editor and is purged
    /// a frame later.
    func ensureWholeNoteLayoutUnlessLong() {
        guard let tlm = textLayoutManager,
              (self as? NativeTextView)?.prefersEstimatedLayoutChain != true else { return }
        tlm.ensureLayout(for: tlm.documentRange)
    }
}
