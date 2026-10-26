//
//  TableOverlayEndToEndTests.swift
//  MarkdownEngineTests
//
//  End-to-end coverage for wide-table overlay geometry: hosts the REAL
//  NativeTextViewWrapper (SwiftUI) in an offscreen NSWindow exactly as
//  PageFlow embeds it (reading column 700, 24pt gutters, top content inset,
//  forced-appearance knob), and asserts the overlay sits on its reserved band
//  after mount, appearance flips, scrolling, and — the regression that
//  motivated this file — after its frame goes stale (the draw-time glue in
//  MarkdownTextLayoutFragment must self-heal it).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table overlay end-to-end", .serialized)
struct TableOverlayEndToEndTests {

    /// Host state driving the wrapper exactly like PageFlow's MarkdownTabView.
    final class Host {
        var text: String
        var forcedAppearanceName: NSAppearance.Name?
        init(text: String) { self.text = text }
    }

    struct EditorHarnessView: View {
        let host: Host
        let configuration: MarkdownEditorConfiguration

        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: configuration,
                fontSize: 16,
                documentId: "e2e",
                isEditable: true,
                forcedAppearanceName: host.forcedAppearanceName
            )
        }
    }

    static let doc = """
    # 实验报告综合评审

    独特贡献:

    - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告.
    - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
    - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级, OLS 被高 1/I (低电流) 主导, 高电流区反映真实 R 的平台权重过小, 截距外推失真.
    - A** 偏低的多来源分析: Ae 标称值可能偏差、Crowell-Sze 理论本身含声子散射修正和载流子有效质量不确定 (sigma(A**)/A** ~ 46%).

    | 方法 | n | R (Ohm) | qphi_b (eV) | A** (A cm^-2 K^-2) |
    | --- | --- | --- | --- | --- |
    | dV/dI 线性 | 1.398 | 1775 | -- | -- |
    | V-I 非线性 (3 参数) | 1.2913 +/- 0.0021 | 0.48 +/- 0.12 | 0.674 +/- 0.008 | -- |
    | 简化 Arrhenius (n=1, V >> IR) | -- | -- | 0.707 +/- 0.012 | 22 +/- 10 |

    - 自制能带图 (接触前、Schottky-Mott 极限、Bardeen 钉扎极限) 质量高, 标注完整.

    结尾段落.
    """

    private func pageFlowConfiguration() -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 700
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)
        configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
        return configuration
    }

    /// Interleave run-loop turns with actor suspensions so BOTH runloop
    /// sources and `DispatchQueue.main.async` blocks (the overlay reconcile,
    /// the draw-time glue) actually execute.
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spinRunLoopOnce()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Synchronous run-loop turn (RunLoop.run is unavailable in async contexts).
    private func spinRunLoopOnce() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func mount(host: Host) async -> (NSWindow, NSHostingView<EditorHarnessView>) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: EditorHarnessView(
            host: host,
            configuration: pageFlowConfiguration()
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)   // offscreen-ish but layout + display run
        hosting.layoutSubtreeIfNeeded()
        await settle()
        return (window, hosting)
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    /// Geometry invariant: every overlay must sit exactly on its reserved band —
    /// at/below the previous paragraph's bottom and above the next one's top.
    private func overlapViolations(textView: NativeTextView) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let storage = textView.textStorage else { return ["no layout stack"] }
        var violations: [String] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(
            .scrollableBlockSourceID,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, attrRange, _ in
            guard let sourceID = value as? Int else { return }
            guard let overlay = textView.wideTableOverlays[sourceID] else {
                // Overlays exist only inside the laid-out viewport band;
                // an offscreen table legitimately has none.
                if let band = textView.viewportCharacterRange,
                   NSLocationInRange(attrRange.location, band) {
                    violations.append("no overlay for sourceID \(sourceID)")
                }
                return
            }
            let fullRange = (storage.attribute(.scrollableBlockFullRange, at: attrRange.location, effectiveRange: nil) as? NSValue).map { AnchorRelativeRange.decode($0, anchorLocation: attrRange.location) }
                ?? ns.paragraphRange(for: attrRange)
            // Paragraph above the whole table source:
            if fullRange.location > 1 {
                let above = ns.paragraphRange(for: NSRange(location: fullRange.location - 2, length: 0))
                let aboveRect = bridge.boundingRect(forCharacterRange: above, in: container)
                let aboveMaxY = textView.frame.origin.y + textView.textContainerOrigin.y + aboveRect.maxY
                if overlay.frame.minY < aboveMaxY - 1.0 {
                    violations.append("overlay minY \(overlay.frame.minY) < above maxY \(aboveMaxY)")
                }
            }
            // Paragraph below the whole table source:
            if NSMaxRange(fullRange) < ns.length - 1 {
                let below = ns.paragraphRange(for: NSRange(location: NSMaxRange(fullRange) + 1, length: 0))
                let belowRect = bridge.boundingRect(forCharacterRange: below, in: container)
                let belowMinY = textView.frame.origin.y + textView.textContainerOrigin.y + belowRect.minY
                if overlay.frame.maxY > belowMinY + 1.0 {
                    violations.append("overlay maxY \(overlay.frame.maxY) > below minY \(belowMinY)")
                }
            }
        }
        return violations
    }

    @Test("mounting the real wrapper creates the overlay on its reserved band")
    func mountedOverlayGeometry() async throws {
        let host = Host(text: Self.doc)
        let (window, hosting) = await mount(host: host)
        defer { window.orderOut(nil) }

        let textView = try #require(findEditor(in: hosting))
        await settle()
        #expect(!textView.wideTableOverlays.isEmpty, "expected a breakout overlay for the wide table")
        #expect(overlapViolations(textView: textView).isEmpty)
    }

    @Test("flipping the forced appearance keeps overlay geometry intact")
    func appearanceFlipKeepsGeometry() async throws {
        let host = Host(text: Self.doc)
        let (window, hosting) = await mount(host: host)
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.forcedAppearanceName = name
            hosting.rootView = EditorHarnessView(host: host, configuration: pageFlowConfiguration())
            hosting.layoutSubtreeIfNeeded()
            await settle()
            #expect(overlapViolations(textView: textView).isEmpty, "violations after forcing \(name.rawValue)")
        }
    }

    @Test("scrolling to the table keeps overlay geometry intact")
    func scrollKeepsGeometry() async throws {
        let host = Host(text: Self.doc)
        let (window, hosting) = await mount(host: host)
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        guard let scrollView = textView.enclosingScrollView else {
            Issue.record("no scroll view")
            return
        }
        await settle()

        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        for y in stride(from: 0, through: maxY, by: max(1, maxY / 4)) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await settle(2)
        }
        await settle()
        #expect(overlapViolations(textView: textView).isEmpty)
    }

    @Test("a stale overlay frame self-heals on the next scroll tick")
    func staleOverlaySelfHeals() async throws {
        let host = Host(text: Self.doc)
        let (window, hosting) = await mount(host: host)
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        let overlay = try #require(textView.wideTableOverlays.values.first)
        let goodFrame = overlay.frame
        #expect(overlapViolations(textView: textView).isEmpty)

        // Sabotage: emulate a missed reconcile — the overlay ends up 300pt above
        // its band, drawn over prose (the bug from the field report).
        overlay.frame = goodFrame.offsetBy(dx: 0, dy: -300)
        #expect(!overlapViolations(textView: textView).isEmpty, "sabotage should violate the band invariant")

        // The next scroll tick must re-glue the overlay (clip-view bounds
        // observer → realignWideTableOverlays).
        let scrollView = try #require(textView.enclosingScrollView)
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle()

        #expect(overlapViolations(textView: textView).isEmpty, "scroll glue should restore the frame")
        #expect(abs(overlay.frame.origin.y - goodFrame.origin.y) < 1.0)
    }
}

@MainActor
@Suite("Table overlay after real edits", .serialized)
struct TableOverlayEditTests {
    typealias H = TableOverlayEndToEndTests

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spin()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// Overlay must sit at/below the paragraph above and above the paragraph below.
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
                let aboveMaxY = textView.frame.origin.y + textView.textContainerOrigin.y + aboveRect.maxY
                if overlay.frame.minY < aboveMaxY - 1.0 {
                    violations.append("overlay minY \(overlay.frame.minY) < above maxY \(aboveMaxY)")
                }
            }
            if NSMaxRange(fullRange) < ns.length - 1 {
                let below = ns.paragraphRange(for: NSRange(location: NSMaxRange(fullRange) + 1, length: 0))
                let belowRect = bridge.boundingRect(forCharacterRange: below, in: container)
                let belowMinY = textView.frame.origin.y + textView.textContainerOrigin.y + belowRect.minY
                if overlay.frame.maxY > belowMinY + 1.0 {
                    violations.append("overlay maxY \(overlay.frame.maxY) > below minY \(belowMinY)")
                }
            }
        }
        return violations
    }

    @Test("typing above the table keeps the overlay on its band")
    func typingAboveKeepsOverlayBand() async throws {
        let host = H.Host(text: H.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: {
            var c = MarkdownEditorConfiguration.default
            c.readingWidth = 700
            c.textInsets = TextInsets(horizontal: 24, vertical: 0)
            c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
            return c
        }()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        try #require(!textView.wideTableOverlays.isEmpty)
        #expect(overlapViolations(textView: textView).isEmpty, "baseline")

        // Real keystrokes in the paragraph above the table.
        let ns = textView.string as NSString
        let loc = ns.range(of: "独特贡献").location
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        for ch in ["新", "增", "\n", "更多文字"] {
            textView.insertText(ch, replacementRange: textView.selectedRange())
            await settle(2)
        }
        await settle()
        print("EDITREPRO typing violations: \(overlapViolations(textView: textView))")
        #expect(overlapViolations(textView: textView).isEmpty)
    }

    /// The field doc VERBATIM (/tmp/pageflow-repro/repro.md, 2026-07-03): prose
    /// with STRAY `**` runs (one inside the table header cell), backtick code,
    /// numbered/bulleted lists, the wide table, a heading, a NARROW table, and
    /// a trailing paragraph — everything that must stay below the grid.
    static let fullWidthDoc = """
    # 肖特基势垒实验报告综合评审 (四次评审)

    ## 评审范围

    纳入比较的 5 份学生实验报告:

    1. `report.pdf` (钟品晨, 2026)
    2. 肖特基势垒高度测量 reference 1/报告.pdf (张嘉骏, 2024)
    3. 肖特基势垒高度测量 reference 2/Schottky_Barrier.pdf (梁舟, 2024)
    4. 肖特基势垒高度测量 reference 3/热激活法研究金属半导体接触的肖特基势垒_2000011528.pdf (顾睿哲, 2023)
    5. 肖特基势垒高度测量 reference 4/热激活法研究肖特基势垒性质.pdf

    未纳入: 顶层 用热激活法测量肖特基势垒高度.pdf 为实验讲义, 不是学生报告.

    ## 评分 rubric

    总分 100, 按以下维度比较:

    - 科学严谨性与物理理解: 25
    - 数据处理与参数提取方法: 25
    - 误差/不确定度分析: 20
    - 图表与呈现质量: 15
    - 写作与结构: 15

    ## 详细评审

    修正后两条路径的 qphi_b 在 0.001 eV 内一致; A 三种方法在误差范围内一致.**

    独特贡献:

    - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告. (其余报告在思考题中提到了此公式, 但无一在正文数据处理中实际使用.)
    - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
    - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级 (~ 10 Ohm 到 ~ 5 x 10^4 Ohm), OLS 被高 1/I (低电流) 主导, 高电流区反映真实 R 的平台权重过小, 截距外推失真.
    - A 偏低的多来源分析: Ae 标称值可能偏差、Crowell-Sze 理论本身含声子散射修正和载流子有效质量不确定、6 个温度点/DeltaT ~ 24 K 使截距外推杠杆臂不足 (sigma(A)/A ~ 46%).******
    - Schottky-Mott (1.60 eV) vs Bardeen (0.75 eV) vs 实验 (0.675 eV): 用 Si 禁带窄、共价键强、界面态密度高解释实验值接近 Bardeen 极限, 并定量估计镜像力降低 Delta_phi ~ 0.02-0.05 eV 可解释剩余差值.
    - 自制能带图 (接触前、Schottky-Mott 极限、Bardeen 钉扎极限) 质量高, 标注完整.

    | 方法 | n | R (Ohm) | qphi_b (eV) | A (A cm^-2 K^-2)** |
    | --- | --- | --- | --- | --- |
    | dV/dI 线性 | 1.398 | 1775 | -- | -- |
    | V-I 非线性 (3 参数) | 1.2913 +/- 0.0021 | 0.48 +/- 0.12 | 0.674 +/- 0.008 | -- |
    | 简化 Arrhenius (n=1, V >> IR) | -- | -- | 0.707 +/- 0.012 | 22 +/- 10 |

    第二个比较维度, 同样超宽:

    | 报告 | 科学严谨性与物理理解 | 数据处理与参数提取方法 | 误差/不确定度分析 | 图表与呈现质量 | 写作与结构 |
    | --- | --- | --- | --- | --- | --- |
    | report.pdf (钟品晨) | 24 | 25 | 19 | 13 | 14 |
    | 报告.pdf (张嘉骏) | 20 | 19 | 14 | 12 | 13 |
    | Schottky_Barrier.pdf (梁舟) | 19 | 18 | 12 | 12 | 12 |

    中间一段正文, 分隔两个宽表格, 用于检验相邻 overlay 的独立回收与重建.

    | 温度点 | T (K) | ln(I0/T^2) 截距 | 1/T (10^-3 K^-1) | 拟合残差 | 备注 |
    | --- | --- | --- | --- | --- | --- |
    | 1 | 296.15 | -18.412 | 3.377 | 0.004 | 基准 |
    | 2 | 320.15 | -16.881 | 3.124 | 0.006 | -- |
    | 3 | 344.15 | -15.523 | 2.906 | 0.003 | -- |

    # 结论: 该报告在数据处理深度与不确定度闭环方面显著优于参照组.

    ## 附录

    一个窄表格:

    | A | B |
    | --- | --- |
    | 一 | 二 |
    | 三 | 四 |

    以及更多正文, 用于观察表格之后的排版是否正常. 这一段落足够长, 可以换行并检验读列宽度的表现是否与 Obsidian 的 readable line length 一致.
    """

    /// The field SYMPTOM, asserted directly and independently of the overlay's
    /// own (possibly corrupted) bookkeeping: no visible overlay may intersect
    /// the on-screen rect of any paragraph OUTSIDE the table source it belongs
    /// to. Catches a grid painted over the 附录 heading even when fullRange
    /// itself decodes to garbage.
    private func groundTruthViolations(textView: NativeTextView, probes: [String]) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let storage = textView.textStorage else { return ["no layout stack"] }
        let ns = storage.string as NSString
        var violations: [String] = []
        for probe in probes {
            let range = ns.range(of: probe)
            guard range.location != NSNotFound else { continue }
            let paragraph = ns.paragraphRange(for: range)
            let rect = bridge.boundingRect(forCharacterRange: paragraph, in: container)
            let onScreen = rect.offsetBy(dx: textView.textContainerOrigin.x + textView.frame.origin.x,
                                         dy: textView.textContainerOrigin.y + textView.frame.origin.y)
            for (sourceID, overlay) in textView.wideTableOverlays where !overlay.isHidden {
                if overlay.frame.intersects(onScreen) {
                    violations.append("overlay \(sourceID) \(overlay.frame) covers '\(probe)' at \(onScreen)")
                }
            }
        }
        return violations
    }

    /// Probe paragraphs that must never sit under the wide grid — everything
    /// around the wide table in the field doc.
    static let groundTruthProbes = ["自制能带图", "# 结论", "## 附录", "一个窄表格", "以及更多正文"]

    /// The FIELD wrapper view — every knob MarkdownEditorView passes in the app
    /// (persisted settings read from the field defaults, 2026-07-03): scoped bus,
    /// literal-markdown substitution, per-tab undo manager, forced-light
    /// appearance, side margin 80.34, restored initial scroll offset.
    struct FieldHarnessView: View {
        let host: H.Host
        let bus: MarkdownEditorBus
        let undoManager: UndoManager

        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    var c = MarkdownEditorConfiguration.default
                    c.inputSubstitution = .literalMarkdown
                    c.services.bus = bus
                    c.textInsets = TextInsets(horizontal: 80.33945610687023, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontName: "SF Pro",
                fontSize: 16,
                documentId: "field-tab",
                isEditable: true,
                forcedAppearanceName: .aqua,
                undoManager: undoManager,
                initialScrollOffset: 600
            )
        }
    }

    /// ⌘A then ⌘U ⌘B ⌘I in FULL-WIDTH mode (readingWidth == nil — the app's
    /// real mode since the margin slider), driven through the SAME bus leg the
    /// app's menu/toolbar uses. Field report 2026-07-03: grid painted over the
    /// 附录 heading after select-all + format commands.
    @Test("select-all underline keeps the overlay on its band (full-width mode)")
    func selectAllUnderlineFullWidthMode() async throws {
        let host = H.Host(text: Self.fullWidthDoc)
        let bus = MarkdownEditorBus(
            applyBoldRequest: Notification.Name("pf.md.bold.field-tab"),
            applyItalicRequest: Notification.Name("pf.md.italic.field-tab"),
            applyUnderlineRequest: Notification.Name("pf.md.underline.field-tab"),
            scopeByObject: true
        )
        let undo = UndoManager()
        let hosting = NSHostingView(rootView: FieldHarnessView(host: host, bus: bus, undoManager: undo))
        // The field window: ~833pt wide, short — the table exceeds the
        // container (833 − 2×80.3) and breaks out into an overlay.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 833, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        // Grids exist only inside the viewport band — bring the first wide
        // table on screen before asserting its overlay (the field session
        // was scrolled to the table).
        revealWideTable(textView)
        await settle()
        try #require(!textView.wideTableOverlays.isEmpty)
        #expect(overlapViolations(textView: textView).isEmpty, "baseline")

        // ⌘A then ⌘U ⌘B ⌘I — the field "command A command UBI" sequence,
        // posted through the scoped bus exactly like TabManager does. Each
        // apply re-selects the formatted span, so commands compose. Between
        // commands the app's debounced binding write lands and @Observable
        // re-runs the SwiftUI body — model that with a rootView reassignment
        // (value-identical view → updateNSView reconcile, no rebuild).
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        for (label, name) in [("⌘U", bus.applyUnderlineRequest),
                              ("⌘B", bus.applyBoldRequest),
                              ("⌘I", bus.applyItalicRequest)] {
            NotificationCenter.default.post(name: try #require(name), object: "field-tab")
            await settle()
            hosting.rootView = FieldHarnessView(host: host, bus: bus, undoManager: undo)
            hosting.layoutSubtreeIfNeeded()
            await settle()
            let band = overlapViolations(textView: textView)
            let ground = groundTruthViolations(textView: textView, probes: Self.groundTruthProbes)
            print("EDITREPRO fullwidth \(label) band: \(band) ground: \(ground) overlays: \(textView.wideTableOverlays.count)")
            #expect(band.isEmpty, "after ⌘A\(label)")
            #expect(ground.isEmpty, "ground truth after ⌘A\(label)")
        }

        // The user's next move after mangling the doc: ⌘Z ⌘Z ⌘Z (each format
        // batch is one undo step), then a redo — every step must hold the band.
        for step in 1...3 {
            undo.undo()
            await settle()
            let band = overlapViolations(textView: textView)
            let ground = groundTruthViolations(textView: textView, probes: Self.groundTruthProbes)
            print("EDITREPRO fullwidth undo\(step) band: \(band) ground: \(ground) overlays: \(textView.wideTableOverlays.count)")
            #expect(band.isEmpty, "after undo \(step)")
            #expect(ground.isEmpty, "ground truth after undo \(step)")
        }
        undo.redo()
        await settle()
        let redoBand = overlapViolations(textView: textView)
        let redoGround = groundTruthViolations(textView: textView, probes: Self.groundTruthProbes)
        print("EDITREPRO fullwidth redo band: \(redoBand) ground: \(redoGround)")
        #expect(redoBand.isEmpty, "after redo")
        #expect(redoGround.isEmpty, "ground truth after redo")
    }

    @Test("select-all underline keeps the overlay on its band")
    func selectAllUnderlineKeepsOverlayBand() async throws {
        let host = H.Host(text: H.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: {
            var c = MarkdownEditorConfiguration.default
            c.readingWidth = 700
            c.textInsets = TextInsets(horizontal: 24, vertical: 0)
            return c
        }()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        try #require(!textView.wideTableOverlays.isEmpty)

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        (textView.delegate as? NativeTextViewCoordinator)?.didMarkdownUnderline(nil)
        await settle()
        print("EDITREPRO cmdAU violations: \(overlapViolations(textView: textView))")
        print("EDITREPRO overlays: \(textView.wideTableOverlays.count)")
        #expect(overlapViolations(textView: textView).isEmpty)
    }

    /// ⌘A ⌘U inserts markup above the table, so its anchor moves. The realign
    /// that runs inside the edit used to hide the grid as unvalidatable and
    /// the reconcile re-showed it a turn later: the table blinked off and on
    /// once per format command and once per undo.
    @Test("select-all underline and its undo keep the on-screen table drawn through the edit")
    func selectAllUnderlineNeverHidesTheTable() async throws {
        let host = H.Host(text: H.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: {
            var c = MarkdownEditorConfiguration.default
            c.readingWidth = 700
            c.textInsets = TextInsets(horizontal: 24, vertical: 0)
            return c
        }()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        let coordinator = try #require(textView.delegate as? NativeTextViewCoordinator)
        let overlay = try #require(textView.wideTableOverlays.values.first)
        try #require(!overlay.isHidden)
        let anchorBefore = overlay.anchorTextLocation

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        // Read before the next turn: that is when the reconcile used to re-show it.
        #expect(overlay.anchorTextLocation > anchorBefore, "the underline did not move the table")
        #expect(!overlay.isHidden, "⌘A ⌘U hid the table until the next turn")
        await settle()

        textView.undoManager?.undo()
        #expect(!overlay.isHidden, "Undo hid the table until the next turn")
        await settle()
        #expect(!overlay.isHidden)
        #expect(overlay.anchorTextLocation == anchorBefore)
    }
}
