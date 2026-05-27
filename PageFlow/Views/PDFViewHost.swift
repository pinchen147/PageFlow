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
