//
//  MarkdownEditorConfiguration.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Centralized configuration for the Markdown editor engine.
//
//  This struct exposes every spacing, sizing, and behavior knob that is
//  shared across the engine. The defaults reproduce the historical
//  Nodes-app behavior, so passing `.default` keeps existing rendering
//  pixel-identical. Embedders that want a different look-and-feel can
//  override individual fields without forking the engine.
//

import AppKit
import Foundation

// MARK: - Top-level Configuration

/// All tunable values for the Markdown editor engine grouped by concern.
///
/// The struct is deliberately flat-with-nested-groups: top level holds
/// orthogonal feature areas (markers, code blocks, lists, …), each group
/// owns the values that belong together. Default values are the production
/// defaults used by the Nodes app and have been chosen empirically.
public struct MarkdownEditorConfiguration: Sendable {

    public var theme: MarkdownEditorTheme
    public var services: MarkdownEditorServices
    public var markers: MarkerStyle
    public var codeBlock: CodeBlockStyle
    public var inlineCode: InlineCodeStyle
    public var lists: ListStyle
    public var headings: HeadingStyle
    public var imageEmbed: ImageEmbedStyle
    public var blockLatex: BlockLatexStyle
    public var inlineLatex: InlineLatexStyle
    public var checkbox: CheckboxStyle
    public var link: LinkStyle
    public var paragraph: ParagraphStyle
    public var overscroll: OverscrollPolicy
    public var dragSelection: DragSelectionPolicy
    public var safeAreaInsets: SafeAreaInsets
    public var scrollers: ScrollersPolicy
    public var textInsets: TextInsets
    /// Centered reading-column width; wide tables break out to full width. nil = full width (default).
    public var readingWidth: CGFloat?
    /// Full-width mode under visual zoom-out (magnification < 1): the document
    /// container grows to the effective viewport width, and this knob decides
    /// where the prose column sits inside it — `true` centers it (PDF parity),
    /// `false` (default) keeps it pinned left. Width-fitted blocks (tables,
    /// diagrams, images) use the grown container either way. Live-reconciled.
    public var centersZoomedOutColumn: Bool
    public var spellChecking: SpellCheckingPolicy
    /// AppKit input-substitution knobs (smart quotes / dashes / text replacement /
    /// data detection). Default reproduces the engine's historical behavior; set
    /// ``InputSubstitutionPolicy/literalMarkdown`` to keep typed Markdown byte-faithful.
    public var inputSubstitution: InputSubstitutionPolicy
    /// the reference editor's floating selection bar over a non-empty selection, with its
    /// selection colors (doc 24 §6). Off by default; live-reconciled.
    public var showsSelectionBar = false
    /// Room for a 26-point drag grip and its gap, including the heading fold control.
    /// Keep the host's preferred margin intact while controls occupy their own gutter.
    var horizontalLayoutInset: CGFloat {
        guard showsSelectionBar else { return textInsets.horizontal }
        // A fixed column can overflow a narrow window, hiding its right gutter.
        // Leave space for both the heading grip and fold button on the left.
        // A heading's right-hand grip also needs an 18-point scrollbar strip.
        let fullWidthMinimum: CGFloat = scrollers.hasVerticalScroller ? 48 : 30
        return max(readingWidth == nil ? fullWidthMinimum : 62, textInsets.horizontal)
    }
    /// Show a centered hidden-block count below collapsed headings; live-reconciled.
    public var showsHiddenContentRow = true
    /// The editor's keyboard commands and their chords; live-reconciled.
    public var keyBindings: MarkdownKeyBindings = .default

    /// Fenced-code info-strings that name a renderable diagram language (default
    /// `["mermaid"]`). A code block whose language is in this set is handed to
    /// ``MarkdownEditorServices/diagram`` and, when it renders, collapses to the
    /// diagram image (revealing raw source on caret-enter); everything else stays
    /// an ordinary code block. Empty ⇒ diagram rendering off. Language matching is
    /// case-insensitive: the set is normalized to lowercase on assignment, so a
    /// host may configure any casing (`["Mermaid"]`) and a `` ```MERMAID `` fence
    /// still resolves.
    public var diagramLanguages: Set<String> {
        didSet {
            let lowered = Set(diagramLanguages.map { $0.lowercased() })
            if lowered != diagramLanguages { diagramLanguages = lowered }
        }
    }

    public init(
        theme: MarkdownEditorTheme = .default,
        services: MarkdownEditorServices = .default,
        markers: MarkerStyle = .default,
        codeBlock: CodeBlockStyle = .default,
        inlineCode: InlineCodeStyle = .default,
        lists: ListStyle = .default,
        headings: HeadingStyle = .default,
        imageEmbed: ImageEmbedStyle = .default,
        blockLatex: BlockLatexStyle = .default,
        inlineLatex: InlineLatexStyle = .default,
        checkbox: CheckboxStyle = .default,
        link: LinkStyle = .default,
        paragraph: ParagraphStyle = .default,
        overscroll: OverscrollPolicy = .default,
        dragSelection: DragSelectionPolicy = .default,
        safeAreaInsets: SafeAreaInsets = .default,
        scrollers: ScrollersPolicy = .default,
        textInsets: TextInsets = .default,
        readingWidth: CGFloat? = nil,
        centersZoomedOutColumn: Bool = false,
        spellChecking: SpellCheckingPolicy = .default,
        inputSubstitution: InputSubstitutionPolicy = .default,
        diagramLanguages: Set<String> = ["mermaid"]
    ) {
        self.theme = theme
        self.services = services
        self.markers = markers
        self.codeBlock = codeBlock
        self.inlineCode = inlineCode
        self.lists = lists
        self.headings = headings
        self.imageEmbed = imageEmbed
        self.blockLatex = blockLatex
        self.inlineLatex = inlineLatex
        self.checkbox = checkbox
        self.link = link
        self.paragraph = paragraph
        self.overscroll = overscroll
        self.dragSelection = dragSelection
        self.safeAreaInsets = safeAreaInsets
        self.scrollers = scrollers
        self.textInsets = textInsets
        self.readingWidth = readingWidth
        self.centersZoomedOutColumn = centersZoomedOutColumn
        self.spellChecking = spellChecking
        self.inputSubstitution = inputSubstitution
        // didSet does not fire during init — normalize the initial set here so the
        // stored value is lowercase from the start (see the property's didSet).
        self.diagramLanguages = Set(diagramLanguages.map { $0.lowercased() })
    }

    public static let `default` = MarkdownEditorConfiguration()
}

// MARK: - Spell checking

/// Initial state for the three "Spelling and Grammar" toggles. Only consulted
/// at `makeNSView` time; afterwards the user's context-menu choices take
/// precedence and are surfaced via ``NativeTextViewWrapper/onSpellCheckingPolicyChanged``.
public struct SpellCheckingPolicy: Sendable, Equatable {
    /// Mirrors `NSTextView.isContinuousSpellCheckingEnabled`.
    public var continuousSpellChecking: Bool
    /// Mirrors `NSTextView.isGrammarCheckingEnabled`.
    public var grammarChecking: Bool
    /// Mirrors `NSTextView.isAutomaticSpellingCorrectionEnabled`.
    public var automaticSpellingCorrection: Bool

    public init(
        continuousSpellChecking: Bool = true,
        grammarChecking: Bool = true,
        automaticSpellingCorrection: Bool = true
    ) {
        self.continuousSpellChecking = continuousSpellChecking
        self.grammarChecking = grammarChecking
        self.automaticSpellingCorrection = automaticSpellingCorrection
    }

    public static let `default` = SpellCheckingPolicy()
}

// MARK: - Input substitution

/// AppKit auto-substitution toggles applied to the editing `NSTextView`.
///
/// These mirror `NSTextView` flags 1:1. Unlike ``SpellCheckingPolicy`` (whose
/// values are an *initial* state the user can override via the context menu),
/// this policy is enforced on every `updateAutocorrectSettings` pass, so the
/// engine never silently re-enables quote substitution when the caret leaves a
/// code/LaTeX/link span. For literal-Markdown safety set ``literalMarkdown``.
public struct InputSubstitutionPolicy: Sendable, Equatable {
    /// Mirrors `NSTextView.isAutomaticQuoteSubstitutionEnabled` (smart quotes).
    public var automaticQuoteSubstitution: Bool
    /// Mirrors `NSTextView.isAutomaticDashSubstitutionEnabled` (-- -> em dash).
    public var automaticDashSubstitution: Bool
    /// Mirrors `NSTextView.isAutomaticTextReplacementEnabled` (text expansion).
    public var automaticTextReplacement: Bool
    /// Mirrors `NSTextView.isAutomaticDataDetectionEnabled` (links/dates/etc.).
    public var automaticDataDetection: Bool

    public init(
        automaticQuoteSubstitution: Bool = true,
        automaticDashSubstitution: Bool = false,
        automaticTextReplacement: Bool = false,
        automaticDataDetection: Bool = true
    ) {
        self.automaticQuoteSubstitution = automaticQuoteSubstitution
        self.automaticDashSubstitution = automaticDashSubstitution
        self.automaticTextReplacement = automaticTextReplacement
        self.automaticDataDetection = automaticDataDetection
    }

    /// Near-reproduces the engine's historical behavior (quotes + data detection
    /// on, dash off). One intentional divergence: text-replacement is now
    /// explicitly off, whereas pre-patch it inherited the NSTextView/system default.
    public static let `default` = InputSubstitutionPolicy()
    /// Whether the engine's own punctuation rewrite (`->` → `→`) runs: it
    /// follows the smart-punctuation switches, so literal Markdown keeps `->`.
    public var rewritesTypedPunctuation: Bool {
        automaticQuoteSubstitution || automaticDashSubstitution
    }

    /// Everything off — typed Markdown round-trips byte-faithfully.
    public static let literalMarkdown = InputSubstitutionPolicy(
        automaticQuoteSubstitution: false,
        automaticDashSubstitution: false,
        automaticTextReplacement: false,
        automaticDataDetection: false
    )
}

// MARK: - Scroll bars

/// Scroll bar visibility. Default: vertical only, autohide on.
public struct ScrollersPolicy: Sendable, Equatable {
    public var hasVerticalScroller: Bool
    public var hasHorizontalScroller: Bool
    public var autohidesScrollers: Bool

    public init(
        hasVerticalScroller: Bool = true,
        hasHorizontalScroller: Bool = false,
        autohidesScrollers: Bool = true
    ) {
        self.hasVerticalScroller = hasVerticalScroller
        self.hasHorizontalScroller = hasHorizontalScroller
        self.autohidesScrollers = autohidesScrollers
    }

    public static let `default` = ScrollersPolicy()
    /// No scrollers (use with a custom scroll overlay).
    public static let hidden = ScrollersPolicy(hasVerticalScroller: false, hasHorizontalScroller: false)
    /// Vertical only — same as `.default`.
    public static let vertical = ScrollersPolicy(hasVerticalScroller: true, hasHorizontalScroller: false)
    /// Both axes (code-heavy / wide content).
    public static let both = ScrollersPolicy(hasVerticalScroller: true, hasHorizontalScroller: true)
    /// Vertical, no auto-hide.
    public static let alwaysVisible = ScrollersPolicy(hasVerticalScroller: true, autohidesScrollers: false)
}

// MARK: - Text insets

/// Margins inside the text view (`NSTextView.textContainerInset`). Scroll bar stays at the outer edge.
public struct TextInsets: Sendable, Equatable {
    public var horizontal: CGFloat
    public var vertical: CGFloat

    public init(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let `default` = TextInsets()
}

// MARK: - Marker visibility

/// How Markdown syntax markers (e.g. `**`, `*`, `$`) are visualized when
/// the cursor is not inside the corresponding token.
///
/// The engine's default approach is to keep markers in the text storage but
/// shrink them to a near-zero font size (`hiddenMarkerFontSize`). This avoids
/// any range translation between displayed and stored text — cursor movement,
/// find/replace, selection, and copy/paste all stay trivially correct.
/// The trade-off is a sub-pixel residue at extreme zoom levels.
public struct MarkerStyle: Sendable, Equatable {
    /// Font size used for "hidden" inline markers. Effectively invisible at
    /// normal zoom while keeping displayed-range == stored-range.
    public var hiddenMarkerFontSize: CGFloat
    /// Alpha applied to inline-code's secondary marker color.
    public var inlineCodeMarkerAlpha: CGFloat
    /// Alpha applied to non-focused find matches when in-document search
    /// highlights are visible. The focused match is drawn at full opacity.
    public var findMatchHighlightAlpha: CGFloat

    public init(
        hiddenMarkerFontSize: CGFloat = 0.1,
        inlineCodeMarkerAlpha: CGFloat = 0.5,
        findMatchHighlightAlpha: CGFloat = 0.65
    ) {
        self.hiddenMarkerFontSize = hiddenMarkerFontSize
        self.inlineCodeMarkerAlpha = inlineCodeMarkerAlpha
        self.findMatchHighlightAlpha = findMatchHighlightAlpha
    }

    public static let `default` = MarkerStyle()
}

// MARK: - Code blocks

/// Styling for fenced code blocks (```language ... ```).
public struct CodeBlockStyle: Sendable, Equatable {
    /// Code-block font size as a fraction of the document base font size.
    public var fontSizeScale: CGFloat
    /// Vertical paragraph spacing applied above and below the code block.
    public var paragraphSpacing: CGFloat
    /// Left/right indent (in points) so code blocks don't run into the gutter.
    public var horizontalIndent: CGFloat
    /// Height (in points) of each fence row while the caret is outside the
    /// block: the hidden ```` ``` ```` lines shrink to the block's inner padding
    /// instead of leaving an empty code line above and below the code.
    public var hiddenFenceHeight: CGFloat

    public init(
        fontSizeScale: CGFloat = 0.85,
        paragraphSpacing: CGFloat = 2.0,
        horizontalIndent: CGFloat = 12.0,
        hiddenFenceHeight: CGFloat = 6.0
    ) {
        self.fontSizeScale = fontSizeScale
        self.paragraphSpacing = paragraphSpacing
        self.horizontalIndent = horizontalIndent
        self.hiddenFenceHeight = hiddenFenceHeight
    }

    public static let `default` = CodeBlockStyle()
}

// MARK: - Inline code

/// Styling for inline `` `code` `` spans.
public struct InlineCodeStyle: Sendable, Equatable {
    /// Inline-code reuses the code block font size scale by default.
    public var fontSizeScale: CGFloat

    public init(fontSizeScale: CGFloat = 0.85) {
        self.fontSizeScale = fontSizeScale
    }

    public static let `default` = InlineCodeStyle()
}

// MARK: - Lists

/// Behavior toggles and metrics for ordered / unordered list editing.
public struct ListStyle: Sendable, Equatable {
    /// Master switch for list-related editing helpers (auto-continue,
    /// auto-indent, marker conversion). When `false`, lists are still
    /// rendered, but typing-time conveniences are skipped.
    public var helpersEnabled: Bool
    /// Master switch for auto-closing pairs `()`, `{}`, `[]` while typing.
    public var autoClosePairsEnabled: Bool
    /// Indent (in points) that one nesting level adds to the list item.
    public var indentPerLevel: CGFloat
    /// Maximum nesting level reachable by pressing Tab inside a list.
    public var maximumNestingLevel: Int
    /// Extra line height added on top of the default to give list items room.
    public var extraLineHeight: CGFloat

    public init(
        helpersEnabled: Bool = true,
        autoClosePairsEnabled: Bool = true,
        indentPerLevel: CGFloat = 27.5,
        maximumNestingLevel: Int = 3,
        extraLineHeight: CGFloat = 2
    ) {
        self.helpersEnabled = helpersEnabled
        self.autoClosePairsEnabled = autoClosePairsEnabled
        self.indentPerLevel = indentPerLevel
        self.maximumNestingLevel = maximumNestingLevel
        self.extraLineHeight = extraLineHeight
    }

    public static let `default` = ListStyle()
}

// MARK: - Headings

/// Per-level heading metrics. Defaults follow the historical Nodes ratios,
/// which are loosely based on browser default heading sizes.
public struct HeadingStyle: Sendable, Equatable {
    /// Font-size multiplier per heading level (1...6).
    public var fontMultipliers: [CGFloat]
    /// Top spacing in `em` units per heading level (1...6).
    public var topSpacingEm: [CGFloat]

    public init(
        fontMultipliers: [CGFloat] = [2.0, 1.5, 1.17, 1.0, 0.83, 0.67],
        topSpacingEm: [CGFloat] = [0.35, 0.30, 0.25, 0.20, 0.15, 0.10]
    ) {
        self.fontMultipliers = fontMultipliers
        self.topSpacingEm = topSpacingEm
    }

    public func fontMultiplier(for level: Int) -> CGFloat {
        let index = max(1, min(level, fontMultipliers.count)) - 1
        return fontMultipliers[index]
    }

    public func topSpacingEm(for level: Int) -> CGFloat {
        let index = max(1, min(level, topSpacingEm.count)) - 1
        return topSpacingEm[index]
    }

    public static let `default` = HeadingStyle()
}

// MARK: - Image embeds (![[...]])

/// Sizing and spacing rules for `![alt](url)` images and `![[Name]]` embeds.
public struct ImageEmbedStyle: Sendable, Equatable {
    /// Minimum allowed display width (points) for an embedded image.
    public var minimumWidth: CGFloat
    /// Smallest explicit width (`|40`) an image is drawn at: the reference
    /// editor's resize minimum.
    public var minimumExplicitWidth: CGFloat
    /// Fallback maximum width if no usable text container width is available.
    public var fallbackMaxWidth: CGFloat
    /// Sanity bound — container widths above this are treated as invalid.
    public var unreasonableMaxWidth: CGFloat
    /// Vertical paragraph spacing above/below the image paragraph.
    public var paragraphSpacing: CGFloat
    /// Gap between the source line and the rendered image (visibleSource mode).
    public var imageGap: CGFloat
    /// Tallest an image without an explicit width is displayed (points) — a
    /// phone screenshot or a long scan is scaled down to this and keeps its
    /// aspect ratio, instead of filling the column width and running for
    /// screens. An explicit width (`![alt|300](url)`, `![[name|300]]`) is the
    /// author's size and ignores it.
    public var maximumHeight: CGFloat
    /// Corner radius (points) images are clipped to.
    public var cornerRadius: CGFloat

    public init(
        minimumWidth: CGFloat = 50,
        minimumExplicitWidth: CGFloat = 40,
        fallbackMaxWidth: CGFloat = 650,
        unreasonableMaxWidth: CGFloat = 1_000_000,
        paragraphSpacing: CGFloat = 8,
        imageGap: CGFloat = 8,
        maximumHeight: CGFloat = 480,
        cornerRadius: CGFloat = 4
    ) {
        self.minimumWidth = minimumWidth
        self.minimumExplicitWidth = minimumExplicitWidth
        self.fallbackMaxWidth = fallbackMaxWidth
        self.unreasonableMaxWidth = unreasonableMaxWidth
        self.paragraphSpacing = paragraphSpacing
        self.imageGap = imageGap
        self.maximumHeight = maximumHeight
        self.cornerRadius = cornerRadius
    }

    /// The display size for an image of `natural` size (already cropped).
    /// With a `requestedWidth`: that width, at least `minimumExplicitWidth`,
    /// never wider than `maxWidth`, the height from the aspect ratio (no
    /// height cap). Without one: never upscaled, no wider than `maxWidth`, no
    /// taller than `maximumHeight`, and at least `minimumWidth` wide when the
    /// caps allow.
    public func displaySize(natural: CGSize, requestedWidth: CGFloat? = nil, maxWidth: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return natural }
        if let requestedWidth {
            let width = min(max(requestedWidth, minimumExplicitWidth), maxWidth)
            return CGSize(width: width, height: width * natural.height / natural.width)
        }
        let width = min(natural.width, maxWidth)
        var scale = width / natural.width
        if natural.height * scale > maximumHeight { scale = maximumHeight / natural.height }
        if natural.width * scale < minimumWidth {
            scale = min(minimumWidth, maxWidth) / natural.width
        }
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    public static let `default` = ImageEmbedStyle()
}

// MARK: - LaTeX

/// Vertical spacing for block-LaTeX `$$...$$` paragraphs.
public struct BlockLatexStyle: Sendable, Equatable {
    /// Top spacing for $$...$$ block paragraphs.
    public var paragraphSpacingBefore: CGFloat
    /// Bottom spacing for $$...$$ block paragraphs.
    public var paragraphSpacing: CGFloat
    /// Extra bottom padding added to single-letter formulas to avoid clipping.
    public var singleLetterPaddingBottom: CGFloat

    public init(
        paragraphSpacingBefore: CGFloat = 16,
        paragraphSpacing: CGFloat = 20,
        singleLetterPaddingBottom: CGFloat = 1.0
    ) {
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.paragraphSpacing = paragraphSpacing
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    public static let `default` = BlockLatexStyle()
}

/// Reserved for future inline-LaTeX (`$...$`) tuning. Currently has no
/// effect; inline LaTeX inherits font size from the surrounding context.
public struct InlineLatexStyle: Sendable {
    /// Reserved for future inline-LaTeX tuning — currently the engine inherits
    /// font size from the surrounding heading context.
    public var placeholder: Void

    public init() { self.placeholder = () }

    public static let `default` = InlineLatexStyle()
}

// MARK: - Task checkboxes

/// Glyph sizing and spacing for `- [ ]` / `- [x]` task checkboxes.
public struct CheckboxStyle: Sendable, Equatable {
    /// Minimum extra spacing (points) inserted after an unchecked checkbox to
    /// optically center the rendered glyph.
    public var minimumExtraSpacing: CGFloat
    /// Additional spacing as a fraction of the surrounding font's point size.
    public var extraSpacingPerFontPointFraction: CGFloat
    /// Checkbox glyph size as a fraction of the line's font height.
    public var sizeFromFontHeightFactor: CGFloat
    /// Checkbox glyph size as a fraction of the `[ ]` marker width.
    public var sizeFromMarkerWidthFactor: CGFloat
    /// Inset applied inside the checkbox bounding box before drawing the icon.
    public var iconInsetFraction: CGFloat

    public init(
        minimumExtraSpacing: CGFloat = 2.0,
        extraSpacingPerFontPointFraction: CGFloat = 0.18,
        sizeFromFontHeightFactor: CGFloat = 1.2,
        sizeFromMarkerWidthFactor: CGFloat = 1.2,
        iconInsetFraction: CGFloat = 0.01
    ) {
        self.minimumExtraSpacing = minimumExtraSpacing
        self.extraSpacingPerFontPointFraction = extraSpacingPerFontPointFraction
        self.sizeFromFontHeightFactor = sizeFromFontHeightFactor
        self.sizeFromMarkerWidthFactor = sizeFromMarkerWidthFactor
        self.iconInsetFraction = iconInsetFraction
    }

    public static let `default` = CheckboxStyle()
}

// MARK: - Links

/// Foreground alpha values applied to link content in different states.
public struct LinkStyle: Sendable, Equatable {
    /// Foreground alpha for the visible label of an active markdown link.
    public var activeLinkAlpha: CGFloat
    /// Foreground alpha applied to "incomplete" link content (e.g. `[text]`
    /// without a target).
    public var incompleteLinkAlpha: CGFloat

    public init(activeLinkAlpha: CGFloat = 0.55, incompleteLinkAlpha: CGFloat = 0.7) {
        self.activeLinkAlpha = activeLinkAlpha
        self.incompleteLinkAlpha = incompleteLinkAlpha
    }

    public static let `default` = LinkStyle()
}

// MARK: - Paragraphs

/// Default paragraph spacing and line height applied to body text.
public struct ParagraphStyle: Sendable, Equatable {
    /// Extra paragraph spacing as a fraction of the document's default line height.
    public var spacingFactor: CGFloat
    /// Extra height (points) added to the default paragraph line height.
    public var lineHeightExtraSpacing: CGFloat

    public init(spacingFactor: CGFloat = 0.3, lineHeightExtraSpacing: CGFloat = 2) {
        self.spacingFactor = spacingFactor
        self.lineHeightExtraSpacing = lineHeightExtraSpacing
    }

    public static let `default` = ParagraphStyle()
}

// MARK: - Bottom overscroll

/// Controls the empty space below the last line so that typing at the bottom
/// of a long document remains comfortable instead of pinning to the viewport
/// bottom edge.
public struct OverscrollPolicy: Sendable, Equatable {
    /// Desired overscroll as a fraction of the visible viewport height.
    public var percent: CGFloat
    /// Hard upper bound for the overscroll in points.
    public var maxPoints: CGFloat
    /// Hard lower bound for the overscroll in points.
    public var minPoints: CGFloat
    /// Fraction of the viewport above which overscroll starts ramping up.
    public var activationStartFraction: CGFloat
    /// Fraction of the viewport over which overscroll fully ramps in.
    public var activationRangeFraction: CGFloat

    public init(
        percent: CGFloat = 0.5,
        maxPoints: CGFloat = 450,
        minPoints: CGFloat = 40,
        activationStartFraction: CGFloat = 0.15,
        activationRangeFraction: CGFloat = 0.85
    ) {
        self.percent = percent
        self.maxPoints = maxPoints
        self.minPoints = minPoints
        self.activationStartFraction = activationStartFraction
        self.activationRangeFraction = activationRangeFraction
    }

    public static let `default` = OverscrollPolicy()
}

// MARK: - Drag selection

/// Tuning for the auto-scroll boost that engages while the user drags a
/// selection past the visible viewport edges.
public struct DragSelectionPolicy: Sendable, Equatable {
    /// Movement threshold (points) before the auto-scroll boost engages.
    public var movementThreshold: CGFloat
    /// Distance from the window edge that triggers the boost.
    public var edgeTriggerDistance: CGFloat
    /// Pixels per tick scrolled while the boost is active.
    public var scrollStepPerTick: CGFloat
    /// Boost timer frequency (ticks per second).
    public var ticksPerSecond: Double

    public init(
        movementThreshold: CGFloat = 5.0,
        edgeTriggerDistance: CGFloat = 5.0,
        scrollStepPerTick: CGFloat = 12.0,
        ticksPerSecond: Double = 60.0
    ) {
        self.movementThreshold = movementThreshold
        self.edgeTriggerDistance = edgeTriggerDistance
        self.scrollStepPerTick = scrollStepPerTick
        self.ticksPerSecond = ticksPerSecond
    }

    public static let `default` = DragSelectionPolicy()
}

// MARK: - Safe-area insets

/// Reserves space on the scroll view for system overlays (e.g. a translucent toolbar to scroll underneath). Maps to `NSScrollView.contentInsets`; scroll bar follows the inset.
public struct SafeAreaInsets: Sendable, Equatable {
    public var top: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat
    public var bottom: CGFloat

    public init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        trailing: CGFloat = 0,
        bottom: CGFloat = 0
    ) {
        self.top = top
        self.leading = leading
        self.trailing = trailing
        self.bottom = bottom
    }

    public static let `default` = SafeAreaInsets()
}

