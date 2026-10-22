//
//  NativeTextViewWrapper.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
//
// Public selection / replacement value types live in
// `NativeTextViewSelectionTypes.swift`.
import SwiftUI
import AppKit

/// SwiftUI bridge for MarkdownEngine's AppKit-backed editor.
///
/// Wraps a TextKit 2 `NSTextView` inside an `NSScrollView` and exposes a
/// SwiftUI-friendly API of bindings (text, link state, replacement requests)
/// and callback closures (link clicks, caret movement, inline-selection and
/// code-block change notifications). All visual styling and external
/// dependencies are routed through ``MarkdownEditorConfiguration``.
public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    /// Two-way binding to exact Markdown source. Live preview changes attributes,
    /// so native selection and host source ranges share UTF-16 coordinates.
    @Binding public var text: String
    /// Becomes `true` while the caret is inside a `[[Name]]` link's content
    /// range, so embedders can show a contextual UI (e.g. a popover).
    @Binding public var isWikiLinkActive: Bool
    /// Push a replacement into the editor by setting this to a non-nil value;
    /// the engine applies it on the next update and then clears the binding.
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    /// Font name OR family name of the base body font — `NSFont(name:)` accepts
    /// both (hosts feed it `NSFontManager.availableFontFamilies` entries). An
    /// unresolvable name falls back to the system font.
    public var fontName: String
    /// Base font size in points. Headings, code blocks, and LaTeX are scaled
    /// off this value via ``MarkdownEditorConfiguration``.
    public var fontSize: CGFloat
    /// Opaque document identifier. Changing this resets per-document editor state
    /// and shared window undo; host-supplied document histories remain separate.
    /// Set a stable, unique value
    /// per document when displaying multiple editors so pending
    /// replacements and undo stay scoped to each editor.
    public var documentId: String
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Optional paste hook. Return a Markdown image-embed string (e.g.
    /// `"![[my-image]]"`) to insert at the caret, or `nil` to fall through
    /// to the system's default plain-text paste.
    public var onPasteImage: ((NSPasteboard) -> String?)?
    /// Optional drop hook: the files dropped on the note that
    /// ``opensDroppedFile`` accepted. Return `true` when the host opens them.
    public var onDropDocuments: (([URL]) -> Bool)?
    /// Whether the host opens a dropped file as a document (a PDF, another
    /// note). Those files go to ``onDropDocuments``; with this unset, or for a
    /// file it rejects, the file is refused unless it is an image.
    public var opensDroppedFile: ((URL) -> Bool)?
    /// Stores images dropped on the note (files, data or file promises) and
    /// answers, on the main thread, with one Markdown image link per image
    /// added, in drop order (empty when none was). The editor inserts them at
    /// the block boundary the drop line marked, mapped through any edit made
    /// meanwhile, as one Undo step. Unset, images are not accepted.
    public var onImportImages: ((MarkdownImageDrop, @escaping ([String]) -> Void) -> Void)?
    /// Reports a file drag over the note: `.images` while the editor shows
    /// its drop line, `.documents` for documents only, `nil` when it leaves,
    /// drops or ends. Hosts use it to hide their own drop overlay for images.
    public var onFileDragHover: ((MarkdownFileDragKind?) -> Void)?

    /// Fires when the user clicks a `[[Name]]` link. The argument is the
    /// resolved opaque identifier (or the display name when no resolver
    /// was supplied).
    public var onLinkClick: ((String) -> Void)?
    /// Fires when the user clicks a local link: a relative path, a `file:`
    /// URL or a `#heading`. Web and mail links open in their apps; without
    /// this hook a local link does nothing.
    public var onOpenLocalLink: ((URL) -> Void)?
    /// Fires whenever the caret rect inside an active wiki-link changes,
    /// so embedders can position a follow-the-caret UI.
    public var onCaretRectChange: ((CGRect) -> Void)?
    /// Fires when the caret enters or leaves a `[[Name]]` or `![[…]]`
    /// token. `nil` means the caret is no longer inside such a token.
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    /// Fires when the set of visible code blocks changes, so embedders can
    /// overlay copy buttons (see ``CodeBlockButton``).
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    /// Fires after the user toggles any of the three spell/grammar/auto-correction
    /// menu items. Embedders persist the policy and pass it back via
    /// ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    public var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    /// Ghost text shown at the first-line position while the document is empty;
    /// the first typed character hides it. Lives inside the scrolled content, so
    /// it sits below the header band and tracks its expand/collapse animation.
    public var placeholder: NSAttributedString?

    /// SwiftUI header hosted above the body and scrolling with it. The engine owns
    /// an `NSHostingView`, reserves its (intrinsic) height at the top of the text
    /// content, and refreshes the hosted content on every SwiftUI update. The header
    /// is a sibling of the text view in the scrolled container, so it is fully
    /// interactive. Inject any required SwiftUI environment into this content
    /// before passing it in.
    public var header: AnyView?
    /// Visible header height when collapsed — typically just the top row. Content
    /// below this is clipped. The embedder measures and supplies it so the top row
    /// stays fully visible while the lower content reveals/hides.
    public var headerCollapsedHeight: CGFloat
    /// Whether the header is expanded to its full content height or collapsed to
    /// ``headerCollapsedHeight``. Toggling animates the reveal.
    public var headerExpanded: Bool

    /// documentIds whose scroll offset to keep; others are forgotten. `nil` keeps all.
    public var retainedScrollDocumentIds: Set<String>?

    /// PageFlow fork patch P1 (doc 10 §3 / ADR-0010): optional host-retained handle for
    /// a SYNCHRONOUS read/flush of the live editor text at save time (see
    /// ``MarkdownEditorController``). The wrapper wires the coordinator to it on make.
    public var editorController: MarkdownEditorController?

    /// PageFlow fork knob: forces the editor's `NSScrollView.appearance` (and thus the
    /// text view's `effectiveAppearance`) independent of the system, so the host can
    /// offer a Light/Dark/System Markdown color scheme. `nil` follows the system.
    /// Dynamic system text colors re-resolve automatically on the resulting
    /// effective-appearance change; the wrapper additionally nudges a restyle in
    /// `updateNSView` when this value changes so rasterized content (math/tables)
    /// re-bakes. See PAGEFLOW-FORK.md.
    public var forcedAppearanceName: NSAppearance.Name?

    /// PageFlow fork knob: one-shot host hook invoked at the end of `makeNSView`
    /// with the editor's scroll view, so the host can apply chrome the engine
    /// doesn't own (e.g. PageFlow installs its Liquid Glass scroller). Make-time
    /// only — scroller identity isn't a live-reconciled property.
    public var scrollViewConfigurator: ((NSScrollView) -> Void)?

    /// PageFlow fork knob: per-document UndoManager the editor's text edits
    /// register into (via the coordinator's `undoManager(for:)`), so ⌘Z routes
    /// through the HOST's per-tab stack and undo history survives warm tab
    /// switches (each document keeps its own manager — the engine then skips
    /// its node-switch `removeAllActions`). `nil` keeps window-level undo.
    public var undoManager: UndoManager?

    /// PageFlow fork knob: vertical scroll offset applied ONCE at mount, after
    /// the initial full-document layout (cross-launch reading-position restore;
    /// clamped to the content). `nil` starts at the top as before. Warm-switch
    /// retention within a session stays the coordinator's own offset memory.
    /// Superseded by ``readingPositionRequest`` for hosts that persist positions.
    public var initialScrollOffset: CGFloat?

    /// A reading position to land on, applied after the first STYLED layout
    /// pass (a raw offset applied before styling landed short) and again
    /// whenever the host hands over a request with a new token — a split, a
    /// tear-off, an eviction remount, a reload. Each token is applied once.
    public var readingPositionRequest: ReadingPositionRequest?

    /// Whether this editor is on screen. A warm but undisplayed editor is
    /// hidden at the AppKit level (no layout, no draw, no hit-testing), its
    /// viewport observers are paused, and it never holds the keyboard — the
    /// Markdown peer of the PDF host view's `isHidden` gate.
    public var isDisplayed: Bool

    /// Whether this editor should own the keyboard while displayed: the host
    /// sets it for the active tab, and the editor takes first responder one
    /// turn later (responder changes inside a SwiftUI update re-enter AppKit).
    public var isFocused: Bool

    /// Fired on a mouse-down inside the editor so the host can make this tab
    /// active (a click in the inactive split pane, exactly as for PDF tabs).
    public var onRequestFocus: (() -> Void)?

    /// PageFlow fork knob: when non-nil, the scroll view enables visual
    /// magnification (PDF-style pinch / ⌘± / Ctrl-scroll zoom of the whole
    /// document, no reflow) bounded to this range. `nil` keeps AppKit's own
    /// magnify handling.
    public var magnificationRange: ClosedRange<CGFloat>?
    /// The host-owned magnification, PROJECTED onto the scroll view whenever it
    /// differs (⌘±, ⌘0, cross-launch restore). User gestures read back through
    /// ``onMagnificationChanged``. Ignored unless ``magnificationRange`` is set.
    public var magnification: CGFloat?
    /// Reports a USER-driven magnification change (pinch end / Ctrl-scroll) so the
    /// host can persist the per-document zoom. Not fired for projected changes.
    public var onMagnificationChanged: ((CGFloat) -> Void)?

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool> = .constant(false),
        pendingInlineReplacement: Binding<InlineReplacementRequest?> = .constant(nil),
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        isEditable: Bool = true,
        onPasteImage: ((NSPasteboard) -> String?)? = nil,
        onDropDocuments: (([URL]) -> Bool)? = nil,
        opensDroppedFile: ((URL) -> Bool)? = nil,
        onImportImages: ((MarkdownImageDrop, @escaping ([String]) -> Void) -> Void)? = nil,
        onFileDragHover: ((MarkdownFileDragKind?) -> Void)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        onOpenLocalLink: ((URL) -> Void)? = nil,
        onCaretRectChange: ((CGRect) -> Void)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil,
        onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)? = nil,
        placeholder: NSAttributedString? = nil,
        header: AnyView? = nil,
        headerCollapsedHeight: CGFloat = 0,
        headerExpanded: Bool = true,
        retainedScrollDocumentIds: Set<String>? = nil,
        editorController: MarkdownEditorController? = nil,
        forcedAppearanceName: NSAppearance.Name? = nil,
        scrollViewConfigurator: ((NSScrollView) -> Void)? = nil,
        undoManager: UndoManager? = nil,
        initialScrollOffset: CGFloat? = nil,
        readingPositionRequest: ReadingPositionRequest? = nil,
        isDisplayed: Bool = true,
        isFocused: Bool = false,
        onRequestFocus: (() -> Void)? = nil,
        magnificationRange: ClosedRange<CGFloat>? = nil,
        magnification: CGFloat? = nil,
        onMagnificationChanged: ((CGFloat) -> Void)? = nil
    ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self._pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onPasteImage = onPasteImage
        self.onDropDocuments = onDropDocuments
        self.opensDroppedFile = opensDroppedFile
        self.onImportImages = onImportImages
        self.onFileDragHover = onFileDragHover
        self.onLinkClick = onLinkClick
        self.onOpenLocalLink = onOpenLocalLink
        self.onCaretRectChange = onCaretRectChange
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        self.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        self.placeholder = placeholder
        self.header = header
        self.headerCollapsedHeight = headerCollapsedHeight
        self.headerExpanded = headerExpanded
        self.retainedScrollDocumentIds = retainedScrollDocumentIds
        self.editorController = editorController
        self.forcedAppearanceName = forcedAppearanceName
        self.scrollViewConfigurator = scrollViewConfigurator
        self.undoManager = undoManager
        self.initialScrollOffset = initialScrollOffset
        self.readingPositionRequest = readingPositionRequest
        self.isDisplayed = isDisplayed
        self.isFocused = isFocused
        self.onRequestFocus = onRequestFocus
        self.magnificationRange = magnificationRange
        self.magnification = magnification
        self.onMagnificationChanged = onMagnificationChanged
    }

    /// The forced appearance resolved from `forcedAppearanceName` (`nil` follows the
    /// system). Shared by make/update so the two derivations can't drift.
    private var resolvedAppearance: NSAppearance? {
        forcedAppearanceName.flatMap { NSAppearance(named: $0) }
    }

    /// The scroll view's safe-area content insets derived from the configuration.
    /// Shared by make/update so the two derivations can't drift.
    private var desiredContentInsets: NSEdgeInsets {
        NSEdgeInsets(
            top: configuration.safeAreaInsets.top,
            left: configuration.safeAreaInsets.leading,
            bottom: configuration.safeAreaInsets.bottom,
            right: configuration.safeAreaInsets.trailing
        )
    }

    public func makeNSView(context: Context) -> NSScrollView {
        makeNativeView(coordinator: context.coordinator)
    }

    /// Creates an AppKit editor whose lifetime is managed by the caller.
    ///
    /// Create one coordinator with ``makeCoordinator()`` and retain it alongside
    /// the returned view. After assigning a viewport frame, call
    /// ``updateNativeView(_:coordinator:)`` to perform the initial styling pass.
    /// The same pair can move between AppKit containers without losing native
    /// text storage, selection, or undo targets. On final disposal, call
    /// ``dismantleNSView(_:coordinator:)`` once before releasing the pair.
    ///
    /// - Parameter coordinator: The coordinator created for this editor.
    /// - Returns: The scroll view containing the editor's native text system.
    public func makeNativeView(coordinator: Coordinator) -> NSScrollView {
        PerfTrace.stamp("makeNSView.start")
        defer { PerfTrace.stamp("makeNSView.end") }
        let scrollView = ClampedScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = configuration.scrollers.hasVerticalScroller
        scrollView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        scrollView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        scrollView.drawsBackground = false
        // PageFlow fork knob: force the editor's appearance (nil = follow system). The
        // initial full-document style below bakes math/tables against this appearance.
        scrollView.appearance = resolvedAppearance
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = desiredContentInsets

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:).
        let textView = NativeTextView(frame: .zero)

        // Configure the auto-created text container.
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        if let readingWidth = configuration.readingWidth {
            // Fix wrap width at readingWidth so text never re-wraps on resize; only the column's position moves.
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: readingWidth, height: .greatestFiniteMagnitude)
        } else {
            textContainer.widthTracksTextView = true
        }
        textView.textContainerInset = NSSize(
            width: configuration.horizontalLayoutInset,
            height: configuration.textInsets.vertical
        )
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        textView.string = text
        textView.delegate = coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        // Width and origin are driven by the container document view (see below).
        textView.autoresizingMask = []
        textView.backgroundColor = .clear
        // Body compositing for the scroll-away header (clipsToBounds + redraw policy)
        // is applied by ScrollingHeaderController when a header is first supplied, so
        // header-less embedders keep AppKit's default rendering.
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking.automaticSpellingCorrection
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = configuration.spellChecking.grammarChecking
        textView.isAutomaticQuoteSubstitutionEnabled = configuration.inputSubstitution.automaticQuoteSubstitution
        textView.isAutomaticDataDetectionEnabled = configuration.inputSubstitution.automaticDataDetection
        textView.isAutomaticDashSubstitutionEnabled = configuration.inputSubstitution.automaticDashSubstitution
        textView.isAutomaticTextReplacementEnabled = configuration.inputSubstitution.automaticTextReplacement
        textView.onPasteImage = onPasteImage
        textView.onDropDocuments = onDropDocuments
        textView.opensDroppedFile = opensDroppedFile
        textView.onImportImages = onImportImages
        textView.onFileDragHover = onFileDragHover
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = .plainText
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        // The document view is ALWAYS a container (`NativeTextViewContainer`) hosting
        // the text view, the optional scroll-away header (a top band stacked ABOVE the
        // text view as a sibling — disjoint frames, so body/header overlap is
        // geometrically impossible), and, in reading-column mode, the full-width
        // wide-table overlays around the centered fixed-width column. The text view
        // keeps managing its own height; the container offsets it below the header
        // band and sizes itself to the sum.
        let vpSize = scrollView.contentView.bounds.size
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: vpSize))
        container.autoresizingMask = [.width]
        container.clipsToBounds = true
        container.textView = textView
        let initialWidth = configuration.readingWidth != nil ? textView.readingColumnWidth : vpSize.width
        textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: textView.frame.height)
        container.addSubview(textView)
        scrollView.documentView = container
        textView.drawNoBackground()
        // Cheap viewport warmup helps the host's first frame/layout pass, but
        // TextKit may visit later paragraphs even with a zero-size viewport.
        // Defer raw warmup if any paragraph exceeds the existing work budget;
        // the first styled update still performs the final exact layout.
        var paragraphLength = 0
        var canWarmViewport = true
        for unit in copiedUTF16(of: text as NSString) {
            paragraphLength += 1
            if paragraphLength > NativeTextViewCoordinator.deferredRestyleMargin {
                canWarmViewport = false
                break
            }
            if unit == 0x000A || unit == 0x000D || unit == 0x2029 { paragraphLength = 0 }
        }
        if canWarmViewport {
            PerfTrace.time("mount.layout") { textLayoutManager.textViewportLayoutController.layoutViewport() }
        }

        // Cross-launch reading-position restore (fork knob): land at the saved
        // offset instead of the top; clampToInsets bounds it if the document shrank.
        let mountOffset = initialScrollOffset ?? -scrollView.contentInsets.top
        ScrollTrace.stamp("mount")
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: mountOffset))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        coordinator.textView = textView
        coordinator.installFolding(in: textView)
        coordinator.installFindRenderingValidator(in: textLayoutManager)
        coordinator.onCaretRectChange = onCaretRectChange
        coordinator.onInlineSelectionChange = onInlineSelectionChange
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        // The overscroll measure would lay the raw note out in full (~170 ms on
        // a 490 KB note); the rebuild that follows in `updateNSView` measures
        // the styled note instead. The clamp below only needs the viewport.
        textView.setPlaceholder(placeholder)
        // Initial reading-column centering; the resize observer below handles later changes.
        if configuration.readingWidth != nil {
            textView.centerReadingColumn(forClipWidth: scrollView.contentView.bounds.width)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        coordinator.lastObservedViewportWidth = scrollView.contentView.bounds.width
        coordinator.installViewObservers(scrollView: scrollView, textView: textView)
        reconcileHeader(textView: textView, coordinator: coordinator)
        // PageFlow fork knob: PDF-style visual magnification (pinch / ⌘± /
        // Ctrl-scroll zoom the whole document, no reflow). Enabled + bounded here;
        // the host-owned level is projected in updateNSView.
        if let range = magnificationRange {
            scrollView.allowsMagnification = true
            scrollView.minMagnification = range.lowerBound
            scrollView.maxMagnification = range.upperBound
            scrollView.onMagnificationChanged = onMagnificationChanged
            if let m = magnification {
                scrollView.magnification = min(max(m, range.lowerBound), range.upperBound)
                // Restored zoom ≠ 1: the container must grow to the effective
                // width and width-fitted blocks re-fit to it. The initial style
                // pass already reads the zoom-aware width; this settles the
                // container geometry + overlays right behind it (ADR-0019).
                if abs(scrollView.magnification - 1) > 0.001 {
                    textView.magnificationDidSettle()
                }
            }
        }
        // PageFlow fork knob: host chrome hook (e.g. custom scroller), make-time only.
        scrollViewConfigurator?(scrollView)
        coordinator.reconcileSelectionBar(in: scrollView)
        return scrollView
    }

    /// Projects the host-owned magnification onto the scroll view, zoomed about
    /// the viewport CENTER (⌘±/⌘0/restore). Guarded by an epsilon so it never
    /// fights a live pinch — and programmatic `setMagnification` does not post
    /// `didEndLiveMagnify`, so this can't loop with `onMagnificationChanged`.
    /// `centeredAt` is in the content (clip) view's coordinate system.
    private func projectMagnification(_ nsView: NSScrollView) {
        guard let range = magnificationRange, let m = magnification,
              let clamped = nsView as? ClampedScrollView else { return }
        let target = min(max(m, range.lowerBound), range.upperBound)
        guard abs(nsView.magnification - target) > 0.001 else { return }
        let center = NSPoint(x: nsView.contentView.bounds.midX, y: nsView.contentView.bounds.midY)
        clamped.noteMagnificationChanged()   // freeze per-frame layout work (see isZoomInProgress)
        ScrollTrace.stamp("projectMagnification")
        nsView.setMagnification(target, centeredAt: center)
        clamped.clampToInsets()
        // Programmatic setMagnification posts no live-magnify notifications —
        // request the width-fitted-block re-fit explicitly (debounced, so a
        // held-down ⌘+ re-fits once at the end of the burst). ADR-0019.
        nsView.nativeTextView?.magnificationDidSettle()
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let textView = nsView.nativeTextView {
            coordinator.tableEditingSession.finishInput()
            coordinator.tableEditingSession.retire()
            if textView.hasMarkedText() { textView.unmarkText() }
            coordinator.commitTextSync(for: textView)
            // Whole-span format edits register their inverse against the
            // coordinator; the undo manager does not retain it.
            textView.undoManager?.removeAllActions(withTarget: coordinator)
        }
        if let observer = coordinator.foldStorageObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.foldStorageObserver = nil
        coordinator.blockMover.uninstall()
        coordinator.foldControls?.uninstall()
        coordinator.foldControls = nil
        coordinator.imageControls?.uninstall()
        coordinator.imageControls = nil
        coordinator.cancelDocumentWork()
        if coordinator.editorController?.coordinator === coordinator {
            coordinator.editorController?.coordinator = nil
        }
        coordinator.textView = nil
        coordinator.removeViewObservers()
        ScrollTrace.forget(nsView)
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        updateNativeView(nsView, coordinator: context.coordinator)
    }

    /// Projects the current document and presentation onto an existing native editor.
    ///
    /// Call after mounting and whenever bindings, content, focus, visibility, or
    /// configuration change. This uses the same update path as SwiftUI, including
    /// composition guards and reading-position restoration.
    ///
    /// - Parameters:
    ///   - nsView: The view returned by ``makeNativeView(coordinator:)``.
    ///   - coordinator: The coordinator retained with that view.
    public func updateNativeView(_ nsView: NSScrollView, coordinator: Coordinator) {
        PerfTrace.stamp("updateNSView.start")
        guard let textView = nsView.nativeTextView else { return }
        defer {
            coordinator.reconcileSelectionBar(in: nsView)
            coordinator.synchronizeFolding()
        }
        let isNodeSwitch = coordinator.documentId != documentId
        let sourceChanged = !(coordinator.lastSyncedText as NSString).isEqual(to: text)
        let fontChanged = coordinator.fontName != fontName || coordinator.fontSize != fontSize
        let imageFingerprint = configuration.services.images.fingerprint()
        let wikiFingerprint = configuration.services.wikiLinks.fingerprint()
        let imageChanged = imageFingerprint != coordinator.lastImageFingerprint
        let presentationChanged = fontChanged || imageChanged
            || wikiFingerprint != coordinator.lastWikiFingerprint
            || !configuration.hasSamePresentation(as: coordinator.configuration)
            || !configuration.hasSameServices(as: coordinator.configuration)
            || textView.isEditable != isEditable
            || nsView.appearance?.name != resolvedAppearance?.name
        let layoutChanged = !configuration.hasSameLayout(as: coordinator.configuration)
        let configurationChanged = presentationChanged || layoutChanged
            || configuration.keyBindings != coordinator.configuration.keyBindings
            || configuration.inputSubstitution != coordinator.configuration.inputSubstitution
            || !configuration.hasSameBus(as: coordinator.configuration)
        if isNodeSwitch {
            coordinator.tableEditingSession.finishInput()
            coordinator.publishOutgoingSource(from: textView)
            textView.breakUndoCoalescing()
            coordinator.cancelDocumentWork()
        }
        coordinator.updateBindings(text: $text, isWikiLinkActive: $isWikiLinkActive)
        coordinator.onLinkClick = onLinkClick
        coordinator.onOpenLocalLink = onOpenLocalLink
        coordinator.onCaretRectChange = onCaretRectChange
        coordinator.onInlineSelectionChange = onInlineSelectionChange
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        coordinator.fontName = fontName
        coordinator.fontSize = fontSize
        coordinator.forcedAppearanceName = forcedAppearanceName
        coordinator.lastImageFingerprint = imageFingerprint
        coordinator.lastWikiFingerprint = wikiFingerprint
        if configurationChanged { coordinator.configuration = configuration }

        // Visual-zoom (fork knob): ENABLE magnification + keep the user-change
        // callback fresh here; the LEVEL is projected by `projectMagnification`
        // below — ordered around the node-switch offset save so a differing
        // incoming zoom can't move (and then corrupt) the outgoing document's
        // saved scroll offset.
        if let range = magnificationRange, let clamped = nsView as? ClampedScrollView {
            if !nsView.allowsMagnification {
                nsView.allowsMagnification = true
                nsView.minMagnification = range.lowerBound
                nsView.maxMagnification = range.upperBound
            }
            clamped.onMagnificationChanged = onMagnificationChanged
        }

        reconcileHeader(textView: textView, coordinator: coordinator)

        // P1: a reused coordinator must re-bind to the current controller. SwiftUI
        // keeps one coordinator across updates, but a document/session switch on
        // the same mounted editor swaps the host's editorController; without this
        // the new controller's currentStorageText/commitPendingText stay
        // disconnected and the old one keeps pointing here (review P2).
        if coordinator.editorController !== editorController {
            if coordinator.editorController?.coordinator === coordinator {
                coordinator.editorController?.coordinator = nil
            }
            coordinator.editorController = editorController
            editorController?.coordinator = coordinator
        }
        // Per-document undo (fork knob): re-bind BEFORE the node-switch block so a
        // document switch resolves undo against the INCOMING document's manager.
        coordinator.hostUndoManager = undoManager
        // Presence (host-parity knobs): a warm tab off screen is hidden with its
        // observers paused; the active tab owns the keyboard; a click asks the
        // host to make this tab active.
        coordinator.onRequestFocus = onRequestFocus
        if let request = readingPositionRequest, request.token != coordinator.appliedReadingPositionToken {
            coordinator.pendingReadingPositionRequest = request
        }
        if let clamped = nsView as? ClampedScrollView {
            coordinator.applyDisplayed(isDisplayed, scrollView: clamped, textView: textView)
        }
        coordinator.applyFocused(isFocused && isDisplayed, textView: textView)
        PerfTrace.stamp("update.presence")

        // Same-document zoom (⌘±, ⌘0, restore) projects here — before the text
        // early-returns, so a pure zoom command always lands. A node switch
        // projects INSIDE the switch block instead, after the outgoing offset is
        // saved (below), so a differing incoming zoom can't corrupt it.
        if !isNodeSwitch { projectMagnification(nsView) }

        // Drop remembered offsets for documents no longer retained (always keep
        // the current one). Only rebuilds the dict when something must go.
        if let retained = retainedScrollDocumentIds {
            let needsPrune = coordinator.scrollOffsets.keys.contains { key in
                key != documentId && !retained.contains(key)
            }
            if needsPrune {
                coordinator.scrollOffsets = coordinator.scrollOffsets.filter {
                    $0.key == documentId || retained.contains($0.key)
                }
            }
        }

        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartDocumentId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            coordinator.isWritingToolsActive = false
        } else if wtActive {
            coordinator.pendingPresentationRefresh = coordinator.pendingPresentationRefresh || presentationChanged
            coordinator.pendingIncomingSource = sourceChanged ? text : nil
            coordinator.pendingIsEditable = isEditable
            return
        }
        if coordinator.isComposing(in: textView) {
            coordinator.pendingCompositionRefresh = true
            coordinator.pendingPresentationRefresh = coordinator.pendingPresentationRefresh || presentationChanged
            coordinator.pendingIncomingSource = sourceChanged ? text : nil
            coordinator.pendingIsEditable = isEditable
            return
        }
        if !isNodeSwitch && sourceChanged {
            coordinator.cancelDocumentWork()
            if !(textView.string as NSString).isEqual(to: text) {
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }
        }

        textView.onPasteImage = onPasteImage
        textView.onDropDocuments = onDropDocuments
        textView.opensDroppedFile = opensDroppedFile
        textView.onImportImages = onImportImages
        textView.onFileDragHover = onFileDragHover
        textView.setPlaceholder(placeholder)
        coordinator.applyLayoutConfiguration(to: textView)
        let needsFullRestyle = presentationChanged
        if imageChanged, let layoutManager = textView.textLayoutManager {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
        }
        if !isEditable {
            coordinator.tableEditingSession.finishInput()
            coordinator.tableEditingSession.retire()
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.insertionPointColor = isEditable ? coordinator.configuration.theme.bodyText : .clear
        let willRebuild = pendingInlineReplacement == nil
            && (isNodeSwitch
                || !(coordinator.didInitialFormatting
                     && !sourceChanged
                     && !fontChanged))
        if needsFullRestyle && !willRebuild {
            coordinator.restyleCurrentSource(in: textView, focusOffset: textView.readingPosition()?.anchorOffset)
            textView.refreshOverscrollAfterTextEdit(for: nsView)
        }
        if let pendingInlineReplacement {
            if pendingInlineReplacement.documentId == documentId,
               coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id {
                coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
            }
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }
        // Nothing to rebuild: the same document, already styled, same font. A
        // node switch always falls through — a new document can be byte-equal
        // to the old one (a reload, a same-name replace) and still needs the
        // switch below.
        if !isNodeSwitch,
           coordinator.didInitialFormatting,
           !sourceChanged,
           !fontChanged {
            coordinator.pendingRebuildRestore = nil
            if let clamped = nsView as? ClampedScrollView {
                coordinator.applyPendingReadingPosition(scrollView: clamped, textView: textView)
            }
            return
        }
        if fontChanged {
            coordinator.didInitialFormatting = false
        }
        if isNodeSwitch {
            // Save the outgoing document's scroll position — unless it just left
            // the retained set, in which case let it reset to top next time.
            if let outgoingId = coordinator.documentId,
               retainedScrollDocumentIds?.contains(outgoingId) ?? true {
                coordinator.scrollOffsets[outgoingId] = nsView.contentView.bounds.origin.y
            }
            // Outgoing offset is now banked at the OLD magnification — safe to
            // apply the incoming document's zoom (park + restore below set the
            // final offset, in doc coords, independent of the scale).
            projectMagnification(nsView)
            coordinator.documentId = documentId
            coordinator.localFoldSession.reset()
            // Typing coalescing must never span documents.
            textView.breakUndoCoalescing()
            // With host-supplied PER-DOCUMENT managers each document keeps its
            // own history across warm switches; only the shared window-undo
            // fallback must be cleared to keep documents from cross-undoing.
            if undoManager == nil {
                textView.undoManager?.removeAllActions()
            }
            coordinator.didInitialFormatting = false
            coordinator.didEnsureLayoutForCurrentDocument = false
            coordinator.resetImageEmbedState()
            coordinator.resetPerDocumentEditState()
            coordinator.isUpdatingSourceOrStyle = true
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.isUpdatingSourceOrStyle = false
            // Drop old document's wide-table overlays synchronously, AND its
            // per-table horizontal scroll offsets. Those offsets are keyed by
            // POSITIONAL table ordinal and deliberately outlive overlay
            // destroy/recreate WITHIN a document (so a wide table stays
            // horizontally scrolled while you edit around it) — but across a
            // node switch the new document's Nth table would inherit the old
            // document's Nth-table offset. Clear here, at the one node-switch
            // seam, not in removeAllWideTableOverlays (which also runs mid-edit).
            textView.tableHorizontalScrollOffsets.removeAll()
            textView.removeAllWideTableOverlays()
            // The re-fit de-dupe memory is per-document (the rebuild below
            // styles the new document at the current width anyway).
            textView.lastBlockFitRefitWidth = nil
            textView.lastBlockRasterScale = nil
            // Park at top during the rebuild; the new document's own saved offset
            // (if any) is restored after its height is known (see below).
            ScrollTrace.stamp("nodeSwitchPark")
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        // Not when a rebuild follows: that path re-measures after styling, and
        // measuring here first laid the UNSTYLED note out in full (~170 ms on a
        // 490 KB note) only for the rebuild to invalidate it.
        if !willRebuild { textView.recalcOverscroll(for: nsView) }
        (nsView as? ClampedScrollView)?.clampToInsets()

        // Sync coordinator's font fields BEFORE the rebuild so the helper
        // reads the current values from the View struct.
        coordinator.fontName = fontName
        coordinator.fontSize = fontSize
        // A presentation update styles the authoritative live text. Installing
        // a host replacement is a separate transaction with its own undo lifetime.
        // An unsized view (a first mount) shows nothing yet, so there is no
        // reading position to keep; reading one would lay out at width 0.
        let isSized = textView.window != nil && (textView.textContainer?.size.width ?? 0) > 1
        let focusOffset = coordinator.pendingReadingPositionRequest?.position.anchorOffset
            ?? (isNodeSwitch || !isSized ? nil : textView.readingPosition()?.anchorOffset)
        if isNodeSwitch || sourceChanged {
            coordinator.rebuildTextStorageAndStyle(
                textView, from: text, invalidateLayout: isNodeSwitch, focusOffset: focusOffset
            )
        } else {
            coordinator.restyleCurrentSource(in: textView, focusOffset: focusOffset)
        }
        textView.recalcOverscroll(for: nsView)
        (nsView as? ClampedScrollView)?.clampToInsets()
        // Height is measured now, so restore the saved offset; clampToInsets keeps
        // it in range if the document got shorter. A pending reading-position
        // request (applied below, once styled) supersedes the banked offset.
        if isNodeSwitch, coordinator.pendingReadingPositionRequest == nil,
           let savedY = coordinator.scrollOffsets[documentId] {
            ScrollTrace.stamp("nodeSwitchRestore")
            nsView.contentView.scroll(to: NSPoint(x: nsView.contentView.bounds.origin.x, y: savedY))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }
        // A host-driven rebuild of the SAME document (a reload, Writing Tools
        // ending) replaced the whole storage: put the caret and the reader back.
        if !isNodeSwitch, let restore = coordinator.pendingRebuildRestore {
            coordinator.pendingRebuildRestore = nil
            coordinator.restoreAfterRebuild(textView, position: restore.position, caret: restore.caret)
        }
        // Document rebuilds bypass textDidChange — re-derive emptiness here.
        textView.refreshPlaceholderVisibility()
        let generation = coordinator.documentGeneration
        DispatchQueue.main.async { [weak coordinator, weak textView] in
            guard let coordinator, let textView, generation == coordinator.documentGeneration else { return }
            // Parses only when a host shows code-block chrome.
            coordinator.updateCodeBlockSelection(textView: textView)
        }

        coordinator.onCaretRectChange = onCaretRectChange
        coordinator.onInlineSelectionChange = onInlineSelectionChange
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.didInitialFormatting = true
        if let clamped = nsView as? ClampedScrollView {
            coordinator.applyPendingReadingPosition(scrollView: clamped, textView: textView)
        }
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        coordinator.lastImageFingerprint = configuration.services.images.fingerprint()
        coordinator.lastWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.onOpenLocalLink = onOpenLocalLink
        coordinator.userPrefersContinuousSpellChecking = configuration.spellChecking.continuousSpellChecking
        coordinator.userPrefersGrammarChecking = configuration.spellChecking.grammarChecking
        coordinator.userPrefersAutomaticSpellingCorrection = configuration.spellChecking.automaticSpellingCorrection
        coordinator.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        // P1: bind the host's controller handle to this live coordinator.
        coordinator.editorController = editorController
        editorController?.coordinator = coordinator
        coordinator.hostUndoManager = undoManager
        return coordinator
    }
}
// MARK: - Scrolling header view

private extension NativeTextViewWrapper {
    /// Host the embedder's header above the body, inside the container document
    /// view. The hosted content refreshes on every SwiftUI update; build,
    /// collapse/expand, and teardown live in `ScrollingHeaderController`.
    func reconcileHeader(textView: NSTextView, coordinator: Coordinator) {
        let coord = coordinator
        guard let container = (textView as? NativeTextView)?.superview as? NativeTextViewContainer else { return }

        guard let header else {
            if let controller = coord.headerController {
                controller.remove(from: container)
                coord.headerController = nil
            }
            return
        }
        let controller = coord.headerController ?? ScrollingHeaderController()
        coord.headerController = controller
        controller.reconcile(
            header: header,
            collapsedHeight: headerCollapsedHeight,
            expanded: headerExpanded,
            container: container
        )
    }
}
