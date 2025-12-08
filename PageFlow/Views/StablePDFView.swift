//
//  StablePDFView.swift
//  PageFlow
//
//  PDFView subclass that preserves vertical scroll position during horizontal resize.
//

import PDFKit
import AppKit

final class StablePDFView: PDFView {
    private var lastWidth: CGFloat = 0
    private let widthChangeTolerance: CGFloat = 0.5

    override func layout() {
        super.layout()

        // Remove content insets so scroll bar extends to top edge
        if let scrollView = documentScrollView {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.automaticallyAdjustsContentInsets = false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let widthChanged = lastWidth > 0 && abs(lastWidth - newSize.width) > widthChangeTolerance

        lastWidth = newSize.width
        super.setFrameSize(newSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let currentWidth = superview?.bounds.width ?? oldSize.width
        let widthChanged = abs(oldSize.width - currentWidth) > widthChangeTolerance

        super.resize(withOldSuperviewSize: oldSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    private func restoreVerticalScroll(_ y: CGFloat) {
        guard let scrollView = documentScrollView else { return }

        var origin = scrollView.contentView.bounds.origin
        origin.y = y
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var documentScrollView: NSScrollView? {
        subviews.first { $0 is NSScrollView } as? NSScrollView
    }
}
