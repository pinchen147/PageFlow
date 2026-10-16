//
//  TableResizeThresholdTests.swift
//  MarkdownEngineTests
//
//  WINDOW RESIZE crossing the wide↔narrow threshold, in PageFlow's ACTUAL
//  full-width mode (readingWidth == nil, textInsets 24, safe-area top 90).
//  A table renders as a floating WideTableOverlay only while
//  image.width > containerWidth; widening the window past the image's
//  natural width must flip it to a plain inline image (overlay destroyed),
//  and narrowing back must re-create the overlay. This suite drives
//  window.setContentSize through the real pipeline and checks, at every
//  step, that (a) overlays sit on their reserved bands (overlapViolations)
//  and (b) the styled mode agrees with the current geometry — a stale
//  overlay surviving the wide→narrow flip, or a clipped inline image with
//  no overlay after the narrow→wide flip, is the bug.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table overlay resize threshold", .serialized)
struct TableResizeThresholdTests {

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
                documentId: "resize-threshold",
                isEditable: true
            )
        }
    }

    // MARK: - Settling

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

    /// Band oracle copied from TableFullWidthModeTests: every overlay must sit
    /// between the paragraph above and the paragraph below its anchor band.
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

    /// The wide 5-column table's anchor line (first char of the table carries
    /// `.renderedBlockImage` in both collapsed modes). Returns nil while the table is
    /// ACTIVE (caret inside → raw source, no image).
    private func probeWideTable(_ textView: NativeTextView) -> (imageWidth: CGFloat, sourceID: Int?)? {
        guard let storage = textView.textStorage else { return nil }
        let ns = storage.string as NSString
        let marker = ns.range(of: "| 方法 |")
        guard marker.location != NSNotFound else { return nil }
        let para = ns.paragraphRange(for: NSRange(location: marker.location, length: 0))
        var result: (CGFloat, Int?)?
        storage.enumerateAttribute(.renderedBlockImage, in: para, options: []) { value, attrRange, stop in
            guard let image = value as? NSImage else { return }
            let sourceID = storage.attribute(.scrollableBlockSourceID, at: attrRange.location, effectiveRange: nil) as? Int
            result = (image.size.width, sourceID)
            stop.pointee = true
        }
        return result.map { (imageWidth: $0.0, sourceID: $0.1) }
    }

    /// Threshold oracle: styled mode (inline vs overlay) must agree with the
    /// CURRENT container width, the overlay dictionary must mirror the
    /// attributed tables 1:1, and a live overlay must span the container.
    private func thresholdViolations(_ textView: NativeTextView, tableActive: Bool = false) -> [String] {
        var v = overlapViolations(textView: textView)
        guard let container = textView.layoutBridge?.firstTextContainer else { return v + ["no container"] }
        let containerWidth = container.size.width

        // Overlays exist only inside the laid-out viewport band — count only
        // the wide-styled tables whose anchor is in the band.
        var idsInStorage = Set<Int>()
        if let storage = textView.textStorage, let band = textView.viewportCharacterRange {
            storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, _ in
                if let id = value as? Int, NSLocationInRange(attrRange.location, band) { idsInStorage.insert(id) }
            }
        }
        if textView.wideTableOverlays.count != idsInStorage.count {
            v.append("overlay count \(textView.wideTableOverlays.count) != wide-styled tables \(idsInStorage.count) (stale/missing overlay)")
        }

        let probe = probeWideTable(textView)
        if tableActive {
            if let probe { v.append("active table still rendered as image (w=\(probe.imageWidth), sourceID=\(String(describing: probe.sourceID)))") }
            return v
        }
        guard let probe else {
            v.append("inactive wide table has no rendered image (unstyled?)")
            return v
        }
        let expectedWide = probe.imageWidth > containerWidth + 0.5
        let styledWide = probe.sourceID != nil
        if expectedWide && !styledWide {
            v.append("STALE NARROW: image \(probe.imageWidth) > container \(containerWidth) but table is styled INLINE (clipped, no overlay)")
        }
        if !expectedWide && styledWide {
            v.append("STALE WIDE: image \(probe.imageWidth) <= container \(containerWidth) but table still overlay-styled")
        }
        if let id = probe.sourceID, let overlay = textView.wideTableOverlays[id],
           abs(overlay.frame.width - containerWidth) > 1.5 {
            v.append("overlay width \(overlay.frame.width) != container width \(containerWidth) (stale frame)")
        }
        return v
    }

    private func dumpState(_ tag: String, _ textView: NativeTextView) {
        let containerWidth = textView.layoutBridge?.firstTextContainer?.size.width ?? -1
        let probe = probeWideTable(textView)
        print("RESIZEREPRO [\(tag)] container=\(containerWidth) imageW=\(String(describing: probe?.imageWidth)) sourceID=\(String(describing: probe?.sourceID)) overlays=\(textView.wideTableOverlays.count) frames=\(textView.wideTableOverlays.map { ($0.key, $0.value.frame) })")
        print("RESIZEREPRO [\(tag)] violations=\(thresholdViolations(textView))")
    }

    // MARK: - Fixtures

    /// Field document (repro.md); falls back to the embedded copy when the
    /// /tmp fixture is absent.
    static let fieldDoc: String = {
        if let onDisk = try? String(
            contentsOf: URL(fileURLWithPath: "/tmp/pageflow-repro/repro.md"), encoding: .utf8
        ), !onDisk.isEmpty { return onDisk }
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

    private func mount(_ host: Host, width: CGFloat = 760) async throws -> (NSWindow, NSHostingView<Harness>, NativeTextView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let textView = try #require(findEditor(in: hosting))
        await settle()
        // Grids exist only inside the viewport band — the resize threshold is
        // being watched at the table, so keep it on screen.
        revealWideTable(textView)
        await settle()
        return (window, hosting, textView)
    }

    private func resize(_ window: NSWindow, _ hosting: NSHostingView<Harness>, to width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 900))
        hosting.layoutSubtreeIfNeeded()
    }

    private func typeAboveTable(_ textView: NativeTextView, _ s: String) {
        let ns = textView.string as NSString
        let loc = ns.range(of: "独特贡献").location
        guard loc != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.insertText(s, replacementRange: textView.selectedRange())
    }

    // MARK: - Tests

    @Test("MINIMAL: widen past the threshold, settle, narrow back — table must become an overlay again")
    func minimalNarrowToWideFlipMissed() async throws {
        let host = Host(Self.fieldDoc)
        let (window, hosting, textView) = try await mount(host, width: 760)   // wide: overlay exists
        defer { window.orderOut(nil) }

        resize(window, hosting, to: 1400)   // image 820 < container 1335 → flips to inline
        await settle()
        resize(window, hosting, to: 760)    // image 820 > container 695 → must flip back to overlay
        await settle()
        dumpState("minimal 760→1400→760", textView)
        #expect(thresholdViolations(textView).isEmpty,
                "table must be overlay-styled again once the container is narrower than the image")
    }

    @Test("settled resizes across the wide↔narrow threshold keep mode + overlay consistent")
    func settledThresholdRoundTrip() async throws {
        let host = Host(Self.fieldDoc)
        let (window, hosting, textView) = try await mount(host, width: 760)
        defer { window.orderOut(nil) }

        dumpState("mount 760", textView)
        #expect(thresholdViolations(textView).isEmpty, "baseline at 760 must be clean")

        // Cross to NARROW: widen past the table image's natural width.
        resize(window, hosting, to: 1400)
        await settle()
        dumpState("760→1400 settled", textView)
        #expect(thresholdViolations(textView).isEmpty, "wide→narrow flip at 1400")

        // Edit while narrow (field: user types after resizing).
        typeAboveTable(textView, "编")
        await settle()
        dumpState("edit at 1400", textView)
        #expect(thresholdViolations(textView).isEmpty, "edit after widening")

        // Cross back to WIDE: shrink below the image width again.
        resize(window, hosting, to: 760)
        await settle()
        dumpState("1400→760 settled", textView)
        #expect(thresholdViolations(textView).isEmpty, "narrow→wide flip back at 760")

        // Edit after the flip back.
        typeAboveTable(textView, "辑")
        await settle()
        dumpState("edit at 760", textView)
        #expect(thresholdViolations(textView).isEmpty, "edit after narrowing back")

        // Two more crossings near the borderline.
        resize(window, hosting, to: 900)
        await settle()
        dumpState("760→900 settled", textView)
        #expect(thresholdViolations(textView).isEmpty, "borderline width 900")

        resize(window, hosting, to: 700)
        await settle()
        dumpState("900→700 settled", textView)
        #expect(thresholdViolations(textView).isEmpty, "back to 700")
    }

    @Test("fast resize burst (single spins) converges to a consistent state")
    func fastResizeBurst() async throws {
        let host = Host(Self.fieldDoc)
        let (window, hosting, textView) = try await mount(host, width: 760)
        defer { window.orderOut(nil) }

        // The field user drags the window edge faster than full settles: one
        // runloop spin between steps (spins do NOT drain DispatchQueue.main).
        for width in [1400.0, 760.0, 900.0, 700.0] {
            resize(window, hosting, to: width)
            spin()
            dumpState("burst @\(Int(width)) (1 spin)", textView)
        }
        typeAboveTable(textView, "快")
        spin()
        dumpState("burst edit (1 spin)", textView)

        await settle()
        dumpState("burst settled @700", textView)
        #expect(thresholdViolations(textView).isEmpty, "state must converge after the burst settles")

        typeAboveTable(textView, "速")
        await settle()
        dumpState("burst settled edit", textView)
        #expect(thresholdViolations(textView).isEmpty, "edit after the burst")
    }

    @Test("resizing across the threshold while the caret is inside the table")
    func resizeWhileTableActive() async throws {
        let host = Host(Self.fieldDoc)
        let (window, hosting, textView) = try await mount(host, width: 760)
        defer { window.orderOut(nil) }
        let ns = textView.string as NSString

        // Edit Table Source, then the caret INTO the table → raw source
        // (active), overlay must go. A plain caret would edit a cell instead.
        let cell = ns.range(of: "dV/dI 线性")
        let coordinator = try #require(textView.delegate as? NativeTextViewCoordinator)
        let table = try #require(coordinator.parsedDocument(for: textView.string).tokens.first {
            $0.kind == .table && NSLocationInRange(cell.location, $0.range)
        })
        coordinator.tableEditingSession.revealSource(of: table.range)
        textView.setSelectedRange(NSRange(location: cell.location + 2, length: 0))
        await settle()
        dumpState("active at 760", textView)
        #expect(thresholdViolations(textView, tableActive: true).isEmpty, "active table at 760")

        // Cross to narrow WHILE active, then leave the table.
        resize(window, hosting, to: 1400)
        await settle()
        dumpState("active 760→1400", textView)
        #expect(thresholdViolations(textView, tableActive: true).isEmpty, "active table across the flip")

        let out = ns.range(of: "独特贡献")
        textView.setSelectedRange(NSRange(location: out.location, length: 0))
        await settle()
        dumpState("deactivated at 1400", textView)
        #expect(thresholdViolations(textView).isEmpty, "deactivation after widening must style inline")

        // Caret back in, cross to wide with ONE spin, caret out fast.
        let cell2 = (textView.string as NSString).range(of: "dV/dI 线性")
        textView.setSelectedRange(NSRange(location: cell2.location + 2, length: 0))
        spin()
        resize(window, hosting, to: 760)
        spin()
        let out2 = (textView.string as NSString).range(of: "独特贡献")
        textView.setSelectedRange(NSRange(location: out2.location, length: 0))
        await settle()
        dumpState("fast deactivate at 760", textView)
        #expect(thresholdViolations(textView).isEmpty, "deactivation after narrowing must re-create the overlay")
    }
}
