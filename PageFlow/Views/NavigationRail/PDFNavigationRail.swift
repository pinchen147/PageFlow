import AppKit
import PDFKit
import Observation
import SwiftUI

struct PDFNavigationRail: NSViewRepresentable {
    let pdfManager: PDFManager
    let bookmarkManager: BookmarkManager
    let eligible: Bool
    let topInset: CGFloat
    let onShowSidebar: () -> Void

    func makeNSView(context: Context) -> NavigationRailView { NavigationRailView() }

    func updateNSView(_ rail: NavigationRailView, context: Context) {
        rail.onShowSidebar = onShowSidebar
        rail.makePreview = { [weak pdfManager, weak bookmarkManager, weak rail] target in
            guard let pdfManager, let bookmarkManager, case let .page(index) = target else { return nil }
            let position = ThumbnailRailPreviewPosition(pageIndex: index)
            rail?.updatePreview = { [weak position] target in
                guard case let .page(index) = target else { return }
                position?.pageIndex = index
            }
            return NSHostingView(rootView: ThumbnailRailPreview(pdfManager: pdfManager,
                bookmarkManager: bookmarkManager, position: position,
                onClose: { [weak rail] in _ = rail?.handleEscape() }))
        }
        let document = pdfManager.document
        rail.onActivate = { [weak pdfManager, weak document, weak rail] target, generation in
            guard let pdfManager, let document, let rail,
                  pdfManager.document === document, !pdfManager.suppressesNavigationRail,
                  rail.eligible, rail.generation == generation,
                  case let .page(index) = target, index >= 0, index < document.pageCount,
                  pdfManager.currentPageIndex != index || pdfManager.currentPage !== document.page(at: index) else { return }
            pdfManager.pushNavigationState()
            pdfManager.goToPage(index)
        }
        rail.configure(kind: .pdf, count: pdfManager.pageCount, visible: [pdfManager.currentPageIndex],
            identity: pdfManager.document.map(ObjectIdentifier.init) as AnyHashable,
            eligible: eligible && pdfManager.hasDocument, topInset: topInset)
    }

    static func dismantleNSView(_ rail: NavigationRailView, coordinator: ()) { rail.retire() }
}

@Observable
private final class ThumbnailRailPreviewPosition {
    var pageIndex: Int
    init(pageIndex: Int) { self.pageIndex = pageIndex }
}

private struct ThumbnailRailPreview: View {
    let pdfManager: PDFManager
    let bookmarkManager: BookmarkManager
    let position: ThumbnailRailPreviewPosition
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Pages").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close page preview")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            ThumbnailGridView(pdfManager: pdfManager, bookmarkManager: bookmarkManager, isEditing: false,
                presentation: .navigationPreview, previewPageIndex: position.pageIndex)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: 12).fill(.regularMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }
}
