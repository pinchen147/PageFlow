//
//  TableOffscreenAnchorStalenessTests.swift
//  MarkdownEngineTests
//
//  OFFSCREEN-ANCHOR staleness probe. The overlay self-heal glue is
//  (a) realignWideTableOverlays on clip-view bounds change and (b) the
//  draw-time re-assert when the ANCHOR's fragment draws. If the wide
//  table's anchor is OUTSIDE the viewport and the user does not scroll,
//  neither may fire. This suite mounts a LONG doc (80 filler paragraphs
//  above the field content so the table sits far below the fold), edits
//  at the TOP (grow + shrink), and measures the overlay frame against
//  the anchor band at every stage — with and without letting the
//  DispatchQueue.main reconcile drain (the field user acts faster than
//  a full settle).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wide table offscreen-anchor staleness", .serialized)
struct TableOffscreenAnchorStalenessTests {

    final class Host {
        var text: String
        var sideMargin: CGFloat = 24
        init(_ t: String) { text = t }
    }

    struct Harness: View {
        let host: Host
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    // PageFlow's ACTUAL config since the margin slider: NO
                    // reading column; margins are text-container insets.
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: host.sideMargin, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: 16,
                documentId: "offscreenanchor",
                isEditable: true
            )
        }
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spin()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Oracles

    /// The harness oracle, verbatim (payload-based fullRange). NOTE: the
    /// .scrollableBlockFullRange payload stores ABSOLUTE offsets baked at
    /// style time, so after an unstyled-region shift it can itself be stale —
    /// which is why groundTruthViolations below exists as a second opinion.
    private func overlapViolations(textView: NativeTextView) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let storage = textView.textStorage else { return ["no layout stack"] }
        var violations: [String] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int else { return }
            guard let overlay = textView.wideTableOverlays[sourceID] else {
                // Overlays exist only inside the laid-out viewport band;
                // an offscreen table legitimately has none.
                if let band = textView.viewportCharacterRange,
                   NSLocationInRange(attrRange.location, band) {
                    violations.append("no overlay for \(sourceID)")
                }
                return
            }
            let fullRange = (storage.attribute(.scrollableBlockFullRange, at: attrRange.location, effectiveRange: nil) as? NSValue).map { AnchorRelativeRange.decode($0, anchorLocation: attrRange.location) }
                ?? ns.paragraphRange(for: attrRange)
            if fullRange.location > 1 {
                let above = ns.paragraphRange(for: NSRange(location: fullRange.location - 2, length: 0))
                let aboveRect = bridge.boundingRect(forCharacterRange: above, in: container)
                let aboveMaxY = textView.textContainerOrigin.y + aboveRect.maxY
                if overlay.frame.minY < aboveMaxY - 1.0 {
                    violations.append("overlay minY \(overlay.frame.minY) < above maxY \(aboveMaxY)")
                }
            }
            if NSMaxRange(fullRange) < ns.length - 1 {
                let below = ns.paragraphRange(for: NSRange(location: NSMaxRange(fullRange) + 1, length: 0))
                let belowRect = bridge.boundingRect(forCharacterRange: below, in: container)
                let belowMinY = textView.textContainerOrigin.y + belowRect.minY
                if overlay.frame.maxY > belowMinY + 1.0 {
                    violations.append("overlay maxY \(overlay.frame.maxY) > below minY \(belowMinY)")
                }
            }
        }
        return violations
    }

    /// Attribute-payload-independent oracle: locate the wide table by its
    /// TEXT (string search survives any shift), ensure layout (measurement
    /// only — text layout is what the app would paint; it moves NO overlay),
    /// and compare the single wide overlay's frame against the band and its
    /// prose neighbors.
    private func groundTruthViolations(textView: NativeTextView) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textView.textLayoutManager,
              let storage = textView.textStorage else { return ["no layout stack"] }
        tlm.ensureLayout(for: tlm.documentRange)
        let ns = storage.string as NSString
        let head = ns.range(of: "| 方法 | n | R (Ohm) |")
        let tail = ns.range(of: "| 简化 Arrhenius")
        guard head.location != NSNotFound, tail.location != NSNotFound else { return ["table text not found"] }
        let blockStart = ns.paragraphRange(for: NSRange(location: head.location, length: 0)).location
        let lastPara = ns.paragraphRange(for: NSRange(location: tail.location, length: 0))
        let block = NSRange(location: blockStart, length: NSMaxRange(lastPara) - blockStart)
        guard let overlay = textView.wideTableOverlays.values.first else {
            // Overlays exist only inside the laid-out viewport band — absence
            // is the CORRECT state for an out-of-band table.
            if let band = textView.viewportCharacterRange, NSLocationInRange(blockStart, band) {
                return ["no overlay"]
            }
            return []
        }

        var violations: [String] = []
        let bandRect = bridge.boundingRect(forCharacterRange: block, in: container)
        let bandTop = textView.textContainerOrigin.y + bandRect.minY
        let drift = overlay.frame.minY - bandTop
        if abs(drift) > 1.0 {
            violations.append("driftY=\(drift) (overlay.minY=\(overlay.frame.minY) bandTop=\(bandTop))")
        }
        if blockStart > 1 {
            let above = ns.paragraphRange(for: NSRange(location: blockStart - 2, length: 0))
            let aboveMaxY = textView.textContainerOrigin.y + bridge.boundingRect(forCharacterRange: above, in: container).maxY
            if overlay.frame.minY < aboveMaxY - 1.0 {
                violations.append("overlaps ABOVE prose: overlay.minY \(overlay.frame.minY) < aboveMaxY \(aboveMaxY)")
            }
        }
        if NSMaxRange(block) < ns.length - 1 {
            let below = ns.paragraphRange(for: NSRange(location: NSMaxRange(block) + 1, length: 0))
            let belowMinY = textView.textContainerOrigin.y + bridge.boundingRect(forCharacterRange: below, in: container).minY
            if overlay.frame.maxY > belowMinY + 1.0 {
                violations.append("overlaps BELOW prose: overlay.maxY \(overlay.frame.maxY) > belowMinY \(belowMinY)")
            }
        }
        return violations
    }

    /// True document location of the table anchor char (first '|' of the
    /// header row) — for auditing overlay.anchorTextLocation staleness.
    private func trueAnchorLocation(textView: NativeTextView) -> Int {
        (textView.string as NSString).range(of: "| 方法 | n | R (Ohm) |").location
    }

    private func anchorAudit(textView: NativeTextView) -> String {
        guard let overlay = textView.wideTableOverlays.values.first,
              let storage = textView.textStorage else { return "no overlay/storage" }
        let trueLoc = trueAnchorLocation(textView: textView)
        let loc = overlay.anchorTextLocation
        let ns = storage.string as NSString
        var attrAtLoc = "out-of-range"
        if loc >= 0 && loc < ns.length {
            attrAtLoc = (storage.attribute(.scrollableBlockSourceID, at: loc, effectiveRange: nil) as? Int).map(String.init) ?? "nil"
        }
        return "anchorTextLocation=\(loc) trueAnchor=\(trueLoc) delta=\(loc - trueLoc) sourceIDAttrAtStoredLoc=\(attrAtLoc) model=\(overlay.model == nil ? "nil" : "present")"
    }

    // MARK: - Document

    /// The field repro doc (verbatim from /tmp/pageflow-repro/repro.md),
    /// inlined so the test is self-contained.
    static let fieldDoc = """
    # 肖特基势垒实验报告综合评审 (四次评审)

    ## 评审范围

    纳入比较的 5 份学生实验报告:

    1. `report.pdf` (钟品晨, 2026)
    2. 肖特基势垒高度测量 reference 1/报告.pdf (张嘉骏, 2024)
    3. 肖特基势垒高度测量 reference 2/Schottky_Barrier.pdf (梁舟, 2024)

    ## 详细评审

    修正后两条路径的 qphi_b 在 0.001 eV 内一致; A 三种方法在误差范围内一致.**

    独特贡献:

    - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告.
    - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
    - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级, OLS 被高 1/I (低电流) 主导, 高电流区反映真实 R 的平台权重过小, 截距外推失真.
    - Schottky-Mott (1.60 eV) vs Bardeen (0.75 eV) vs 实验 (0.675 eV): 用 Si 禁带窄、共价键强、界面态密度高解释实验值接近 Bardeen 极限.

    | 方法 | n | R (Ohm) | qphi_b (eV) | A (A cm^-2 K^-2)** |
    | --- | --- | --- | --- | --- |
    | dV/dI 线性 | 1.398 | 1775 | -- | -- |
    | V-I 非线性 (3 参数) | 1.2913 +/- 0.0021 | 0.48 +/- 0.12 | 0.674 +/- 0.008 | -- |
    | 简化 Arrhenius (n=1, V >> IR) | -- | -- | 0.707 +/- 0.012 | 22 +/- 10 |

    # 结论: 该报告在数据处理深度与不确定度闭环方面显著优于参照组.

    ## 附录

    一个窄表格:

    | A | B |
    | --- | --- |
    | 一 | 二 |
    | 三 | 四 |

    以及更多正文, 用于观察表格之后的排版是否正常. 这一段落足够长, 可以换行并检验读列宽度的表现是否与 Obsidian 的 readable line length 一致.
    """

    static func longDoc() -> String {
        var fillers: [String] = []
        for i in 1...80 {
            fillers.append("第 \(i) 段填充: 这是用来把宽表格推到视口下方很远处的填充文字, 段落内容足够长以便在七百多点宽的容器里产生换行, 从而增加文档在垂直方向上的总高度.")
        }
        return fillers.joined(separator: "\n\n") + "\n\n" + fieldDoc
    }

    // MARK: - Scroll helpers

    private func scroll(_ textView: NativeTextView, toY y: CGFloat) {
        guard let sv = textView.enclosingScrollView else { return }
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func scrollTableIntoView(_ textView: NativeTextView) {
        revealWideTable(textView)
    }

    private func nudgeScroll1px(_ textView: NativeTextView) {
        guard let sv = textView.enclosingScrollView else { return }
        let origin = sv.contentView.bounds.origin
        sv.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 1))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func paintVisibleRegion(_ textView: NativeTextView) {
        textView.setNeedsDisplay(textView.visibleRect)
        textView.displayIfNeeded()
        textView.enclosingScrollView?.displayIfNeeded()
    }

    private func report(_ label: String, _ textView: NativeTextView) -> (payload: [String], truth: [String]) {
        let payload = overlapViolations(textView: textView)
        let truth = groundTruthViolations(textView: textView)
        print("OFFSCR [\(label)] payloadOracle=\(payload)")
        print("OFFSCR [\(label)] groundTruth=\(truth)")
        print("OFFSCR [\(label)] audit: \(anchorAudit(textView: textView))")
        return (payload, truth)
    }

    private func mount() async throws -> (NSWindow, NSHostingView<Harness>, NativeTextView, Host) {
        let host = Host(Self.longDoc())
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let textView = try #require(findEditor(in: hosting))
        await settle()
        return (window, hosting, textView, host)
    }

    // MARK: - Tests

    @Test("offscreen anchor: INSERT lines at top, no scroll — overlay must track the band")
    func offscreenAnchorInsertAtTop() async throws {
        let (window, _, textView, _) = try await mount()
        defer { window.orderOut(nil) }

        // Viewport-scoped model: at mount the table is far below the viewport,
        // so it has NO overlay — that absence IS the correct state.
        print("OFFSCR overlays after mount: \(textView.wideTableOverlays.count)")
        #expect(textView.wideTableOverlays.isEmpty, "offscreen table must have no overlay at mount")

        // Baseline 1: bring the table into view — the grid materializes there.
        scrollTableIntoView(textView)
        await settle()
        try #require(textView.wideTableOverlays.count == 1, "wide table must gain its overlay on scroll-in")
        let baseline = report("baseline table-in-view", textView)
        #expect(baseline.truth.isEmpty, "baseline must be clean before the experiment")

        // Scroll back to the top — the table (and its anchor) leave the viewport.
        scroll(textView, toY: 0)
        await settle()
        let topBaseline = report("baseline back-at-top", textView)
        #expect(topBaseline.truth.isEmpty, "scrolling back up must not disturb the overlay")

        // FAST edits at the top: three lines typed without ever letting a full
        // settle happen (the field user types faster than the async reconcile).
        let ns = textView.string as NSString
        let caret = ns.range(of: "第 3 段填充").location
        try #require(caret != NSNotFound)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertText("补充一行说明文字, 在文档顶部追加的新内容之一.\n", replacementRange: textView.selectedRange())
        spin()
        textView.insertText("再补充一行, 顶部内容继续增长以推移下方的表格.\n", replacementRange: textView.selectedRange())
        spin()
        textView.insertText("第三行补充内容, 使表格锚点继续向下移动.\n", replacementRange: textView.selectedRange())
        spin()

        // C1: no scroll, no settle — is the overlay stale right now?
        let c1 = report("C1 insert +3 lines, spin-only", textView)

        // C2: paint the visible region only (anchor fragment is offscreen so
        // its draw-glue cannot fire) — does a paint heal it?
        paintVisibleRegion(textView)
        spin()
        let c2 = report("C2 after displayIfNeeded, spin-only", textView)

        // C3: 1px scroll tick (synchronous realignWideTableOverlays) — does
        // the scroll glue heal it WITHOUT a main-queue drain?
        nudgeScroll1px(textView)
        spin()
        let c3 = report("C3 after 1px scroll, spin-only", textView)

        // C4: full settle — the coalesced reconcile runs. Under the
        // viewport-scoped model the offscreen overlay is simply GONE (swept),
        // and no grid may be painted anywhere near the edited prose.
        await settle()
        let c4 = report("C4 after full settle", textView)
        #expect(c4.truth.isEmpty, "no grid may sit over prose after edits above an offscreen table")

        // C5: scroll back to the table — the grid must materialize on its
        // band with fresh bookkeeping (the actual user-facing guarantee).
        scrollTableIntoView(textView)
        await settle()
        try #require(textView.wideTableOverlays.count == 1, "table must regain its overlay on scroll-in")
        let c5 = report("C5 back at table", textView)
        #expect(c5.truth.isEmpty, "scroll-in grid must sit on its band after edits above")
        let trueLoc = trueAnchorLocation(textView: textView)
        let storedLoc = textView.wideTableOverlays.values.first?.anchorTextLocation ?? -1
        print("OFFSCR [C5] stored anchor=\(storedLoc) true anchor=\(trueLoc)")
        #expect(storedLoc == trueLoc, "anchorTextLocation must be refreshed on re-create, else scroll-glue is dead")

        _ = (c1, c2, c3)
    }

    @Test("offscreen anchor: DELETE a block above, no scroll — the field symptom direction")
    func offscreenAnchorDeleteAbove() async throws {
        let (window, _, textView, _) = try await mount()
        defer { window.orderOut(nil) }
        #expect(textView.wideTableOverlays.isEmpty, "offscreen table must have no overlay at mount")

        scrollTableIntoView(textView)
        await settle()
        try #require(textView.wideTableOverlays.count == 1, "wide table must gain its overlay on scroll-in")
        #expect(groundTruthViolations(textView: textView).isEmpty)
        scroll(textView, toY: 0)
        await settle()
        let base = report("baseline before delete", textView)
        #expect(base.truth.isEmpty)

        // Delete two whole filler paragraphs near the top (about a heading
        // block's worth of height) with a REAL selection + deleteBackward.
        let ns = textView.string as NSString
        let start = ns.range(of: "第 5 段填充").location
        let endMarker = ns.range(of: "第 7 段填充").location
        try #require(start != NSNotFound && endMarker != NSNotFound && endMarker > start)
        let deleteRange = NSRange(location: start, length: endMarker - start)
        textView.setSelectedRange(deleteRange)
        spin()
        textView.deleteBackward(nil)
        spin()

        // D1: no scroll, no settle. Content above SHRANK → the band moved UP →
        // a stale overlay now sits BELOW its band over the following prose:
        // the exact field screenshot.
        let d1 = report("D1 delete 2 paras, spin-only", textView)

        // D2: visible-region paint only.
        paintVisibleRegion(textView)
        spin()
        let d2 = report("D2 after displayIfNeeded, spin-only", textView)

        // D3: 1px scroll tick.
        nudgeScroll1px(textView)
        spin()
        let d3 = report("D3 after 1px scroll, spin-only", textView)

        // D4: full settle — the offscreen overlay is swept; nothing may be
        // painted over the edited region (the exact field screenshot check).
        await settle()
        let d4 = report("D4 after full settle", textView)
        #expect(d4.truth.isEmpty, "no grid may sit over prose after a delete above an offscreen table")

        // D5: scroll back — the grid must materialize on its band, fresh.
        scrollTableIntoView(textView)
        await settle()
        try #require(textView.wideTableOverlays.count == 1, "table must regain its overlay on scroll-in")
        #expect(groundTruthViolations(textView: textView).isEmpty, "scroll-in grid must sit on its band after the delete")
        let trueLoc = trueAnchorLocation(textView: textView)
        let storedLoc = textView.wideTableOverlays.values.first?.anchorTextLocation ?? -1
        print("OFFSCR [D5] stored anchor=\(storedLoc) true anchor=\(trueLoc)")
        #expect(storedLoc == trueLoc, "anchorTextLocation must be refreshed on re-create, else scroll-glue is dead")

        // D6: now scroll the table back into view the way a user would —
        // does the overlay land on the band, or does the stale anchor leave
        // it one block off (the persistent field symptom)?
        scrollTableIntoView(textView)
        spin()
        let d6 = report("D6 table scrolled into view, spin-only", textView)
        await settle()
        let d7 = report("D7 table in view, settled", textView)
        #expect(d7.truth.isEmpty, "after scrolling back, the settled overlay must sit on its band")

        _ = (d1, d2, d3, d6)
    }

    @Test("MINIMAL: one char typed at top of a long doc, table never scrolled into view")
    func minimalOneCharInsert() async throws {
        let (window, _, textView, _) = try await mount()
        defer { window.orderOut(nil) }
        #expect(textView.wideTableOverlays.isEmpty, "offscreen table must have no overlay at mount")
        let base = report("M0 mounted, never scrolled", textView)
        #expect(base.truth.isEmpty)

        // Single character typed at the very start of the document.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: textView.selectedRange())
        spin()
        let m1 = report("M1 +1 char, spin-only", textView)

        // Give the sync heal paths every chance: paint + 1px scroll tick.
        paintVisibleRegion(textView)
        nudgeScroll1px(textView)
        spin()
        let m2 = report("M2 paint + 1px scroll, spin-only", textView)

        await settle()
        let m3 = report("M3 settled", textView)
        #expect(m3.truth.isEmpty)

        // The user-facing guarantee: scroll to the table after the keystroke —
        // the grid materializes on its band with fresh bookkeeping.
        scrollTableIntoView(textView)
        await settle()
        try #require(textView.wideTableOverlays.count == 1, "table must gain its overlay on scroll-in")
        let m4 = report("M4 table scrolled into view", textView)
        #expect(m4.truth.isEmpty)
        let trueLoc = trueAnchorLocation(textView: textView)
        let storedLoc = textView.wideTableOverlays.values.first?.anchorTextLocation ?? -1
        print("OFFSCR [M5] stored anchor=\(storedLoc) true anchor=\(trueLoc) delta=\(storedLoc - trueLoc)")
        #expect(storedLoc == trueLoc, "one keystroke above an offscreen table must not strand anchorTextLocation")

        _ = (m1, m2)
    }
}
