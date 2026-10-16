//
//  PDFViewHost.swift
//  PageFlow
//
//  Keeps PDFKit out of interactive window resizing.
//

import AppKit

final class PDFViewHost: NSView {
    let pdfView: StablePDFView

    private var isFreezingPDFLayout = false
    private var isContentActive = true
    private var visibilityUpdateScheduled = false

    init(pdfView: StablePDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)

        pdfView.autoresizingMask = []
        addSubview(pdfView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override var preservesContentDuringLiveResize: Bool { true }

    /// Stop inactive-tab input immediately. Native hiding runs after the
    /// representable update because AppKit's key-view traversal can re-enter
    /// SwiftUI focus layout while updateNSView is projecting the warm set.
    func setContentActive(_ active: Bool) {
        isContentActive = active
        guard isHidden != !active, !visibilityUpdateScheduled else { return }
        visibilityUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityUpdateScheduled = false
            let shouldHide = !self.isContentActive
            if self.isHidden != shouldHide { self.isHidden = shouldHide }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isContentActive else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.viewerBackground.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()

        guard !isFreezingPDFLayout, pdfView.frame != bounds else { return }
        pdfView.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        guard inLiveResize else { return }
        invalidateExposedRegionsDuringLiveResize()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isFreezingPDFLayout = true
    }

    override func viewDidEndLiveResize() {
        isFreezingPDFLayout = false
        if pdfView.frame != bounds {
            pdfView.frame = bounds
            pdfView.needsDisplay = true
        }
        super.viewDidEndLiveResize()
    }

    private func invalidateExposedRegionsDuringLiveResize() {
        var exposedRects = [NSRect](repeating: .zero, count: 4)
        var exposedCount = 0

        exposedRects.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            getRectsExposedDuringLiveResize(baseAddress, count: &exposedCount)
        }

        for rect in exposedRects.prefix(exposedCount) {
            setNeedsDisplay(rect)
        }
    }
}
