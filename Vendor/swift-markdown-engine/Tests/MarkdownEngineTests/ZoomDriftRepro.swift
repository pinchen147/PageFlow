//
//  ZoomDriftRepro.swift  (diagnostic — field bug: "view jumps right after zoom")
//
//  Measures the document point under the viewport CENTER across a ⌘+ zoom
//  (projectMagnification anchors at the viewport center, so that doc point
//  must be invariant) and across the debounced settle. Any post-settle delta
//  IS the field jump. PageFlow-realistic config: contentInsets.top = 90.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine
#if canImport(MarkdownEngineMermaid)
import MarkdownEngineMermaid
#endif

@MainActor
@Suite("Zoom drift repro", .serialized)
struct ZoomDriftRepro {

    final class Host { var text: String; init(_ t: String) { text = t } }

    final class StubDiagramRenderer: BlockDiagramRenderer, @unchecked Sendable {
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
            render(source: source, language: language, maxWidth: maxWidth,
                   fontSize: fontSize, theme: theme, pixelScale: 2)
        }
        func render(source: String, language: String, maxWidth: CGFloat,
                    fontSize: CGFloat, theme: MarkdownEditorTheme,
                    pixelScale: CGFloat) -> DiagramRenderResult? {
            let w = min(900, maxWidth)
            return DiagramRenderResult(image: NSImage(size: NSSize(width: w, height: 300)),
                                       size: CGSize(width: w, height: 300))
        }
    }

    struct Harness: View {
        let host: Host
        let diagram: StubDiagramRenderer
        var magnification: CGFloat
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: 24, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    #if canImport(MarkdownEngineMermaid)
                    c.services.diagram = MermaidBridge()   // REAL renderer: app parity
                    #else
                    c.services.diagram = diagram
                    #endif
                    return c
                }(),
                fontSize: 16,
                documentId: "zoom-drift",
                isEditable: true,
                magnificationRange: 0.5...4.0,
                magnification: magnification
            )
        }
    }

    private static let tallDoc: String = {
        var s = "# Top\n\n"
        for i in 0..<40 {
            s += "Paragraph \(i) 报告在联合非线性拟合部分明确说明, with body text so each one occupies a couple of wrapped lines 篇幅主要被预习报告、实验记录和数据截图占据 at sixteen points.\n\n"
        }
        s += """
        ```mermaid
        flowchart TB
          A[Observed price of X] --> B{DECOMPOSE}
          B --> C[Material floor]
          B --> D[Transformation cost]
          B --> E[Margin stack]
          C --> F[Commodity index]
          D --> G[Labor + energy]
          E --> H[Brand premium]
          F --> I[Final estimate]
          G --> I
          H --> I
        ```

        """
        for t in 0..<3 {
            s += "| 报告 \(t) | 图数 | 自制图 | 仪器截图 | 坐标轴标注 | 误差棒 | 图注信息量 |\n| --- | --- | --- | --- | --- | --- | --- |\n| report.pdf | 5 | 5 | 0 | 完整, 含单位 | Arrhenius 图有 | 高: 含拟合参数和物理含义 |\n| ref 3 | 7 | 5 | 2 (图3 为软件截图) | 完整 | 无 | 中 |\n\n"
        }
        for i in 40..<80 {
            s += "Paragraph \(i) 这三道题的回答展示了对实验操作背后物理原因的理解, so each one occupies a couple of wrapped lines at sixteen points.\n\n"
        }
        return s
    }()

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds { spin(); await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func settlePastRefitDebounce() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        await settle()
    }
    private func findScroll(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(in: sub) { return s } }
        return nil
    }

    @Test("the doc point under the viewport center survives a ⌘+ zoom AND its settle")
    func postSettleDrift() async throws {
        _ = NSApplication.shared
        let host = Host(Self.tallDoc)
        let diagram = StubDiagramRenderer()
        let hosting = NSHostingView(rootView: Harness(host: host, diagram: diagram, magnification: 1.0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }

        let scroll = try #require(findScroll(in: hosting))
        let textView = try #require(scroll.nativeTextView)

        // Park the viewport over the mermaid region (mid-document).
        let ns = host.text as NSString
        let mermaidLoc = ns.range(of: "flowchart").location
        revealWideTable(textView, needle: "flowchart")
        await settlePastRefitDebounce()   // let the initial mount settle fully
        _ = mermaidLoc

        func centerDocY() -> CGFloat { scroll.contentView.bounds.midY }
        let before = centerDocY()

        // ⌘+ through the real wrapper (projectMagnification anchors the CENTER).
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 1.25)
        hosting.layoutSubtreeIfNeeded()
        spin(); spin()   // zoom applied, settle debounce still pending
        let afterZoom = centerDocY()
        print("DRIFT-REPRO before=\(before) afterZoom=\(afterZoom) (zoom-anchor delta=\(afterZoom - before))")

        await settlePastRefitDebounce()
        let afterSettle = centerDocY()
        print("DRIFT-REPRO afterSettle=\(afterSettle) (SETTLE delta=\(afterSettle - afterZoom))")

        #expect(abs(afterSettle - afterZoom) < 2,
                "the settle must not move the view — this delta IS the field jump")

        // Second step ⌘+ again (bucket crossing differs) — same invariant.
        hosting.rootView = Harness(host: host, diagram: diagram, magnification: 1.5625)
        hosting.layoutSubtreeIfNeeded()
        spin(); spin()
        let afterZoom2 = centerDocY()
        await settlePastRefitDebounce()
        let afterSettle2 = centerDocY()
        print("DRIFT-REPRO step2 afterZoom=\(afterZoom2) afterSettle=\(afterSettle2) (delta=\(afterSettle2 - afterZoom2))")
        #expect(abs(afterSettle2 - afterZoom2) < 2)

        // No post-settle IDLE CRAWL: the field logs showed +20…+90pt drifts at
        // STEADY magnification long after the settle — TextKit 2 estimate debt
        // paying itself back. The settle's full-document layout must leave
        // nothing to revise.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await settle()
        let afterIdle = centerDocY()
        print("DRIFT-REPRO idle=\(afterIdle) (idle delta=\(afterIdle - afterSettle2))")
        #expect(abs(afterIdle - afterSettle2) < 2, "no estimate-debt crawl after the settle")
    }

    @Test("an AppKit-side magnification mutation (elastic bounce) freezes frames and re-arms the settle")
    func valueBasedZoomDetection() async throws {
        _ = NSApplication.shared
        let host = Host(Self.tallDoc)
        let diagram = StubDiagramRenderer()
        let hosting = NSHostingView(rootView: Harness(host: host, diagram: diagram, magnification: 1.0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }

        let scroll = try #require(findScroll(in: hosting) as? ClampedScrollView)
        try? await Task.sleep(nanoseconds: 250_000_000)   // let the mount window close
        #expect(!scroll.isZoomInProgress)

        // Mutate magnification the way AppKit's bounce animation does — no
        // notification, no wrapper involvement — and nudge the clip bounds.
        scroll.magnification = 1.3
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x,
                                              y: scroll.contentView.bounds.origin.y + 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin()
        #expect(scroll.isZoomInProgress,
                "a value-only magnification mutation must open the freeze window")
    }
}
