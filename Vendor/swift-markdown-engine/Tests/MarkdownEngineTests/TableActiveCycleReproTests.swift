//
//  TableActiveCycleReproTests.swift
//  MarkdownEngineTests
//
//  Field-bug hunt: caret ENTERS the wide table (activates it — raw source,
//  overlay removed, reservation dropped, following text reflows UP), user
//  TYPES inside a cell, caret LEAVES (table re-renders, overlay recreated).
//  Cycled 3-5 times at varying speeds — including faster than the coalesced
//  DispatchQueue.main.async overlay reconcile can run — checking the
//  overlap oracle after every step.
//
//  Full-width mode (readingWidth == nil), exactly what PageFlow ships.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table active-cycle full-width repro", .serialized)
struct TableActiveCycleReproTests {

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
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: host.sideMargin, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: 16,
                documentId: "activecycle",
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

    // MARK: - Driving helpers (real pipeline)

    /// Real caret move: setSelectedRange (AppKit posts the selection
    /// notification to the delegate) + an explicit delivery to the
    /// coordinator, mirroring the field click. The explicit call is
    /// idempotent when AppKit already delivered.
    private func moveCaret(_ tv: NativeTextView, to location: Int) {
        tv.setSelectedRange(NSRange(location: location, length: 0))
        (tv.delegate as? NativeTextViewCoordinator)?.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: tv)
        )
    }

    private func loc(_ tv: NativeTextView, _ needle: String, offset: Int = 0) throws -> Int {
        let r = (tv.string as NSString).range(of: needle)
        try #require(r.location != NSNotFound, "needle missing: \(needle)")
        return r.location + offset
    }

    /// Type where the keyboard is: a caret in a table edits its cell.
    private func type(_ tv: NativeTextView, _ text: String) {
        let responder = (tv.window?.firstResponder as? NSTextView) ?? tv
        responder.insertText(text, replacementRange: responder.selectedRange())
    }

    /// The field document (repro.md), inlined so the test is hermetic.
    static let fieldDoc: String = {
        if let disk = try? String(contentsOf: URL(fileURLWithPath: "/tmp/pageflow-repro/repro.md"), encoding: .utf8), !disk.isEmpty {
            return disk
        }
        return """
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

        # 结论: 该报告在数据处理深度与不确定度闭环方面显著优于参照组.

        ## 附录

        一个窄表格:

        | A | B |
        | --- | --- |
        | 一 | 二 |
        | 三 | 四 |

        以及更多正文, 用于观察表格之后的排版是否正常. 这一段落足够长, 可以换行并检验读列宽度的表现是否与 Obsidian 的 readable line length 一致.
        """
    }()

    // MARK: - Tests

    @Test("enter→type-in-cell→leave cycles keep the overlay on its band")
    func activeCyclesKeepOverlayBand() async throws {
        let host = Host(Self.fieldDoc)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        // Grids exist only inside the viewport band — bring the table on
        // screen first (the cycles all edit inside it anyway).
        revealWideTable(textView)
        await settle()
        try #require(!textView.wideTableOverlays.isEmpty, "wide table must have an overlay at 760pt")
        var log: [String] = []
        func check(_ label: String) -> [String] {
            let v = overlapViolations(textView: textView)
            log.append("CYCREPRO [\(label)] overlays=\(textView.wideTableOverlays.count) violations=\(v)")
            print(log.last!)
            return v
        }
        _ = check("baseline")
        #expect(check("baseline-settled").isEmpty)

        // ── Cycle 1: slow (full settles), leave BELOW ──────────────────────
        moveCaret(textView, to: try loc(textView, "1775", offset: 2))     // inside cell
        await settle()
        _ = check("c1 enter")
        type(textView, "**")
        await settle()
        _ = check("c1 type **")
        type(textView, "重要")
        await settle()
        _ = check("c1 type 重要")
        moveCaret(textView, to: try loc(textView, "以及更多正文", offset: 3)) // paragraph below
        await settle()
        #expect(check("c1 leave below (settled)").isEmpty)

        // ── Cycle 2: fast (single spins), leave ABOVE ──────────────────────
        moveCaret(textView, to: try loc(textView, "0.674", offset: 1))
        spin()
        _ = check("c2 enter fast")
        type(textView, "**")
        spin()
        _ = check("c2 type ** fast")
        type(textView, "更")
        spin()
        _ = check("c2 type 更 fast")
        moveCaret(textView, to: try loc(textView, "独特贡献", offset: 1))   // paragraph above
        spin()
        _ = check("c2 leave above fast")
        await settle()
        #expect(check("c2 settled").isEmpty)

        // ── Cycle 3: leave then IMMEDIATELY type at new location, same spin ─
        moveCaret(textView, to: try loc(textView, "22 +/- 10", offset: 1))
        spin()
        _ = check("c3 enter")
        type(textView, "xx")
        spin()
        _ = check("c3 type xx")
        moveCaret(textView, to: try loc(textView, "这一段落", offset: 2))
        type(textView, "插入文字") // no spin between
        _ = check("c3 leave+type same spin")
        spin()
        _ = check("c3 one spin later")
        await settle()
        #expect(check("c3 settled").isEmpty)

        // ── Cycle 4: char-by-char typing in cell, 2 spins on exit, leave ABOVE
        moveCaret(textView, to: try loc(textView, "dV/dI 线性", offset: 6))
        spin()
        _ = check("c4 enter")
        for ch in ["*", "*", "加", "粗", "*", "*"] {
            type(textView, ch)
            spin()
        }
        _ = check("c4 typed **加粗**")
        moveCaret(textView, to: try loc(textView, "评分 rubric", offset: 1))
        spin(); spin()
        _ = check("c4 leave above 2 spins")
        await settle()
        #expect(check("c4 settled").isEmpty)

        // ── Cycle 5: rapid enter/leave toggling, no typing ─────────────────
        moveCaret(textView, to: try loc(textView, "非线性", offset: 1))
        spin()
        _ = check("c5 enter")
        moveCaret(textView, to: try loc(textView, "结论", offset: 1))       // heading below
        spin()
        _ = check("c5 leave below")
        moveCaret(textView, to: try loc(textView, "Arrhenius", offset: 2))
        spin()
        _ = check("c5 re-enter")
        moveCaret(textView, to: try loc(textView, "详细评审", offset: 1))    // heading above
        _ = check("c5 leave above no spin")
        await settle()
        #expect(check("c5 settled").isEmpty)

        // ── Cycle 6: a pipe and a line break typed in a cell stay cell text
        // (escaped pipe, <br>), so the table never splits ──────────────────
        moveCaret(textView, to: try loc(textView, "1.398", offset: 5))
        spin()
        _ = check("c6 enter")
        type(textView, " | 新列")
        spin()
        type(textView, "\n")
        spin()
        _ = check("c6 typed pipe and newline")
        #expect((textView.string as NSString).range(of: "1.398 \\| 新列<br>").location != NSNotFound)
        moveCaret(textView, to: try loc(textView, "独特贡献"))
        spin()
        _ = check("c6 leave above fast")
        await settle()
        #expect(check("c6 settled").isEmpty)

        // Final state.
        await settle()
        let final = check("final")
        #expect(final.isEmpty, "cycles must leave every overlay on its band")
        print("CYCREPRO ==== full log ====")
        log.forEach { print($0) }
    }

    @Test("ultra-fast cycle with zero spins between steps self-heals by settle")
    func ultraFastCycleNoSpins() async throws {
        let host = Host(Self.fieldDoc)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        revealWideTable(textView)
        await settle()
        try #require(!textView.wideTableOverlays.isEmpty)
        func check(_ label: String) -> [String] {
            let v = overlapViolations(textView: textView)
            print("CYCREPRO2 [\(label)] overlays=\(textView.wideTableOverlays.count) violations=\(v)")
            return v
        }
        _ = check("baseline")

        // Three enter→type→leave cycles with NO runloop service at all
        // between steps (everything lands in one main-queue turn, the way a
        // burst of real events can queue up faster than coalesced reconciles).
        for round in 1...3 {
            // offset 0 everywhere: inserted chars land BEFORE the needle, so
            // the needle survives for the next round.
            moveCaret(textView, to: try loc(textView, "0.707"))
            type(textView, "**")
            type(textView, "快")
            let out = round % 2 == 0 ? try loc(textView, "独特贡献")
                                     : try loc(textView, "以及更多正文")
            moveCaret(textView, to: out)
            type(textView, "尾")
            _ = check("round \(round) mid-turn")
        }
        _ = check("after burst, pre-settle")
        spin()
        _ = check("after burst, one spin")
        await settle()
        let settled = check("after burst, settled")
        #expect(settled.isEmpty, "burst cycles must settle with overlays on their bands")
        await settle()
        #expect(check("final").isEmpty)
    }
}
