//
//  TableFontZoomOverlayTests.swift
//  MarkdownEngineTests
//
//  LIVE FONT SIZE scenario: the app's pinch-zoom / ⌘± steps the wrapper's
//  fontSize prop. fontChanged forces a FULL rebuildTextStorageAndStyle in
//  updateNSView, which re-renders the wide-table image at the new size and
//  schedules an async overlay reconcile. This suite ramps fontSize
//  16→…→22→…→16 through the REAL wrapper (hosting.rootView reassignment)
//  at pinch speed (1-2 runloop spins between steps — reconciles queue up),
//  interleaves real insertText edits mid-zoom, and checks the overlay never
//  survives at the OLD size's position/image nor duplicates.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wide-table overlay live font zoom", .serialized)
struct TableFontZoomOverlayTests {

    final class Host {
        var text: String
        var fontSize: CGFloat = 16
        init(_ t: String) { text = t }
    }

    struct Harness: View {
        let host: Host
        // Stored VALUE property (not just read through the Host reference):
        // SwiftUI's rootView diff compares the Harness value memberwise; a
        // reference-typed Host compares identical across steps, which silently
        // short-circuits the whole update (verified — coordinator.fontSize
        // stayed 16 through a "ramp" until this property existed). The app's
        // wrapper receives fontSize as a value prop the same way.
        let fontSize: CGFloat
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    // PageFlow's ACTUAL full-width config (readingWidth == nil).
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: 24, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: fontSize,
                documentId: "fontzoom",
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

    /// Oracle copied from TableFullWidthModeTests + font-zoom-specific checks
    /// (stale image size, orphan/zombie/duplicate overlays).
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
            // Font-zoom specific: the overlay's IMAGE must be the one rendered
            // at the CURRENT font size, not the old size's leftover.
            if let naturalWidth = storage.attribute(.scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil) as? CGFloat,
               let imageView = overlay.documentView {
                if abs(imageView.frame.width - naturalWidth) > 0.5 {
                    violations.append("stale image: overlay image width \(imageView.frame.width) != natural width \(naturalWidth)")
                }
            }
            if let totalHeight = storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat {
                if abs(overlay.frame.height - totalHeight) > 1.0 {
                    violations.append("stale height: overlay height \(overlay.frame.height) != reserved \(totalHeight)")
                }
            }
        }
        return violations
    }

    /// Orphans (overlay in dict whose attr vanished), zombies (WideTableOverlay
    /// still in the view hierarchy but not in the dict), duplicates.
    private func integrityViolations(textView: NativeTextView, window: NSWindow) -> [String] {
        guard let storage = textView.textStorage else { return ["no storage"] }
        var violations: [String] = []
        var attrIDs: Set<Int> = []
        storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let id = value as? Int { attrIDs.insert(id) }
        }
        for id in textView.wideTableOverlays.keys where !attrIDs.contains(id) {
            violations.append("orphan overlay \(id): overlay exists but no storage attr")
        }
        func collect(_ view: NSView, into out: inout [WideTableOverlay]) {
            if let o = view as? WideTableOverlay { out.append(o) }
            for sub in view.subviews { collect(sub, into: &out) }
        }
        var inHierarchy: [WideTableOverlay] = []
        if let root = window.contentView { collect(root, into: &inHierarchy) }
        if inHierarchy.count != textView.wideTableOverlays.count {
            violations.append("duplicate/zombie: \(inHierarchy.count) overlays in hierarchy vs \(textView.wideTableOverlays.count) tracked")
        }
        return violations
    }

    private func allViolations(textView: NativeTextView, window: NSWindow) -> [String] {
        overlapViolations(textView: textView) + integrityViolations(textView: textView, window: window)
    }

    /// The user's ACTUAL document (repro.md as of the field report), with an
    /// inline fallback so the suite runs without /tmp state.
    static let fieldDoc: String = {
        if let s = try? String(contentsOf: URL(fileURLWithPath: "/tmp/pageflow-repro/repro.md"), encoding: .utf8),
           !s.isEmpty {
            return s
        }
        return Self.inlineFieldDoc
    }()

    static let inlineFieldDoc = """
    # 肖特基势垒实验报告综合评审 (四次评审)

    ## 评审范围

    纳入比较的 5 份学生实验报告:

    1. `report.pdf` (钟品晨, 2026)
    2. 肖特基势垒高度测量 reference 1/报告.pdf (张嘉骏, 2024)
    3. 肖特基势垒高度测量 reference 2/Schottky_Barrier.pdf (梁舟, 2024)

    ## 详细评审

    独特贡献:

    - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告.
    - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
    - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级 (~ 10 Ohm 到 ~ 5 x 10^4 Ohm), OLS 被高 1/I (低电流) 主导.

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

    private func mount(_ host: Host) async throws -> (NSHostingView<Harness>, NSWindow, NativeTextView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host, fontSize: host.fontSize))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let textView = try #require(findEditor(in: hosting))
        await settle()
        // Grids exist only inside the viewport band — every test in this file
        // zooms while looking at the table, so bring it on screen.
        reveal(textView)
        await settle()
        return (hosting, window, textView)
    }

    private func stepFont(_ host: Host, _ hosting: NSHostingView<Harness>, to size: CGFloat, spins: Int) {
        host.fontSize = size
        hosting.rootView = Harness(host: host, fontSize: size)
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<spins { spin() }
        // Reflow moves the table; keep it in the viewport band like a user
        // pinch-zooming the grid they are looking at.
        if let textView = findEditor(in: hosting) { reveal(textView) }
    }

    /// Scroll the wide table into the viewport band.
    private func reveal(_ textView: NativeTextView) {
        revealWideTable(textView)
    }

    // MARK: - 1. Slow zoom: every step fully settled must be violation-free.

    @Test("slow zoom: each fully-settled step keeps the overlay on its band")
    func slowZoomEachStepSettled() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        print("FONTZOOM-SLOW overlays after mount: \(textView.wideTableOverlays.count)")
        print("FONTZOOM-SLOW baseline: \(allViolations(textView: textView, window: window))")
        #expect(allViolations(textView: textView, window: window).isEmpty)

        for size in [17, 18, 19, 20, 21, 22, 21, 20, 19, 18, 17, 16].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 1)
            await settle()
            let v = allViolations(textView: textView, window: window)
            let applied = textView.baseFont.pointSize
            let coordSize = (textView.delegate as? NativeTextViewCoordinator)?.fontSize ?? -1
            let imageW = textView.wideTableOverlays.values.first?.documentView?.frame.width ?? -1
            print("FONTZOOM-SLOW settled @\(size): baseFont=\(applied) coord=\(coordSize) imageW=\(imageW) overlays=\(textView.wideTableOverlays.count) violations=\(v)")
            #expect(applied == size, "fontSize prop must actually reach the text view (anti-vacuity)")
            #expect(v.isEmpty, "settled font step to \(size) must not strand the overlay")
            #expect(textView.wideTableOverlays.count == 1, "field doc has exactly one wide table")
        }
    }

    // MARK: - 2. Fast pinch: 1-2 spins between steps, settle only at the end.

    @Test("fast pinch ramp: overlay heals by the time the gesture settles")
    func fastPinchRampSingleSpins() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        #expect(allViolations(textView: textView, window: window).isEmpty)

        // Up-ramp at pinch speed. Transient violations mid-ramp are expected
        // (reconcile is async by design) — print them, assert only after settle.
        for size in [17, 18, 19, 20, 21, 22].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 1)
            let v = allViolations(textView: textView, window: window)
            print("FONTZOOM-FAST transient @\(size): overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        }
        await settle()
        var settled = allViolations(textView: textView, window: window)
        print("FONTZOOM-FAST settled @22: overlays=\(textView.wideTableOverlays.count) violations=\(settled)")
        #expect(settled.isEmpty, "after the up-pinch settles the overlay must sit on its band")
        #expect(textView.wideTableOverlays.count == 1)

        // Down-ramp with 2 spins between steps.
        for size in [21, 20, 19, 18, 17, 16].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 2)
            let v = allViolations(textView: textView, window: window)
            print("FONTZOOM-FAST transient @\(size): overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        }
        await settle()
        settled = allViolations(textView: textView, window: window)
        print("FONTZOOM-FAST settled @16: overlays=\(textView.wideTableOverlays.count) violations=\(settled)")
        #expect(settled.isEmpty, "after the down-pinch settles the overlay must sit on its band")
        #expect(textView.wideTableOverlays.count == 1)
    }

    // MARK: - 3. Instant jump: zero spins between steps (fastest possible pinch).

    @Test("zero-spin ramp: coalesced font jumps still land the overlay correctly")
    func zeroSpinRamp() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        #expect(allViolations(textView: textView, window: window).isEmpty)

        for size in [17, 18, 19, 20, 21, 22].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 0)
        }
        await settle()
        var v = allViolations(textView: textView, window: window)
        print("FONTZOOM-ZERO settled @22: overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        #expect(v.isEmpty)

        for size in [20, 18, 16].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 0)
        }
        await settle()
        v = allViolations(textView: textView, window: window)
        print("FONTZOOM-ZERO settled @16: overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        #expect(v.isEmpty)
    }

    // MARK: - 4. Real edits interleaved mid-zoom (typing during a pinch).

    @Test("insertText mid-zoom: edits survive and the overlay stays on its band")
    func editsInterleavedMidZoom() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        #expect(allViolations(textView: textView, window: window).isEmpty)

        // Zoom up two steps at pinch speed…
        stepFont(host, hosting, to: 17, spins: 1)
        stepFont(host, hosting, to: 18, spins: 1)

        // …type in the paragraph above the wide table mid-gesture…
        let ns1 = textView.string as NSString
        let loc1 = ns1.range(of: "独特贡献").location
        try #require(loc1 != NSNotFound)
        textView.setSelectedRange(NSRange(location: loc1, length: 0))
        textView.insertText("甲", replacementRange: textView.selectedRange())
        spin()
        let containsEditBeforeNextStep = textView.string.contains("甲独特贡献")
        print("FONTZOOM-EDIT after insert@18 pre-step: contains edit = \(containsEditBeforeNextStep)")

        // …and keep zooming.
        stepFont(host, hosting, to: 19, spins: 1)
        stepFont(host, hosting, to: 20, spins: 1)
        let survivedUp = textView.string.contains("甲独特贡献")
        print("FONTZOOM-EDIT after zoom to 20: edit survived = \(survivedUp)")

        // Second edit on the way down, right below the table's following heading.
        let ns2 = textView.string as NSString
        let loc2 = ns2.range(of: "一个窄表格").location
        if loc2 != NSNotFound {
            textView.setSelectedRange(NSRange(location: loc2, length: 0))
            textView.insertText("乙", replacementRange: textView.selectedRange())
        }
        spin()
        stepFont(host, hosting, to: 18, spins: 1)
        stepFont(host, hosting, to: 16, spins: 1)
        let survivedDown = textView.string.contains("乙一个窄表格")

        await settle()
        let v = allViolations(textView: textView, window: window)
        print("FONTZOOM-EDIT settled @16: overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        print("FONTZOOM-EDIT text integrity: edit1 survived=\(textView.string.contains("甲独特贡献")) edit2 survived=\(survivedDown && textView.string.contains("乙一个窄表格"))")
        #expect(v.isEmpty, "edits mid-zoom must not strand the overlay")
        #expect(textView.wideTableOverlays.count == 1)
        // Honest probe: fontChanged rebuilds from the SwiftUI `text` prop, but the
        // binding sync is debounced 1s — does the zoom step revert live typing?
        #expect(textView.string.contains("甲独特贡献"), "insertText typed mid-zoom must survive the fontChanged rebuild")
        #expect(textView.string.contains("乙一个窄表格"), "second mid-zoom edit must survive the down-ramp")
    }

    // MARK: - 5. Wide↔narrow threshold crossing: zoom far enough DOWN that the
    // wide table fits the container (overlay must be DESTROYED), then back up
    // (must be RE-CREATED on the right band), all at pinch speed.

    @Test("threshold crossing: overlay destroyed on zoom-out, recreated on zoom-in")
    func wideNarrowThresholdCrossing() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        #expect(allViolations(textView: textView, window: window).isEmpty)
        try #require(textView.wideTableOverlays.count == 1)

        for size in [14, 12, 10, 9, 8, 7, 6].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 1)
            let v = allViolations(textView: textView, window: window)
            print("FONTZOOM-XING transient @\(size): overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        }
        await settle()
        var v = allViolations(textView: textView, window: window)
        let appliedDown = textView.baseFont.pointSize
        let naturalW = textView.wideTableOverlays.values.first?.documentView?.frame.width ?? -1
        print("FONTZOOM-XING settled @6: baseFont=\(appliedDown) tableNaturalW=\(naturalW) overlays=\(textView.wideTableOverlays.count) violations=\(v) (0 overlays = table fits inline now)")
        #expect(appliedDown == 6, "fontSize prop must actually reach the text view (anti-vacuity)")
        #expect(v.isEmpty, "zoomed-out state must not leave a stale grid over prose")

        for size in [8, 10, 12, 14, 16, 18, 20, 22].map(CGFloat.init) {
            stepFont(host, hosting, to: size, spins: 1)
            let vt = allViolations(textView: textView, window: window)
            print("FONTZOOM-XING transient @\(size): overlays=\(textView.wideTableOverlays.count) violations=\(vt)")
        }
        await settle()
        v = allViolations(textView: textView, window: window)
        print("FONTZOOM-XING settled @22: overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        #expect(v.isEmpty, "zoom back in must recreate the overlay on its band")
        #expect(textView.wideTableOverlays.count == 1, "wide table must regain its overlay at 22pt")
    }

    // MARK: - 6. Caret INSIDE the table during the zoom (active table shows raw
    // source, overlay removed) + a cell edit mid-zoom (changes the table's
    // sourceID hash), then caret out — overlay must come back keyed to the NEW
    // source, with no orphan of the OLD sourceID.

    @Test("caret in table + cell edit mid-zoom: overlay returns for the new source, no orphans")
    func caretInsideTableDuringZoom() async throws {
        let host = Host(Self.fieldDoc)
        let (hosting, window, textView) = try await mount(host)
        defer { window.orderOut(nil) }
        #expect(allViolations(textView: textView, window: window).isEmpty)
        try #require(textView.wideTableOverlays.count == 1)

        // Click into the wide table (caret inside → source mode, overlay drops).
        let ns = textView.string as NSString
        let cellLoc = ns.range(of: "1.398").location
        try #require(cellLoc != NSNotFound)
        textView.setSelectedRange(NSRange(location: cellLoc, length: 0))
        await settle()
        print("FONTZOOM-CARET inside table: overlays=\(textView.wideTableOverlays.count)")

        // Zoom while the caret is inside, pinch speed.
        stepFont(host, hosting, to: 18, spins: 1)
        stepFont(host, hosting, to: 20, spins: 1)

        // Type into the cell mid-zoom — the table SOURCE changes, so the
        // sourceID hash of this table changes. The caret in the table put the
        // keyboard in that cell's editor.
        let cellEditor = (window.firstResponder as? NSTextView) ?? textView
        cellEditor.insertText("9", replacementRange: cellEditor.selectedRange())
        // No spin — immediately keep zooming (fastest realistic interleave).
        stepFont(host, hosting, to: 22, spins: 1)

        // Caret out to the paragraph after the table, still mid-gesture.
        let outLoc = (textView.string as NSString).range(of: "一个窄表格").location
        try #require(outLoc != NSNotFound)
        textView.setSelectedRange(NSRange(location: outLoc, length: 0))
        stepFont(host, hosting, to: 21, spins: 1)

        await settle()
        let v = allViolations(textView: textView, window: window)
        print("FONTZOOM-CARET settled @21: overlays=\(textView.wideTableOverlays.count) violations=\(v)")
        print("FONTZOOM-CARET cell edit survived: \(textView.string.contains("91.398") || textView.string.contains("9 1.398"))")
        #expect(v.isEmpty, "caret-in-table zoom + cell edit must not orphan or misplace the overlay")
        #expect(textView.wideTableOverlays.count == 1, "the (edited) wide table must have exactly one overlay again")
        #expect(textView.string.contains("91.398"), "cell edit typed mid-zoom must survive")
    }
}
