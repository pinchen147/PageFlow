//
//  MarkdownEditorServices.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Protocols and default implementations for engine-side dependencies.
//
//  The Markdown editor engine resolves wiki-links, syntax highlighting,
//  LaTeX rendering, and embedded image lookup through these protocols.
//  Embedders supply the concrete implementations; the engine never
//  reaches into the host app for any of these concerns.
//

import AppKit
import Foundation

// MARK: - Wiki Links

/// Resolves a wiki-link's display name to a stable storage identifier.
///
/// The engine stores wiki-links as `[[Name|<id>]]` and displays them as
/// `[[Name]]`. The resolver maps a display name (and the range it occupies
/// in the document) to whatever stable identifier the embedder uses for
/// linked content. The identifier is opaque to the engine.
public protocol WikiLinkResolver: Sendable {
    /// Resolve a wiki-link by its visible name.
    ///
    /// - Parameters:
    ///   - displayName: The text inside `[[ ]]` as the user sees it.
    ///   - range: The character range the link occupies in the document.
    /// - Returns: A resolution if the link points at known content; `nil` otherwise.
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution?

    /// Coarse fingerprint of the resolver's known targets (typically IDs + names).
    /// A different value triggers a wiki-link restyle, so a rename refreshes link
    /// clickability/display without waiting for the next keystroke.
    func fingerprint() -> AnyHashable
}

public extension WikiLinkResolver {
    func fingerprint() -> AnyHashable { 0 }
}

/// The result of resolving a wiki-link.
public struct WikiLinkResolution: Sendable, Equatable {
    /// Stable identifier persisted in the storage form `[[Name|<id>]]`.
    public let id: String
    /// Whether the linked target currently exists/is reachable.
    public let exists: Bool

    public init(id: String, exists: Bool) {
        self.id = id
        self.exists = exists
    }
}

/// Default resolver that never resolves anything. Useful when an embedder
/// doesn't ship wiki-link support.
public struct NoOpWikiLinkResolver: WikiLinkResolver {
    public init() {}
    public func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
}

// MARK: - Embedded Images

/// Loads an `NSImage` for an `![[...]]` embed reference.
///
/// The engine parses `![[name|optional-id|optional-width]]` into a
/// reference and asks the provider for an image. The provider decides
/// where the image actually lives (filesystem, remote, asset catalog).
public protocol EmbeddedImageProvider: Sendable {
    /// Returns an image for the given reference, or `nil` if no image
    /// is available.
    func image(for reference: EmbeddedImageRequest) -> NSImage?

    /// A coarse fingerprint of the provider's current state. Returning
    /// a different value invalidates the engine's image cache. Embedders
    /// typically combine the IDs of all known images.
    func fingerprint() -> AnyHashable
}

/// What the engine asks an `EmbeddedImageProvider` for.
public struct EmbeddedImageRequest: Sendable, Equatable {
    /// Display name of the embed (the part before any `|`).
    public let name: String
    /// Optional explicit identifier supplied as `![[name|id]]`.
    public let id: String?
    /// Optional explicit width supplied as `![[name|...|width]]`.
    public let requestedWidth: CGFloat?

    public init(name: String, id: String? = nil, requestedWidth: CGFloat? = nil) {
        self.name = name
        self.id = id
        self.requestedWidth = requestedWidth
    }
}

/// Default provider that never returns images.
public struct NoOpEmbeddedImageProvider: EmbeddedImageProvider {
    public init() {}
    public func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    public func fingerprint() -> AnyHashable { 0 }
}

// MARK: - Syntax Highlighting

/// Provides code-block font, background color, and syntax highlighting.
public protocol SyntaxHighlighter: Sendable {
    /// Monospace font used for fenced code blocks at the requested size.
    func codeFont(size: CGFloat) -> NSFont

    /// Background color used to fill code-block paragraphs. The engine
    /// also uses this color to detect which fragments are code blocks
    /// when drawing custom backgrounds.
    func backgroundColor() -> NSColor

    /// Highlight `code` written in `language`. Return an attributed string
    /// whose attributes carry per-token foreground colors. Return `nil` if
    /// no highlighting is available for this language.
    func highlight(code: String, language: String?) -> NSAttributedString?

    /// Notification name posted when the highlighter's appearance source
    /// changes (light/dark mode flip, theme switch). The engine subscribes
    /// to this notification so it can invalidate cached attributes.
    /// Return `nil` if the highlighter never changes after construction.
    var appearanceDidChangeNotification: Notification.Name? { get }
}

/// Default highlighter that produces no highlighting and supplies a
/// basic system monospace font on a transparent background.
public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func codeFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor {
        NSColor.textBackgroundColor.withAlphaComponent(0)
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        nil
    }

    public var appearanceDidChangeNotification: Notification.Name? { nil }
}

// MARK: - LaTeX

/// Renders LaTeX formulas to images for inline display.
public protocol LatexRenderer: Sendable {
    /// Render `latex` at the requested font size, optionally tinted by `theme`.
    /// - Returns: A rendered result, or `nil` if the renderer cannot produce
    ///   an image (unsupported syntax, missing dependency, …).
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult?
}

/// Output of a LaTeX render call.
public struct LatexRenderResult: Sendable {
    public let image: NSImage
    public let size: CGSize
    /// Distance from the image's bottom edge to its visual baseline.
    /// Used to align inline math with the surrounding text.
    public let baselineOffset: CGFloat

    public init(image: NSImage, size: CGSize, baselineOffset: CGFloat) {
        self.image = image
        self.size = size
        self.baselineOffset = baselineOffset
    }
}

/// Default renderer that ignores LaTeX entirely. The engine falls back to
/// rendering the source text when this is in use.
public struct NoOpLatexRenderer: LatexRenderer {
    public init() {}
    public func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
}

// MARK: - Block Diagrams (Mermaid, …)

/// Renders a fenced block whose info-string names a diagram language (e.g.
/// ```` ```mermaid ````) to a standalone block image — the diagram peer of
/// ``LatexRenderer``. Synchronous and cached, exactly like the LaTeX path: the
/// styler calls this on each restyle of an INACTIVE diagram block and blits the
/// result; a `nil` return means "cannot render this" (unsupported language,
/// unparseable/broken source, or any failure) and the block falls back to
/// ordinary code styling — the "never lie, show the source" contract. Kept
/// behind a protocol so the concrete renderer and its heavy layout dependency
/// link only into the opt-in `MarkdownEngineMermaid` product, never the core.
public protocol BlockDiagramRenderer: Sendable {
    /// Render `source` (the fenced block's content) for `language` (the
    /// lowercased info-string, e.g. `"mermaid"`), laid out to fit within
    /// `maxWidth` points, at `fontSize`, tinted for `theme`. Return `nil` on any
    /// unsupported/failed case so the caller reveals raw source instead.
    func render(source: String, language: String, maxWidth: CGFloat,
                fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult?

    /// As above, with the display pixel density the raster should target —
    /// `backingScaleFactor × magnification` under visual zoom-in (ADR-0019), so
    /// a diagram rendered at a zoomed-in settle stays crisp. Renderers that
    /// rasterize at a fixed density may ignore it; the default forwards to the
    /// plain overload.
    func render(source: String, language: String, maxWidth: CGFloat,
                fontSize: CGFloat, theme: MarkdownEditorTheme,
                pixelScale: CGFloat) -> DiagramRenderResult?
}

public extension BlockDiagramRenderer {
    func render(source: String, language: String, maxWidth: CGFloat,
                fontSize: CGFloat, theme: MarkdownEditorTheme,
                pixelScale: CGFloat) -> DiagramRenderResult? {
        render(source: source, language: language, maxWidth: maxWidth,
               fontSize: fontSize, theme: theme)
    }
}

/// Output of a diagram render. Unlike ``LatexRenderResult`` there is no baseline
/// offset — a diagram is always a centered block, never inline with text.
public struct DiagramRenderResult: Sendable {
    public let image: NSImage
    /// The image's point size (already fitted to the caller's `maxWidth`).
    public let size: CGSize

    public init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Default renderer that renders no diagrams: a ```` ```mermaid ```` block stays
/// an ordinary (highlightable) code block. Replaced when a host links the
/// `MarkdownEngineMermaid` opt-in product and injects a real renderer.
public struct NoOpBlockDiagramRenderer: BlockDiagramRenderer {
    public init() {}
    public func render(source: String, language: String, maxWidth: CGFloat,
                       fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? { nil }
}

// MARK: - Event Bus

/// Optional notification-name bridge that lets the editor communicate with
/// surrounding UI without hard-coding any names of its own.
///
/// The engine observes the request notifications it is configured with and
/// posts the response notifications when supplied. Embedders that don't
/// need cross-view formatting commands simply leave every name `nil`.
public struct MarkdownEditorBus: Sendable {
    /// Posted by the host UI to request the engine apply bold styling.
    public var applyBoldRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply italic styling.
    public var applyItalicRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply underline styling.
    public var applyUnderlineRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply a heading level.
    /// Expected `userInfo["level"] as? Int`.
    public var applyHeadingRequest: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isBold"] as? Bool`.
    public var selectionBoldDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isItalic"] as? Bool`.
    public var selectionItalicDidChange: Notification.Name?
    /// Posted by the host UI to scroll an in-document find match into view
    /// and highlight all matches. Expected `userInfo["range"] as? NSRange`,
    /// `userInfo["currentIndex"] as? Int`, `userInfo["allRanges"] as? [NSRange]`.
    public var findScrollToRange: Notification.Name?
    /// Posted by the host UI to clear all in-document find highlights.
    public var findClearHighlights: Notification.Name?
    /// When true, the engine scopes this bus to a single editor instance:
    /// it ignores INCOMING request notifications (bold/italic/heading/find)
    /// whose `object` is not the coordinator's `documentId`, and stamps
    /// OUTGOING selection-status posts with `object = documentId`. Hosts
    /// running multiple warm editors should give each tab a distinct bus with
    /// unique `Notification.Name`s AND set this `true`, posting the tab's
    /// `documentId` as the notification `object`. Default `false` preserves the
    /// legacy `object: nil` broadcast behavior for single-editor embedders.
    public var scopeByObject: Bool

    public init(
        applyBoldRequest: Notification.Name? = nil,
        applyItalicRequest: Notification.Name? = nil,
        applyUnderlineRequest: Notification.Name? = nil,
        applyHeadingRequest: Notification.Name? = nil,
        selectionBoldDidChange: Notification.Name? = nil,
        selectionItalicDidChange: Notification.Name? = nil,
        findScrollToRange: Notification.Name? = nil,
        findClearHighlights: Notification.Name? = nil,
        scopeByObject: Bool = false
    ) {
        self.applyBoldRequest = applyBoldRequest
        self.applyItalicRequest = applyItalicRequest
        self.applyUnderlineRequest = applyUnderlineRequest
        self.applyHeadingRequest = applyHeadingRequest
        self.selectionBoldDidChange = selectionBoldDidChange
        self.selectionItalicDidChange = selectionItalicDidChange
        self.findScrollToRange = findScrollToRange
        self.findClearHighlights = findClearHighlights
        self.scopeByObject = scopeByObject
    }

    // MARK: - Scope convention (encode ⟺ decode)
    //
    // The rule "when `scopeByObject`, post `documentId` as the notification
    // `object`; on receipt accept iff it matches (nil object ⇒ broadcast)" has
    // two sides that must stay in lock-step. They live here as a symmetric pair
    // so the POST side and the ACCEPT side can't drift apart.

    /// The `object` to stamp on an OUTGOING scoped post: the document's id when
    /// `scopeByObject`, else `nil` (legacy broadcast). Symmetric partner of
    /// ``accepts(_:forDocument:)``.
    public func scopeObject(for documentId: String?) -> Any? {
        scopeByObject ? documentId : nil
    }

    /// Whether an INCOMING request notification is meant for `documentId`.
    /// Scoping off ⇒ every notification is accepted (legacy broadcast). Scoping
    /// on: a `nil` `documentId` (pre-attach / single editor) accepts, a `nil`
    /// notification `object` is a broadcast-accept, and any other object is
    /// accepted iff it string-matches `documentId`. Symmetric partner of
    /// ``scopeObject(for:)``.
    public func accepts(_ notification: Notification, forDocument documentId: String?) -> Bool {
        guard scopeByObject else { return true }
        guard let documentId else { return true }
        guard let posted = notification.object else { return true }
        return (posted as? String) == documentId
    }

    public static let `default` = MarkdownEditorBus()
}

// MARK: - Services Container

/// Bundles every external service the engine needs.
///
/// Held by ``MarkdownEditorConfiguration/services``. The engine reads its
/// dependencies exclusively from this container; embedders inject the
/// implementations they want.
public struct MarkdownEditorServices: Sendable {
    public var wikiLinks: any WikiLinkResolver
    public var images: any EmbeddedImageProvider
    public var syntaxHighlighter: any SyntaxHighlighter
    public var latex: any LatexRenderer
    public var diagram: any BlockDiagramRenderer
    public var bus: MarkdownEditorBus

    public init(
        wikiLinks: any WikiLinkResolver = NoOpWikiLinkResolver(),
        images: any EmbeddedImageProvider = NoOpEmbeddedImageProvider(),
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter(),
        latex: any LatexRenderer = NoOpLatexRenderer(),
        diagram: any BlockDiagramRenderer = NoOpBlockDiagramRenderer(),
        bus: MarkdownEditorBus = .default
    ) {
        self.wikiLinks = wikiLinks
        self.images = images
        self.syntaxHighlighter = syntaxHighlighter
        self.latex = latex
        self.diagram = diagram
        self.bus = bus
    }

    public static let `default` = MarkdownEditorServices()
}
