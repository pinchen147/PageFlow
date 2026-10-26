import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table edit reservation repro", .serialized)
struct TableEditReservationRepro {

    private final class State { var text: String; init(_ t: String) { text = t } }

    static let doc = """
    # 结论

    结论: 该报告在数据处理深度与不确定度闭环方面显著优于参照组.

    | 方法 | n | R (Ohm) | qphi_b (eV) | A (A cm^-2 K^-2) |
    | --- | --- | --- | --- | --- |
    | dV/dI 线性 | 1.398 | 1775 | -- | -- |
    | V-I 非线性 (3 参数) | 1.2913 +/- 0.0021 | 0.48 +/- 0.12 | 0.674 +/- 0.008 | -- |

    ## 附录

    一个窄表格:
    """

    private func makeEditor(text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let state = State(text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 700
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 748, height: 600))
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        textView.configuration = configuration
        coordinator.configuration = configuration
        textView.baseFont = NSFont.systemFont(ofSize: 16)
        textView.isEditable = true
        let bridge = LayoutBridge(textView.textLayoutManager!)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge
        textView.string = text
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        textView.textLayoutManager!.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return (coordinator, textView)
    }

    private func spinOnce() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func pump(_ times: Int = 6) async {
        for _ in 0..<times {
            spinOnce()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func reservationViolations(in textView: NativeTextView) -> [String] {
        guard let storage = textView.textStorage else { return ["no storage"] }
        var violations: [String] = []
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.renderedBlockImage, in: full, options: []) { value, range, _ in
            guard let image = value as? NSImage,
                  storage.attribute(.latexIsBlock, at: range.location, effectiveRange: nil) as? Bool == true,
                  storage.attribute(.latexBlockOffsetY, at: range.location, effectiveRange: nil) == nil
            else { return }
            let needed: CGFloat
            if let total = storage.attribute(.scrollableBlockTotalHeight, at: range.location, effectiveRange: nil) as? CGFloat {
                needed = total
            } else {
                needed = image.size.height
            }
            let para = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            let style = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            let reserved = style?.minimumLineHeight ?? 0
            if reserved + 0.5 < needed {
                violations.append("anchor@\(range.location): reserved \(reserved) < needed \(needed)")
            }
        }
        return violations
    }

    @Test("typing above the table keeps the reservation")
    func typingAboveKeepsReservation() async {
        let (_, textView) = makeEditor(text: Self.doc)
        #expect(reservationViolations(in: textView).isEmpty, "baseline must hold")

        let ns = textView.string as NSString
        let loc = ns.range(of: "显著").location
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: loc, length: 0))
        await pump()
        print("REPRO after typing: \(reservationViolations(in: textView))")
        #expect(reservationViolations(in: textView).isEmpty)
    }

    @Test("select-all underline keeps the reservation")
    func selectAllUnderlineKeepsReservation() async {
        let (coordinator, textView) = makeEditor(text: Self.doc)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        coordinator.didMarkdownUnderline(nil)
        await pump()
        print("REPRO after cmdA-cmdU: \(reservationViolations(in: textView))")
        print("REPRO text head: \(String(textView.string.prefix(120)))")
        #expect(reservationViolations(in: textView).isEmpty)
    }
}
