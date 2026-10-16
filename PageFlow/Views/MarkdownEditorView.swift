//
//  MarkdownEditorView.swift
//  PageFlow
//
//  PageFlow's editor surface over the vendored swift-markdown-engine (ADR-0010):
//  the canonical editor configuration — the literal-markdown input policy (fork
//  patch P5), auto-pairing off, the math, diagram and syntax-highlight bridges —
//  and the per-editor controller handed to the engine wrapper. Other host files
//  use engine types directly (the controller, reading positions, the bus); the
//  configuration lives only here.
//

#if canImport(MarkdownEngine)
import SwiftUI
import AppKit
import MarkdownEngine
#if canImport(MarkdownEngineLatex)
import MarkdownEngineLatex
#endif
#if canImport(MarkdownEngineMermaid)
import MarkdownEngineMermaid
#endif
#if canImport(MarkdownEngineCodeBlocks)
import MarkdownEngineCodeBlocks
#endif

/// PageFlow's Markdown editor surface: a thin adapter over the engine's
/// `NativeTextViewWrapper` that injects the host configuration and the per-editor
/// save-time controller. Owns no document logic — the caller binds `text` to its
/// `MarkdownDocumentManager.text` and retains the `editorController` for the
/// editor's lifetime (ADR-0012 D2: the controller backs the synchronous quit-save
/// read).
@MainActor
struct MarkdownEditorView: View {
    @Binding var text: String
    /// Stable per-tab id (= `TabSession.id`, ADR-0012 D4), used by the engine for
    /// scroll retention and the scoped bus.
    let documentId: String
    /// Host-retained handle for the synchronous save-time text read/flush (P1).
    let editorController: MarkdownEditorController
    /// This tab's PER-TAB scoped editor bus (fork P2): unique find Notification.Names
    /// + `scopeByObject: true`, owned by the tab's `MarkdownContent` so it is stable
    /// across warm switches. Injected into the engine configuration here.
    let bus: MarkdownEditorBus
    /// Body font family + base size (Settings-driven; the engine scales
    /// headings/code off the base and rebuilds live on change).
    var fontName: String = SettingsManager.defaultMarkdownFontFamily
    var fontSize: CGFloat = 16
    var isEditable: Bool = true
    /// Whether this editor is on screen (S8 P2 / doc 18 §4.7): a warm editor that
    /// is not displayed is hidden at the AppKit level with its viewport work
    /// paused — the markdown peer of PDFViewWrapper's warm gate.
    var isDisplayed: Bool = true
    /// Whether this editor should own the keyboard (the active tab); the engine
    /// takes first responder one turn later, PDF-style.
    var isFocused: Bool = false
    /// A click inside the editor asks the host to make its tab active.
    var onRequestFocus: (() -> Void)? = nil
    /// Where the reader should land, applied once per request token after the
    /// first styled layout (load, eviction remount, tear-off).
    var readingPositionRequest: ReadingPositionRequest? = nil
    /// Resolves `![alt](path)` relative to the note's folder; owned by the tab's
    /// content so decoded images outlive restyles.
    var imageProvider: (any EmbeddedImageProvider)? = nil
    /// Turns image files dropped or pasted into the editor into image links.
    var onPasteImage: ((NSPasteboard) -> String?)? = nil
    /// Opens dropped PDF/Markdown files as tabs instead of inserting their paths.
    var onDropDocuments: (([URL]) -> Bool)? = nil
    /// Follows a local link (relative path, `file:`, `#heading`) clicked in the note.
    var onOpenLocalLink: ((URL) -> Void)? = nil
    /// The window's warm (mounted) tab `documentId`s (S8 P2). The engine keeps each
    /// retained tab's scroll offset across a switch and forgets the rest; `nil`
    /// keeps all. Passed through verbatim to the engine wrapper.
    var retainedScrollDocumentIds: Set<String>? = nil
    /// Top clearance (points) reserved on the scroll view so the first line clears the
    /// floating tab-bar/toolbar chrome the editor scrolls UNDER. Maps to the engine's
    /// `safeAreaInsets.top` → `NSScrollView.contentInsets.top`. Threaded from
    /// `MarkdownTabView` off the live `toolbarScale`.
    var topInset: CGFloat = 0
    /// User-defined left/right margin (points) around the editor text — the
    /// text container's horizontal inset, reconciled LIVE by the engine wrapper
    /// (no remount; dragging the Settings slider re-lays mounted editors).
    var sideMargin: CGFloat = DesignTokens.markdownReadingGutter
    /// Whether the document centers in the window when zoomed OUT (PDF parity);
    /// off = pinned left (Settings toggle, default off). Live-reconciled.
    var centersZoomedOut: Bool = false
    /// Page look: fixed measure (42 em of the body font) centered in the
    /// window, on the same background as the rest of the editor.
    var pageLook: Bool = true
    /// Forces the editor's `NSScrollView.appearance` independent of the system (fork
    /// knob, Feature 2b). `nil` follows the system. The SwiftUI side of the scheme
    /// is applied by `MarkdownTabView` (`.environment(\.colorScheme)` + background);
    /// this is the AppKit leg for the engine subtree.
    var forcedAppearanceName: NSAppearance.Name? = nil
    /// This tab's per-document undo stack (`MarkdownContent.undoManager` — the one
    /// the Edit menu drives via `TabManager.activeUndoManager`). Routed into the
    /// engine so the text view registers its edits THERE, not on the window (fork
    /// knob); history then survives warm tab switches per document.
    var undoManager: UndoManager? = nil
    /// Per-document visual magnification (1.0 = 100%), projected onto the engine's
    /// scroll view — PDF-style pinch/⌘±/Ctrl-scroll zoom, not a font-size change.
    var zoomScale: CGFloat = 1.0
    /// A user gesture changed the magnification (pinch end / Ctrl-scroll); the
    /// host adopts + persists it.
    var onZoomChanged: ((CGFloat) -> Void)? = nil

    var body: some View { nativeEditor }

    /// The same configured editor used by SwiftUI and retained AppKit hosts.
    var nativeEditor: NativeTextViewWrapper {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontName: fontName,
            fontSize: fontSize,
            documentId: documentId,
            isEditable: isEditable,
            onPasteImage: onPasteImage,
            onDropDocuments: onDropDocuments,
            onOpenLocalLink: onOpenLocalLink,
            retainedScrollDocumentIds: retainedScrollDocumentIds,
            editorController: editorController,
            forcedAppearanceName: forcedAppearanceName,
            // The PDF tabs' scroller treatment (GlassScroller + hover reveal),
            // installed through the engine's make-time chrome hook.
            scrollViewConfigurator: { GlassScrollerHover.install(on: $0) },
            undoManager: undoManager,
            readingPositionRequest: readingPositionRequest,
            isDisplayed: isDisplayed,
            isFocused: isFocused,
            onRequestFocus: onRequestFocus,
            // PDF-style visual zoom: the scroll view magnifies the whole document
            // (pinch / ⌘± / Ctrl-scroll) rather than changing the font size. The
            // host owns + persists the level per document.
            magnificationRange: DesignTokens.markdownMinZoom...DesignTokens.markdownMaxZoom,
            magnification: zoomScale,
            onMagnificationChanged: onZoomChanged
        )
    }

    /// The canonical engine configuration with THIS tab's scoped bus injected. The
    /// shared base (`baseConfiguration`) is computed once; only the per-tab bus
    /// differs, so warm tabs never share a find/format channel (fork P2).
    private var configuration: MarkdownEditorConfiguration {
        var configuration = Self.baseConfiguration
        configuration.services.bus = bus
        if let imageProvider { configuration.services.images = imageProvider }
        // User-defined side margins (live) + top clearance so the first line
        // scrolls out from under the floating chrome.
        configuration.textInsets = TextInsets(horizontal: sideMargin, vertical: 0)
        configuration.safeAreaInsets = SafeAreaInsets(top: topInset, leading: 0, trailing: 0, bottom: 0)
        // Zoomed-out column placement (Settings toggle, live).
        configuration.centersZoomedOutColumn = centersZoomedOut
        // The editor's own chords, as Settings > Shortcuts binds them (live).
        configuration.keyBindings = ShortcutCatalog.editorKeyBindings()
        if pageLook {
            configuration.readingWidth = DesignTokens.markdownPageMeasureEm * fontSize
        }
        #if canImport(MarkdownEngineLatex)
        // Math ink must key off the editor's forced scheme, not the key window —
        // a restyle triggered while Settings is key would otherwise bake formulas
        // against the Settings window's appearance (fork knob on SwiftMathBridge).
        (configuration.services.latex as? SwiftMathBridge)?.appearanceOverride =
            forcedAppearanceName.flatMap { NSAppearance(named: $0) }
        #endif
        #if canImport(MarkdownEngineMermaid)
        // Diagram ink follows the editor's forced scheme, not the key window's —
        // same reason as the math bridge above.
        (configuration.services.diagram as? MermaidBridge)?.appearanceOverride =
            forcedAppearanceName.flatMap { NSAppearance(named: $0) }
        #endif
        return configuration
    }

    /// Runs `build` with math and diagrams rendering for paper: dark ink,
    /// whatever color scheme the editor is pinned to.
    @MainActor
    static func renderingForPrint<Result>(_ build: () -> Result) -> Result {
        let paper = NSAppearance(named: .aqua)
        #if canImport(MarkdownEngineLatex)
        let latex = baseConfiguration.services.latex as? SwiftMathBridge
        let latexPin = latex?.appearanceOverride
        latex?.appearanceOverride = paper
        defer { latex?.appearanceOverride = latexPin }
        #endif
        #if canImport(MarkdownEngineMermaid)
        let diagram = baseConfiguration.services.diagram as? MermaidBridge
        let diagramPin = diagram?.appearanceOverride
        diagram?.appearanceOverride = paper
        defer { diagram?.appearanceOverride = diagramPin }
        #endif
        return build()
    }

    /// PageFlow's canonical engine configuration: Live Preview defaults, math
    /// rendered via SwiftMath (no WebView), and **literal-markdown** input
    /// substitution (fork P5) so smart quotes / dashes / text-replacement never
    /// silently rewrite typed source — a prerequisite for the byte-faithful
    /// round-trip the save layer guarantees (ADR-0008). The per-tab bus is layered
    /// on per instance (see `configuration`).
    static let baseConfiguration: MarkdownEditorConfiguration = {
        var configuration = MarkdownEditorConfiguration.default
        configuration.inputSubstitution = .literalMarkdown
        // the reference editor's floating selection bar and selection colors (ADR-0027).
        configuration.showsSelectionBar = true
        // Typed source stays exactly what was typed: no paired brackets (D10).
        configuration.lists.autoClosePairsEnabled = false
        // Side margins (textInsets) are per-instance — the user setting drives
        // them in `configuration` above; the base carries everything tab-invariant.
        #if canImport(MarkdownEngineLatex)
        configuration.services.latex = SwiftMathBridge()
        #endif
        #if canImport(MarkdownEngineMermaid)
        // Native Mermaid rendering (no WebView). A ```` ```mermaid ```` block
        // collapses to its diagram; caret-in reveals source; unsupported/broken
        // diagrams fall back to a styled code block. Shared instance → one
        // render cache across warm tabs.
        configuration.services.diagram = MermaidBridge()
        #endif
        #if canImport(MarkdownEngineCodeBlocks)
        // Fenced code gets real syntax colors (HighlighterSwift, light/dark
        // themes follow the system appearance). Shared instance → one
        // highlight cache across warm tabs. Without it every code block was
        // plain monospace on a transparent background.
        configuration.services.syntaxHighlighter = HighlighterSwiftBridge()
        #endif
        return configuration
    }()
}

#if DEBUG
/// An Xcode preview of the editor surface with a local binding, outside any tab.
private struct MarkdownEditorViewPreviewHost: View {
    @State private var text = "# Hello\n\nType **literal** markdown — \"quotes\" stay straight."
    @State private var controller = MarkdownEditorController()

    var body: some View {
        MarkdownEditorView(
            text: $text,
            documentId: "preview",
            editorController: controller,
            bus: MarkdownEditorBus(scopeByObject: true)
        )
        .frame(minWidth: 480, minHeight: 360)
    }
}

#Preview("MarkdownEditorView") {
    MarkdownEditorViewPreviewHost()
}
#endif
#endif
