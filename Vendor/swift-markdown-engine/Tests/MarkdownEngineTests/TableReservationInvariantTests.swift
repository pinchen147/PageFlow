//
//  TableReservationInvariantTests.swift
//  MarkdownEngineTests
//
//  Repro + regression coverage for the "table grid drawn over flowing text"
//  bug: a rendered standalone block (table/LaTeX image) is only correct when
//  the paragraph carrying its anchor character also carries the tall
//  line-height reservation. If any restyle path strips the reservation while
//  the anchor image attribute survives, the grid draws over normally-flowing
//  text (rows appear interleaved with the surrounding paragraphs).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table reservation invariant")
struct TableReservationInvariantTests {

    private final class State {
        var text: String
        var isWikiLinkActive = false
        init(text: String) { self.text = text }
    }

    /// A document shaped like the field report that surfaced the bug: CJK
    /// bullet prose around a genuinely wide (breakout) pipe table.
    private static let wideTableDoc = """
    # 实验报告综合评审

    修正后两条路径的 qphi_b 在 0.001 eV 内一致; A** 三种方法在误差范围内一致.

    独特贡献:

    - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告.
    - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
    - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级, OLS 被高 1/I (低电流) 主导, 高电流区反映真实 R 的平台权重过小, 截距外推失真.

    | 方法 | n | R (Ohm) | qphi_b (eV) | A** (A cm^-2 K^-2) |
    | --- | --- | --- | --- | --- |
    | dV/dI 线性 | 1.398 | 1775 | -- | -- |
    | V-I 非线性 (3 参数) | 1.2913 +/- 0.0021 | 0.48 +/- 0.12 | 0.674 +/- 0.008 | -- |
    | 简化 Arrhenius (n=1, V >> IR) | -- | -- | 0.707 +/- 0.012 | 22 +/- 10 |

    - 自制能带图 (接触前、Schottky-Mott 极限、Bardeen 钉扎极限) 质量高, 标注完整.
    """

    /// Same document but with the blank lines around the table removed, so the
    /// table butts directly against the bullet list (a common authoring shape).
    private static let adjacentTableDoc = wideTableDoc
        .replacingOccurrences(of: "截距外推失真.\n\n|", with: "截距外推失真.\n|")
        .replacingOccurrences(of: "| 22 +/- 10 |\n\n-", with: "| 22 +/- 10 |\n-")

    private func makeEditor(
        text: String,
        readingWidth: CGFloat? = 700
    ) -> (NativeTextViewCoordinator, NativeTextView, NativeTextViewContainer) {
        _ = NSApplication.shared
        let state = State(text: text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            isWikiLinkActive: Binding(get: { state.isWikiLinkActive }, set: { state.isWikiLinkActive = $0 }),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )

        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = readingWidth
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 748, height: 800))
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("no TextKit 2 stack")
        }
        textContainer.lineFragmentPadding = 0
        if let readingWidth {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: readingWidth, height: .greatestFiniteMagnitude)
        }
        textView.textContainerInset = NSSize(width: 24, height: 0)
        textView.configuration = configuration
        coordinator.configuration = configuration
        textView.baseFont = NSFont.systemFont(ofSize: 16)
        textView.isEditable = true

        let bridge = LayoutBridge(textLayoutManager)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        // Mirror makeNSView's reading-column shape: the text view is a centered
        // child of the full-width container; breakout overlays land in the container.
        let container = NativeTextViewContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        container.textView = textView
        container.addSubview(textView)

        textView.string = text
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        // Overlays exist only inside the laid-out viewport band; a bare
        // harness view never gets AppKit's viewport pass, so run one.
        textLayoutManager.textViewportLayoutController.layoutViewport()
        return (coordinator, textView, container)
    }

    /// Every block-image anchor (collapsed table / block LaTeX) must sit in a
    /// paragraph whose effective style reserves at least the block's height.
    /// Returns human-readable violations; empty = invariant holds.
    private func reservationViolations(in textView: NativeTextView) -> [String] {
        guard let storage = textView.textStorage else { return ["no storage"] }
        var violations: [String] = []
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.renderedBlockImage, in: full, options: []) { value, range, _ in
            guard let image = value as? NSImage,
                  storage.attribute(.latexIsBlock, at: range.location, effectiveRange: nil) as? Bool == true,
                  // visibleSource mode reserves via paragraphSpacing, not line height.
                  storage.attribute(.latexBlockOffsetY, at: range.location, effectiveRange: nil) == nil
            else { return }
            let needed: CGFloat
            if let total = storage.attribute(
                .scrollableBlockTotalHeight, at: range.location, effectiveRange: nil
            ) as? CGFloat {
                needed = total
            } else {
                needed = image.size.height
            }
            let para = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            let style = storage.attribute(
                .paragraphStyle, at: para.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let reserved = style?.minimumLineHeight ?? 0
            if reserved + 0.5 < needed {
                violations.append(
                    "anchor at \(range.location): reserved \(reserved)pt < needed \(needed)pt"
                )
            }
        }
        return violations
    }

    private func tableToken(in coordinator: NativeTextViewCoordinator, text: String) -> (index: Int, token: MarkdownToken)? {
        let tokens = coordinator.parsedDocument(for: text).tokens
        for (i, t) in tokens.enumerated() where t.kind == .table { return (i, t) }
        return nil
    }

    @Test("initial full style reserves the wide table's height")
    func initialStyleHoldsInvariant() {
        let (_, textView, container) = makeEditor(text: Self.wideTableDoc)
        #expect(reservationViolations(in: textView).isEmpty)

        // The wide table must produce a breakout overlay glued to the reserved line.
        textView.performWideTableOverlayUpdate()
        #expect(textView.wideTableOverlays.count == 1)
        _ = container
    }

    @Test("table adjacent to bullet list (no blank lines) holds the invariant")
    func adjacentTableHoldsInvariant() {
        let (coordinator, textView, _) = makeEditor(text: Self.adjacentTableDoc)
        // Only meaningful if the tokenizer still sees a table here.
        let hasTable = coordinator.parsedDocument(for: Self.adjacentTableDoc)
            .tokens.contains { $0.kind == .table }
        if hasTable {
            #expect(reservationViolations(in: textView).isEmpty)
        }
    }

    @Test("caret into the table and back out restores the reservation")
    func caretRoundTripRestoresInvariant() throws {
        let (coordinator, textView, _) = makeEditor(text: Self.wideTableDoc)
        let ns = textView.string as NSString
        let (_, token) = try #require(tableToken(in: coordinator, text: textView.string))
        textView.performWideTableOverlayUpdate()
        #expect(textView.wideTableOverlays.count == 1)

        // Caret INTO the table with its source revealed (Edit Table Source;
        // a plain caret edits a cell and never unfolds the table).
        coordinator.tableEditingSession.revealSource(of: token.range)
        let inside = NSRange(location: token.range.location + 2, length: 0)
        textView.setSelectedRange(inside)
        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: inside, tokens: coordinator.parsedDocument(for: textView.string).tokens, in: ns
        )
        coordinator.restyleTextView(
            textView,
            paragraphCandidates: [ns.paragraphRange(for: token.range)],
            tokens: coordinator.parsedDocument(for: textView.string).tokens
        )
        // Active table = raw source, no reservation — and the overlay must go.
        textView.performWideTableOverlayUpdate()
        #expect(textView.wideTableOverlays.isEmpty)

        // Caret back OUT.
        let outside = NSRange(location: 0, length: 0)
        textView.setSelectedRange(outside)
        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: outside, tokens: coordinator.parsedDocument(for: textView.string).tokens, in: ns
        )
        coordinator.restyleTextView(
            textView,
            paragraphCandidates: [ns.paragraphRange(for: token.range)],
            tokens: coordinator.parsedDocument(for: textView.string).tokens
        )
        #expect(reservationViolations(in: textView).isEmpty)
        textView.performWideTableOverlayUpdate()
        #expect(textView.wideTableOverlays.count == 1)
    }

    @Test("full-range restyle (appearance flip path) keeps the reservation")
    func fullRangeRestyleHoldsInvariant() {
        let (coordinator, textView, _) = makeEditor(text: Self.wideTableDoc)
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        coordinator.restyleParagraphs([fullRange], in: textView)
        #expect(reservationViolations(in: textView).isEmpty)
        textView.performWideTableOverlayUpdate()
        #expect(textView.wideTableOverlays.count == 1)
    }

    @Test("partial-scope restyles never leave a half-styled table")
    func partialScopeRestylesHoldInvariant() throws {
        let (coordinator, textView, _) = makeEditor(text: Self.wideTableDoc)
        let ns = textView.string as NSString
        let (_, token) = try #require(tableToken(in: coordinator, text: textView.string))

        // Scope = paragraph directly above the table.
        let above = ns.paragraphRange(for: NSRange(location: max(0, token.range.location - 2), length: 0))
        coordinator.restyleParagraphs([above], in: textView)
        #expect(reservationViolations(in: textView).isEmpty)

        // Scope = the anchor line only (first table source line).
        let anchorLine = ns.paragraphRange(for: NSRange(location: token.range.location, length: 0))
        coordinator.restyleParagraphs([anchorLine], in: textView)
        #expect(reservationViolations(in: textView).isEmpty)

        // Scope = a middle table source line only.
        let middle = ns.paragraphRange(for: NSRange(location: token.range.location + token.range.length / 2, length: 0))
        coordinator.restyleParagraphs([middle], in: textView)
        #expect(reservationViolations(in: textView).isEmpty)
    }

    @Test("overlay frame covers exactly the reserved band, not the prose above")
    func overlayFrameMatchesReservedLine() throws {
        let (coordinator, textView, container) = makeEditor(text: Self.wideTableDoc)
        let ns = textView.string as NSString
        let (_, token) = try #require(tableToken(in: coordinator, text: textView.string))
        textView.performWideTableOverlayUpdate()
        let overlay = try #require(textView.wideTableOverlays.values.first)

        // The paragraph ABOVE the table must lie fully above the overlay.
        guard let storage = textView.textStorage,
              let bridge = textView.layoutBridge,
              let tk2Container = bridge.firstTextContainer else {
            Issue.record("no layout stack")
            return
        }
        _ = storage
        let aboveRange = ns.paragraphRange(for: NSRange(location: max(0, token.range.location - 2), length: 0))
        let aboveRect = bridge.boundingRect(forCharacterRange: aboveRange, in: tk2Container)
        let aboveMaxYInContainer = textView.frame.origin.y + textView.textContainerOrigin.y + aboveRect.maxY
        #expect(
            overlay.frame.minY >= aboveMaxYInContainer - 1.0,
            "overlay (minY \(overlay.frame.minY)) overlaps the paragraph above (maxY \(aboveMaxYInContainer))"
        )
        _ = container
    }
}
