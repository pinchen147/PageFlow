//
//  NativeTextViewCoordinator.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Keeps the editor in sync while you type, updating formatting, selections,
// links, and other editing behavior in one place.
import AppKit
import SwiftUI

/// `NSTextViewDelegate` that bridges ``NativeTextViewWrapper`` and the
/// underlying `NSTextView`.
///
/// The coordinator is created automatically by SwiftUI; embedders never
/// construct one directly. Behaviors that don't fit in the main file live
/// in extensions (Autocorrect, CodeBlocks, Find, InlineSelection,
/// Notifications, Restyling, TextDelegate, WritingTools).
public final class NativeTextViewCoordinator: NSObject, NSTextViewDelegate {
    var documentId: String?
    /// Remembered scroll offset (`bounds.origin.y`) per `documentId` — saved on
    /// switch-away, restored on switch-back.
    var scrollOffsets: [String: CGFloat] = [:]
    @Binding var text: String
    @Binding var isWikiLinkActive: Bool
    var fontName: String
    var fontSize: CGFloat
    /// The keyboard commands in force: the host's live ones, else the configuration's.
    var keyBindings: MarkdownKeyBindings {
        MainActor.assumeIsolated { editorController?.keyBindings } ?? configuration.keyBindings
    }

    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            if !configuration.hasSameBus(as: oldValue) {
                subscribeToBusNotifications(replacing: oldValue.services.bus)
            }
            subscribeToAppearanceNotification()
        }
    }
    /// Last `EmbeddedImageProvider.fingerprint()` value we've reflected in
    /// the textView's attributes. We cache it here because embedders that
    /// MUTATE the same provider over time (async URL fetches, etc.) would
    /// otherwise fool the wrapper's "did the embedder hand us a new
    /// fingerprint" check — re-reading the same object twice always
    /// returns the current value, regardless of when state changed.
    var lastImageFingerprint: AnyHashable?
    var lastWikiFingerprint: AnyHashable?
    private var busObservers: [NSObjectProtocol] = []
    var viewObserverTokens: [NSObjectProtocol] = []
    /// Clip width seen by the frame observer; width-only changes re-center the column.
    var lastObservedViewportWidth: CGFloat = 0
    /// The last `isDisplayed` / `isFocused` the wrapper applied (transition edges only).
    var lastDisplayed = true
    var lastFocused = false
    /// The reading-position request token already applied by this editor, and
    /// the request waiting for a styled, displayed viewport to land in.
    var appliedReadingPositionToken: UUID?
    var pendingReadingPositionRequest: ReadingPositionRequest?
    /// Position + caret to re-land after the next host-driven rebuild (Writing
    /// Tools end, a reload): the rebuild replaces the whole storage.
    var pendingRebuildRestore: (position: ReadingPosition?, caret: Int)?
    /// Where the reader is, refreshed on every settled scroll tick, so a reflow
    /// the editor did not start (a pane resize, a split, a hidden tab shown at
    /// a new width) can land the same paragraph at the same place.
    var lastReadingPosition: ReadingPosition?
    /// Fired on mouse-down so the host can activate this tab.
    var onRequestFocus: (() -> Void)?
    private var registeredAppearanceObserverName: Notification.Name?
    weak var textView: NSTextView?
    /// PageFlow fork patch P1 (doc 10 §3 / ADR-0010): host-retained handle for the
    /// synchronous save-time text read/flush. Weak — the host owns it.
    weak var editorController: MarkdownEditorController?
    /// The document's single in-place table cell editor (TableEditor/).
    lazy var tableEditingSession = MarkdownTableEditingSession(coordinator: self)
    /// PageFlow fork knob: host-supplied per-document UndoManager, returned by
    /// `undoManager(for:)` so text edits register into the HOST's per-tab undo
    /// stack, not the window's. `nil` keeps AppKit's default (window) undo.
    /// The wrapper re-binds it on every update. See PAGEFLOW-FORK.md.
    var hostUndoManager: UndoManager?

    /// Route the text view's undo registration to the host's per-document
    /// manager when one is supplied (PageFlow: `MarkdownContent.undoManager`,
    /// the stack the Edit menu drives), else AppKit's default resolution.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        hostUndoManager ?? view.window?.undoManager
    }
    /// Owns the scroll-away header (build, content refresh, collapse/expand,
    /// teardown). Created on first reconcile with a non-nil header.
    var headerController: ScrollingHeaderController?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var onLinkClick: ((String) -> Void)?
    var onOpenLocalLink: ((URL) -> Void)?
    var onCaretRectChange: ((CGRect) -> Void)?
    var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    var didInitialFormatting: Bool = false
    /// One-shot guard so `updateCodeBlockSelection` only forces a full-document layout once per document.
    var didEnsureLayoutForCurrentDocument: Bool = false
    var lastSyncedText: String
    /// Generation token for the coalesced text→binding sync (see `scheduleTextSync`).
    /// Bumped on every keystroke; a scheduled sync only commits if it is still the
    /// latest, so a typing burst writes the SwiftUI binding ONCE on the trailing edge
    /// instead of on every keystroke.
    var textSyncGeneration: Int = 0
    var documentGeneration: Int = 0
    var isUpdatingSourceOrStyle = false
    var pendingIncomingSource: String?
    var pendingIsEditable: Bool?
    var pendingCompositionRefresh = false
    var pendingPresentationRefresh = false
    var activeFindHighlights: [FindHighlight] = []
    var pendingFindCommand: PendingFindCommand?
    var findRenderingNeedsReset = false
    var forcedAppearanceName: NSAppearance.Name?
    var wtSessionGeneration = 0
    var isProgrammaticEdit: Bool = false
    var isLiteralInsertion = false
    /// A span edit is being applied; the table session follows it afterwards
    /// (`sourceDidChange`) instead of ending.
    var isApplyingSpanEdit = false
    /// The arrow key moving the document caret now, so a caret it puts in a
    /// rendered table enters the cell the reference editor would (+TableEntry).
    var pendingTableEntry: TableEntryIntent?
    /// The table that ends the note while the caret waits after it (the reference
    /// editor's gap cursor): no text position exists there until input makes one.
    var tableGapCaret: Int?
    /// the reference editor's selection bar, when the configuration shows it.
    var selectionBar: MarkdownSelectionBarController?
    /// the reference editor's "…" button for the table with the caret (with the selection bar).
    var tableActions: TableActionsController?
    /// the reference editor's hover chrome for tables: grips, handle, add bars (with the selection bar).
    var tableChrome: TableChromeController?
    /// the reference editor's one-time table hint (with the selection bar).
    var tableHint: TableHintView?
    /// the reference editor's docked table scroller (with the selection bar).
    var tableProxy: TableProxyScroller?
    /// the reference editor's comments (with the selection bar and a host controller).
    var comments: MarkdownCommentsController?
    /// Called when the selection's formatting changes (bar, Format menu, toolbar).
    var onFormatStateChange: ((MarkdownFormatState) -> Void)?
    var publishedFormatState = MarkdownFormatState()
    /// A table cell's keystroke whose table re-renders when typing pauses.
    var isDeferringTableRender = false
    var isWritingToolsActive: Bool = false
    var wtStartDocumentId: String?
    weak var wtChildWindow: NSWindow?
    var wtInitialChildOrigin: CGPoint?
    var wtInitialSelectionRange: NSRange?
    enum WTMode { case unknown, proofread, rewrite }
    var wtDetectedMode: WTMode = .unknown
    var wtUndoObserverTokens: [NSObjectProtocol] = []
    var wtUndoneDuringSession: Bool = false
    var wtPostUndoSnapshot: String?
    var lastAppliedInlineReplacementID: UUID?
    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []

    var pendingEditedRange: NSRange? = nil
    var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    var pendingPreEditRestyleRanges: [NSRange] = []
    var pendingTextChange: TextChange? = nil
    var pendingEditMayChangeBlockStructure = false
    var pendingEditRequiresFullDocumentRestyle = false
    var pendingInlineFormattingEdit = false
    /// Set by a whole-document format before `didChangeText`: the viewport's
    /// character range in the NEW text, so the restyle can go viewport-first.
    var pendingViewportFirstRange: NSRange? = nil
    /// Ranges still to restyle in idle passes (see +DeferredRestyle).
    var deferredRestyleRanges: [NSRange] = []
    /// The background parse whose landing still owes the note its styling
    /// (`+BackgroundParse.swift`). A newer one, or a whole-note restyle on
    /// main, takes the debt over.
    var pendingBackgroundStyle: UUID?
    /// Bulk-edit chunks preserve one source anchor until user/document state changes.
    var deferredRestyleAnchorsVisibleSource = false
    var bulkViewportAnchor: BulkViewportAnchor?
    var deferredRestyleScheduled = false
    var previousCaretLocation: Int? = nil
    var skipNextSelectionChangeAfterPlainEdit = false
    /// Drag-select suppressed a restyle; replayed on the next non-drag selection change.
    var needsRestyleAfterDrag = false

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    var codeBlockSelectionGeneration: Int = 0
    /// Accepted native source edits; binding publication alone does not advance it.
    var nativeSourceGeneration: Int = 0
    var cachedCodeBlockSourceGeneration: Int = -1
    /// Source snapshot for exact cache hits. Plain typing keeps it current and
    /// records the insertions (`plainInsertionsSinceParse`) so the next lookup
    /// rebases the cached tokens instead of re-parsing the note.
    var cachedParsedChars: [UInt16]? {
        didSet { if cachedParsedChars == nil { plainInsertionsSinceParse.removeAll() } }
    }
    var cachedParsedDocument: ParsedDocument?
    /// Plain insertions typed since `cachedParsedDocument` was parsed, in order,
    /// each in the source as it was when typed; consecutive keystrokes merge.
    var plainInsertionsSinceParse: [NSRange] = []
    var pendingPlainFastPathExpansion: PlainFastPathExpansion?
    // Skip spellcheck property setters when the state wouldn't change.
    var cachedSpellingDisabled: Bool?

    /// Memoized base font + paragraph style. `TextStylingService.makeBaseFontAndStyle`
    /// allocates an `NSMutableParagraphStyle` with 24 `NSTextTab` stops; it was rebuilt
    /// on every keystroke (the scoped restyle and the `shouldChangeTypingAttributes`
    /// shim both call it). Recompute only when an input that affects it changes.
    private struct BaseStyleKey: Equatable {
        let fontName: String
        let fontSize: CGFloat
        let lineHeightExtra: CGFloat
        let spacingFactor: CGFloat
        let indentPerLevel: CGFloat
        let layoutBridgeID: ObjectIdentifier?
    }
    private var cachedBaseStyleKey: BaseStyleKey?
    private var cachedBaseStyle: (font: NSFont, style: NSMutableParagraphStyle)?

    /// Base font + paragraph style for the current font/config, memoized (see above).
    /// The returned paragraph style is shared and must not be mutated by callers; they
    /// only read it (set as a text/typing attribute), which matches the prior behavior
    /// where a fresh-but-identical instance was shared across a single restyle.
    func baseFontAndStyle() -> (font: NSFont, style: NSMutableParagraphStyle) {
        let key = BaseStyleKey(
            fontName: fontName,
            fontSize: fontSize,
            lineHeightExtra: configuration.paragraph.lineHeightExtraSpacing,
            spacingFactor: configuration.paragraph.spacingFactor,
            indentPerLevel: configuration.lists.indentPerLevel,
            layoutBridgeID: layoutBridge.map { ObjectIdentifier($0) }
        )
        if key == cachedBaseStyleKey, let cached = cachedBaseStyle {
            return cached
        }
        let made = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        cachedBaseStyleKey = key
        cachedBaseStyle = made
        return made
    }

    // Mirrors the user's last-known preference for each spell/grammar toggle.
    // `updateAutocorrectSettings` reads these when restoring outside a
    // suppress zone, so caret movement no longer clobbers a manual "off".
    var userPrefersContinuousSpellChecking: Bool = true
    var userPrefersGrammarChecking: Bool = true
    var userPrefersAutomaticSpellingCorrection: Bool = true

    /// Fires after the user toggles a spell/grammar/auto-correction menu item.
    /// Embedders persist the returned policy (e.g. to `UserDefaults`) and feed
    /// it back via ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    var currentSpellCheckingPolicy: SpellCheckingPolicy {
        SpellCheckingPolicy(
            continuousSpellChecking: userPrefersContinuousSpellChecking,
            grammarChecking: userPrefersGrammarChecking,
            automaticSpellingCorrection: userPrefersAutomaticSpellingCorrection
        )
    }

    /// Called from ``NativeTextView`` toggle overrides after `super` flips the
    /// underlying property. Snapshots the text view's state, refreshes the
    /// cache so the next caret move doesn't immediately overwrite it, and
    /// notifies the embedder.
    func didToggleSpellCheckingPolicy(textView: NSTextView) {
        userPrefersContinuousSpellChecking = textView.isContinuousSpellCheckingEnabled
        userPrefersGrammarChecking = textView.isGrammarCheckingEnabled
        userPrefersAutomaticSpellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
        // Invalidate the "didn't change" short-circuit so the next selection
        // update re-applies the preferences cleanly.
        cachedSpellingDisabled = nil
        onSpellCheckingPolicyChanged?(currentSpellCheckingPolicy)
    }

    /// Everything remembered about the outgoing document's edits: queued
    /// restyle work, the pre-edit token sets, the caret memory. Run at the
    /// node-switch seam so none of it is applied to the incoming document.
    func resetPerDocumentEditState(preservingReadingPosition: Bool = false) {
        deferredRestyleRanges.removeAll()
        deferredRestyleAnchorsVisibleSource = false
        bulkViewportAnchor = nil
        pendingViewportFirstRange = nil
        pendingEditedRange = nil
        pendingPreEditActiveTokenIndices = nil
        pendingPreEditRestyleRanges.removeAll(keepingCapacity: true)
        pendingTextChange = nil
        pendingEditMayChangeBlockStructure = false
        pendingEditRequiresFullDocumentRestyle = false
        pendingInlineFormattingEdit = false
        previousActiveTokenIndices.removeAll()
        previousCaretLocation = nil
        if !preservingReadingPosition {
            pendingRebuildRestore = nil
            lastReadingPosition = nil
        }
    }

    func removeViewObservers() {
        viewObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        viewObserverTokens.removeAll(keepingCapacity: true)
    }

    struct ParsedDocument {
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let latexTokens: [MarkdownToken]
        let blockLatexTokens: [MarkdownToken]
        let wikiLinkTokens: [MarkdownToken]
        let imageEmbedTokens: [MarkdownToken]
    }

    struct TextChange {
        let oldRange: NSRange
        let replacement: String

        var replacementLength: Int { replacement.utf16.count }
        var delta: Int { replacementLength - oldRange.length }
    }

    struct PlainFastPathExpansion {
        let insertionLocation: Int
        var delta: Int
        let activeTokenIndices: Set<Int>
    }

    enum InlineTokenContext {
        case wikiLink(token: MarkdownToken)
        case imageEmbed(token: MarkdownToken)

        var token: MarkdownToken {
            switch self {
            case .wikiLink(let token), .imageEmbed(let token):
                return token
            }
        }

        var selectionKind: InlineSelectionKind {
            switch self {
            case .wikiLink:
                return .wikiLink
            case .imageEmbed:
                return .imageEmbed
            }
        }
    }

    var isImageEmbedActive: Bool = false

    // Inline selection geometry, image-embed activation, and inline-token
    // detection live in `NativeTextViewCoordinator+InlineSelection.swift`.

    init(text: Binding<String>,
         fontName: String,
         fontSize: CGFloat,
         isWikiLinkActive: Binding<Bool>,
         onLinkClick: ((String) -> Void)?,
         onInlineSelectionChange: ((InlineSelectionState?) -> Void)?) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        _isWikiLinkActive = isWikiLinkActive
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = nil
        self.onInlineSelectionChange = onInlineSelectionChange
        self.lastSyncedText = text.wrappedValue
        super.init()
        // Init + didSet share this helper so the observer tracks whichever service is current.
        subscribeToAppearanceNotification()
    }

    func updateBindings(text: Binding<String>, isWikiLinkActive: Binding<Bool>) {
        _text = text
        _isWikiLinkActive = isWikiLinkActive
    }

    /// (Re)register the syntax-highlighter appearance observer; idempotent and unsubscribes on nil.
    private func subscribeToAppearanceNotification() {
        let target = configuration.services.syntaxHighlighter.appearanceDidChangeNotification
        if registeredAppearanceObserverName == target { return }
        if let current = registeredAppearanceObserverName {
            NotificationCenter.default.removeObserver(self, name: current, object: nil)
        }
        registeredAppearanceObserverName = nil
        guard let name = target else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: name,
            object: nil
        )
        registeredAppearanceObserverName = name
    }

    /// Subscribe to whichever bus notification names the current configuration
    /// supplies. Removes any previous subscriptions first so that swapping
    /// configurations at runtime doesn't double-fire handlers.
    private func subscribeToBusNotifications(replacing previous: MarkdownEditorBus) {
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        busObservers.removeAll(keepingCapacity: true)

        let bus = configuration.services.bus
        let center = NotificationCenter.default

        if let name = bus.applyBoldRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleBoldNotification(notification)
            })
        }
        if let name = bus.applyItalicRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleItalicNotification(notification)
            })
        }
        if let name = bus.applyUnderlineRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleUnderlineNotification(notification)
            })
        }
        if let name = bus.applyHeadingRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHeadingNotification(notification)
            })
        }
        if let name = bus.findScrollToRange {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindScrollToRange(notification)
            })
        }
        if let name = bus.findClearHighlights {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindClearHighlights(notification)
            })
        }
    }

    // Find-in-document highlight handlers live in
    // `NativeTextViewCoordinator+Find.swift`.

    deinit {
        NotificationCenter.default.removeObserver(self)
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        viewObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
    }
}

// MARK: - PageFlow fork patch P1: synchronous source read / pending-write flush
//
// The source reaches the host @Binding on the trailing edge of a typing burst (a
// 1 s debounce, `scheduleTextSync` in `+TextDelegate.swift`), so a synchronous
// quit/close `saveSync` could read stale text. These helpers read the LIVE
// `NSTextView.string` — the native string is the source — so the value is
// current even before the debounce fires.
extension NativeTextViewCoordinator {
    /// The live source, read synchronously from the text view (same as
    /// `snapshotDisplayText`). Returns `lastSyncedText` when no text view is attached.
    @MainActor
    func snapshotStorageText() -> String {
        textView?.string ?? lastSyncedText
    }

    /// The native string uses exact source coordinates, including hidden markers.
    @MainActor
    func snapshotDisplayText() -> String {
        textView?.string ?? lastSyncedText
    }

    /// Flush the pending (debounced) binding write synchronously: push the live source
    /// into the host `@Binding` and refresh the de-dupe guard. Returns the text.
    ///
    /// Delegates to `commitTextSync(for:)` — the single source of truth for the
    /// debounced write-back — so it stays byte-identical to the typing/teardown
    /// paths and survives an upstream rebase (no copy to drift). That shared impl
    /// also respects the `!isWritingToolsActive` guard, so a save fired mid-rewrite
    /// does NOT push a transient Writing-Tools state into the binding — exactly as
    /// the debounced write-back would have skipped. (The save-time *read*,
    /// `snapshotStorageText()`, deliberately ignores WT to capture on-screen text.)
    ///
    /// Mid-composition (save, close or quit while an input method is open), the
    /// committed source is published and the open composition stays with the
    /// input method: it is not text yet, and committing it would write raw
    /// romanization the user never chose.
    @MainActor
    func commitPendingTextNow() -> String {
        guard let tv = textView else { return lastSyncedText }
        tableEditingSession.finishInput()
        if isComposing(in: tv), !isWritingToolsActive {
            let source = tv.string as NSString
            let marked = tv.markedRange()
            publishSource(marked.location == NSNotFound || NSMaxRange(marked) > source.length
                ? source as String
                : source.replacingCharacters(in: marked, with: ""))
        } else {
            commitTextSync(for: tv)
        }
        return lastSyncedText
    }
}

extension NSTextView {
    func viewRect(forCharacterRange range: NSRange, using bridge: LayoutBridge?) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = bridge,
              let textContainer = textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let containerOrigin = textContainerOrigin
        boundingRect.origin.x += containerOrigin.x
        boundingRect.origin.y += containerOrigin.y
        // The text view sits inside a container document view, offset by the header
        // band (y) and the reading-column centering (x), so its glyph rects
        // (text-view-local) must be lifted into the document view's space before
        // subtracting the scroll offset (which is in document-view space).
        // `convert(.zero, to: doc)` covers both offsets and self-zeroes if this text
        // view ever IS the document view.
        if let scrollView = enclosingScrollView {
            if let doc = scrollView.documentView, doc !== self {
                let originInDoc = convert(CGPoint.zero, to: doc)
                boundingRect.origin.x += originInDoc.x
                boundingRect.origin.y += originInDoc.y
            }
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}
