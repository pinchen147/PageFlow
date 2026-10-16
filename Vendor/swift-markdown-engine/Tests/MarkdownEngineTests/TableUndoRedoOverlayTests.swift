//
//  TableUndoRedoOverlayTests.swift
//  MarkdownEngineTests
//
//  Undo/redo of formatting + typed edits in FULL-WIDTH mode (readingWidth ==
//  nil, the config PageFlow actually ships). The app routes editor undo into a
//  HOST-owned UndoManager (wrapper knob `undoManager:`); undo replays storage
//  mutations through NSTextView's undo machinery, which may bypass the restyle
//  triggers that reposition WideTableOverlays. Companion to
//  TableFullWidthModeTests (same Harness/oracle pattern).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table overlay undo/redo full-width mode", .serialized)
struct TableUndoRedoOverlayTests {

    final class Host {
        var text: String
        init(_ t: String) { text = t }
    }

    struct Harness: View {
        let host: Host
        let undo: UndoManager
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    // PageFlow's ACTUAL config since the margin slider: NO
                    // reading column; margins are text-container insets.
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: 24, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: 16,
                documentId: "undoredo",
                isEditable: true,
                undoManager: undo
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

    /// Oracle copied from TableFullWidthModeTests + an orphan-overlay check
    /// (an overlay whose sourceID no longer exists in storage after undo).
    private func overlapViolations(textView: NativeTextView) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let storage = textView.textStorage else { return ["no layout stack"] }
        var violations: [String] = []
        var seenIDs = Set<Int>()
        let ns = storage.string as NSString
        storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int else { return }
            seenIDs.insert(sourceID)
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
        for id in textView.wideTableOverlays.keys where !seenIDs.contains(id) {
            violations.append("orphan overlay \(id) (sourceID absent from storage)")
        }
        return violations
    }

    // MARK: - Mount plumbing

    struct Mounted {
        let window: NSWindow
        let hosting: NSHostingView<Harness>
        let textView: NativeTextView
        let host: Host
        let undo: UndoManager
    }

    private func mount(_ doc: String) async throws -> Mounted {
        let host = Host(doc)
        let undo = UndoManager()
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host, undo: undo))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        let textView = try #require(findEditor(in: hosting))
        await settle()
        return Mounted(window: window, hosting: hosting, textView: textView, host: host, undo: undo)
    }

    /// The user's ACTUAL document (repro.md as of the field report), with an
    /// inline equivalent fallback (CJK bullets + 5-col wide CJK table +
    /// following heading/paragraphs + narrow 2-col table).
    static let fieldDoc: String = {
        if let disk = try? String(
            contentsOf: URL(fileURLWithPath: "/tmp/pageflow-repro/repro.md"), encoding: .utf8
        ), !disk.isEmpty { return disk }
        return """
        # 肖特基势垒实验报告综合评审 (四次评审)

        ## 评审范围

        纳入比较的 5 份学生实验报告, 每份都经过独立复核并交叉对比.

        独特贡献:

        - Y_corr = ln(I/T^2) - q(V - IR)/(nkT) 修正形式, 将 n != 1 和 IR 压降一并纳入纵坐标, 斜率直接给出 qphi_b. 这是唯一使用此修正的报告.
        - 系统偏差的定量闭环: 预期偏差 qV(n-1)/n = 0.036 eV, 实际偏差 0.707 - 0.674 = 0.033 eV, 差值 0.003 eV < sigma = 0.013 eV.
        - 负 R 的因果解释: dV/dI vs 1/I 跨 4 个数量级, OLS 被高 1/I (低电流) 主导, 截距外推失真.

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

    @Test("select-all underline → undo → redo → undo (full settles)")
    func underlineAllUndoRedoSettled() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        let baselineCount = tv.wideTableOverlays.count
        print("UNDOREPRO settled/baseline overlays=\(baselineCount) violations=\(overlapViolations(textView: tv))")
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        // ⌘A + ⌘U through the real pipeline.
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        await settle()
        print("UNDOREPRO settled/after-underline overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        #expect(overlapViolations(textView: tv).isEmpty, "underline-all (already-passing scenario) must stay clean")

        m.undo.undo()
        await settle()
        print("UNDOREPRO settled/after-undo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        #expect(overlapViolations(textView: tv).isEmpty, "undo of underline-all must not strand overlays")
        #expect(tv.wideTableOverlays.count == baselineCount, "undo back to original text must restore overlay count")

        m.undo.redo()
        await settle()
        print("UNDOREPRO settled/after-redo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        #expect(overlapViolations(textView: tv).isEmpty, "redo of underline-all must not strand overlays")

        m.undo.undo()
        await settle()
        print("UNDOREPRO settled/after-second-undo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        #expect(overlapViolations(textView: tv).isEmpty, "second undo must not strand overlays")
        #expect(tv.wideTableOverlays.count == baselineCount)
    }

    @Test("select-all underline → undo → redo → undo (fast, 1-2 spins between steps)")
    func underlineAllUndoRedoFast() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        let baselineCount = tv.wideTableOverlays.count
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        spin(); spin()
        print("UNDOREPRO fast/after-underline overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")

        m.undo.undo()
        spin(); spin()
        print("UNDOREPRO fast/after-undo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        let transientAfterUndo = overlapViolations(textView: tv)

        m.undo.redo()
        spin(); spin()
        print("UNDOREPRO fast/after-redo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        let transientAfterRedo = overlapViolations(textView: tv)

        m.undo.undo()
        spin(); spin()
        print("UNDOREPRO fast/after-second-undo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        let transientAfterSecondUndo = overlapViolations(textView: tv)

        // Persistent state: the field bug survives idling.
        await settle()
        let persistent = overlapViolations(textView: tv)
        print("UNDOREPRO fast/PERSISTENT overlays=\(tv.wideTableOverlays.count) violations=\(persistent)")
        print("UNDOREPRO fast/TRANSIENTS undo=\(transientAfterUndo) redo=\(transientAfterRedo) undo2=\(transientAfterSecondUndo)")
        #expect(persistent.isEmpty, "fast undo/redo sequence must not leave overlays stranded after settle")
        #expect(tv.wideTableOverlays.count == baselineCount)
    }

    @Test("type 3 chars above the table, undo them one by one, then redo")
    func typingAboveUndoOneByOne() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        let baselineCount = tv.wideTableOverlays.count
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")

        // Real keystrokes in the paragraph above the wide table, coalescing
        // broken between them so each is its own undo group (typing pauses).
        let ns = tv.string as NSString
        let loc = ns.range(of: "独特贡献").location
        try #require(loc != NSNotFound)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        spin()
        for ch in ["编", "辑", "过"] {
            tv.insertText(ch, replacementRange: tv.selectedRange())
            tv.breakUndoCoalescing()
            spin()
        }
        await settle()
        print("UNDOREPRO typing/after-3-inserts overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        try #require(overlapViolations(textView: tv).isEmpty, "typing above (already-passing scenario) must stay clean")

        // Undo one by one, only single spins between (faster than a settle).
        var transients: [[String]] = []
        for step in 1...3 {
            m.undo.undo()
            spin()
            let v = overlapViolations(textView: tv)
            transients.append(v)
            print("UNDOREPRO typing/after-undo-\(step) overlays=\(tv.wideTableOverlays.count) violations=\(v)")
        }
        await settle()
        let persistentUndo = overlapViolations(textView: tv)
        print("UNDOREPRO typing/PERSISTENT-after-undos overlays=\(tv.wideTableOverlays.count) violations=\(persistentUndo) transients=\(transients)")
        #expect(persistentUndo.isEmpty, "undoing typed chars one by one must not strand overlays")
        #expect(tv.wideTableOverlays.count == baselineCount)

        // Redo them back fast.
        for step in 1...3 {
            m.undo.redo()
            spin()
            print("UNDOREPRO typing/after-redo-\(step) overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        }
        await settle()
        let persistentRedo = overlapViolations(textView: tv)
        print("UNDOREPRO typing/PERSISTENT-after-redos overlays=\(tv.wideTableOverlays.count) violations=\(persistentRedo)")
        #expect(persistentRedo.isEmpty, "redoing typed chars must not strand overlays")
    }

    @Test("edit inside a wide-table cell, leave, undo the cell edit from outside")
    func cellEditUndoFromOutside() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        let baselineCount = tv.wideTableOverlays.count
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")

        // Caret INTO the wide table's source (first data cell), type a char.
        let ns = tv.string as NSString
        let cell = ns.range(of: "dV/dI 线性")
        try #require(cell.location != NSNotFound, "wide-table cell text must exist")
        tv.setSelectedRange(NSRange(location: NSMaxRange(cell), length: 0))
        spin()
        tv.insertText("改", replacementRange: tv.selectedRange())
        tv.breakUndoCoalescing()
        spin(); spin()
        print("UNDOREPRO cell/after-cell-edit overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")

        // Leave the table: caret to a paragraph outside.
        let outside = (tv.string as NSString).range(of: "附录")
        try #require(outside.location != NSNotFound)
        tv.setSelectedRange(NSRange(location: outside.location, length: 0))
        spin()

        // Undo the cell edit from OUTSIDE the table, fast.
        m.undo.undo()
        spin(); spin()
        let transient = overlapViolations(textView: tv)
        print("UNDOREPRO cell/after-undo-fast overlays=\(tv.wideTableOverlays.count) violations=\(transient)")
        await settle()
        let persistent = overlapViolations(textView: tv)
        print("UNDOREPRO cell/PERSISTENT overlays=\(tv.wideTableOverlays.count) violations=\(persistent) transient=\(transient)")
        #expect(persistent.isEmpty, "undoing a cell edit from outside must not strand overlays")
        #expect(tv.wideTableOverlays.count == baselineCount)
        #expect((tv.string as NSString).range(of: "改").location == NSNotFound, "undo must actually revert the cell edit")

        // Redo it back from outside too.
        m.undo.redo()
        spin(); spin()
        print("UNDOREPRO cell/after-redo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        await settle()
        let persistentRedo = overlapViolations(textView: tv)
        print("UNDOREPRO cell/PERSISTENT-after-redo overlays=\(tv.wideTableOverlays.count) violations=\(persistentRedo)")
        #expect(persistentRedo.isEmpty, "redoing a cell edit from outside must not strand overlays")
    }

    @Test("interleaved: underline-all → undo → type inside the transient window → unwind")
    func undoThenTypeInsideTransientWindow() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        let baselineCount = tv.wideTableOverlays.count
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        spin()
        m.undo.undo()
        spin()
        // The overlay is stranded low right now (transient). Type BEFORE it heals.
        let loc = (tv.string as NSString).range(of: "独特贡献").location
        try #require(loc != NSNotFound)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.insertText("编", replacementRange: tv.selectedRange())
        tv.breakUndoCoalescing()
        spin()
        print("UNDOREPRO interleave/after-type-in-window overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        m.undo.undo() // undo the typed char
        spin()
        print("UNDOREPRO interleave/after-undo-type overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        await settle()
        let persistent = overlapViolations(textView: tv)
        print("UNDOREPRO interleave/PERSISTENT overlays=\(tv.wideTableOverlays.count) violations=\(persistent)")
        #expect(persistent.isEmpty, "typing inside the undo transient window must not strand overlays")
        #expect(tv.wideTableOverlays.count == baselineCount)
    }

    @Test("undo of underline-all with the caret parked inside the table")
    func undoWithCaretInsideTable() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        await settle()
        try #require(overlapViolations(textView: tv).isEmpty)

        let cell = (tv.string as NSString).range(of: "1775")
        try #require(cell.location != NSNotFound)
        tv.setSelectedRange(NSRange(location: cell.location, length: 0))
        spin()
        m.undo.undo()
        spin(); spin()
        let transient = overlapViolations(textView: tv)
        print("UNDOREPRO caret-in/after-undo-fast overlays=\(tv.wideTableOverlays.count) violations=\(transient)")
        await settle()
        let persistent = overlapViolations(textView: tv)
        print("UNDOREPRO caret-in/PERSISTENT overlays=\(tv.wideTableOverlays.count) violations=\(persistent) transient=\(transient)")
        #expect(persistent.isEmpty, "undo with caret inside the table must not strand overlays")
    }

    @Test("same-turn churn: undo+redo with no spin between, then undo")
    func undoRedoSameTurnChurn() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        spin()
        m.undo.undo()
        m.undo.redo() // same runloop turn — no spin between
        spin()
        print("UNDOREPRO churn/after-undo+redo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        m.undo.undo()
        spin()
        print("UNDOREPRO churn/after-final-undo overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        await settle()
        let persistent = overlapViolations(textView: tv)
        print("UNDOREPRO churn/PERSISTENT overlays=\(tv.wideTableOverlays.count) violations=\(persistent)")
        #expect(persistent.isEmpty, "same-turn undo/redo churn must not strand overlays")
    }

    @Test("undo then immediate window resize before the overlay fix lands")
    func undoThenImmediateResize() async throws {
        try #require(!Self.fieldDoc.isEmpty)
        let m = try await mount(Self.fieldDoc)
        defer { m.window.orderOut(nil) }
        let tv = m.textView
        try #require(overlapViolations(textView: tv).isEmpty, "baseline must be clean")
        let coordinator = try #require(tv.delegate as? NativeTextViewCoordinator)

        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        spin()
        coordinator.didMarkdownUnderline(nil)
        await settle()
        try #require(overlapViolations(textView: tv).isEmpty)

        m.undo.undo()
        // NO spin: resize in the same turn, before any overlay reconcile runs.
        m.window.setContentSize(NSSize(width: 900, height: 900))
        m.hosting.layoutSubtreeIfNeeded()
        spin(); spin()
        let transient = overlapViolations(textView: tv)
        print("UNDOREPRO resize/after-undo+resize overlays=\(tv.wideTableOverlays.count) violations=\(transient)")
        await settle()
        let persistentWide = overlapViolations(textView: tv)
        print("UNDOREPRO resize/PERSISTENT-900 overlays=\(tv.wideTableOverlays.count) violations=\(persistentWide) transient=\(transient)")
        #expect(persistentWide.isEmpty, "undo + immediate resize must not strand overlays")

        // Redo, then shrink back in the transient window.
        m.undo.redo()
        m.window.setContentSize(NSSize(width: 760, height: 900))
        m.hosting.layoutSubtreeIfNeeded()
        spin(); spin()
        print("UNDOREPRO resize/after-redo+shrink overlays=\(tv.wideTableOverlays.count) violations=\(overlapViolations(textView: tv))")
        await settle()
        let persistentBack = overlapViolations(textView: tv)
        print("UNDOREPRO resize/PERSISTENT-760 overlays=\(tv.wideTableOverlays.count) violations=\(persistentBack)")
        #expect(persistentBack.isEmpty, "redo + immediate shrink must not strand overlays")
    }
}
