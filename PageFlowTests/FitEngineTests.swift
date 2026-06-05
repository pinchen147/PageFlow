//
//  FitEngineTests.swift
//  PageFlowTests
//

import CoreGraphics
import PDFKit
import Testing
@testable import PageFlow

struct FitEngineTests {
    // Shared geometry: 800x600 view, 400x500 (portrait) page, 20pt padding, 10pt gap.
    // Available area after padding: 780 x 580.
    private func inputs(
        viewWidth: CGFloat = 800,
        viewHeight: CGFloat = 600,
        pageWidth: CGFloat = 400,
        pageHeight: CGFloat = 500,
        displayMode: PDFDisplayMode,
        padding: CGFloat = 20,
        twoPageGap: CGFloat = 10
    ) -> FitEngine.FitInputs {
        FitEngine.FitInputs(
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            displayMode: displayMode,
            padding: padding,
            twoPageGap: twoPageGap
        )
    }

    @Test
    func singlePageUsesTheLimitingDimension() {
        // availW/pageW = 780/400 = 1.95 ; availH/pageH = 580/500 = 1.16 -> height limits.
        let scale = FitEngine.scale(for: inputs(displayMode: .singlePage))
        #expect(abs(scale - (580.0 / 500.0)) < 1e-9)
    }

    @Test
    func singlePageCanBeWidthLimited() {
        // Tall, narrow view: 400x900 ; page 400x500 ; pad 20 -> availW 380, availH 880.
        // 380/400 = 0.95 ; 880/500 = 1.76 -> width limits.
        let scale = FitEngine.scale(for: inputs(viewWidth: 400, viewHeight: 900, displayMode: .singlePage))
        #expect(abs(scale - (380.0 / 400.0)) < 1e-9)
    }

    @Test
    func singlePageContinuousFitsWidthOnly() {
        // Width ratio regardless of height: 780/400 = 1.95.
        let scale = FitEngine.scale(for: inputs(displayMode: .singlePageContinuous))
        #expect(abs(scale - (780.0 / 400.0)) < 1e-9)
    }

    @Test
    func twoUpUsesTheLimitingDimensionAcrossBothPages() {
        // twoPageWidth = 400*2 + 10 = 810 ; 780/810 = 0.96296.. ; 580/500 = 1.16 -> width limits.
        let scale = FitEngine.scale(for: inputs(displayMode: .twoUp))
        #expect(abs(scale - (780.0 / 810.0)) < 1e-9)
    }

    @Test
    func twoUpContinuousFitsTwoPageWidthOnly() {
        // twoPageWidth = 810 ; width ratio only: 780/810.
        let scale = FitEngine.scale(for: inputs(displayMode: .twoUpContinuous))
        #expect(abs(scale - (780.0 / 810.0)) < 1e-9)
    }

    @Test
    func paddingIsSubtractedFromBothAxes() {
        // Same page/view but zero padding -> width ratio uses full 800: 800/400 = 2.0.
        let padded = FitEngine.scale(for: inputs(displayMode: .singlePageContinuous, padding: 0))
        #expect(abs(padded - (800.0 / 400.0)) < 1e-9)
    }

    @Test
    func twoPageGapWidensTheTwoUpDenominator() {
        // Larger gap shrinks the fit scale: gap 60 -> twoPageWidth 860 -> 780/860.
        let scale = FitEngine.scale(for: inputs(displayMode: .twoUpContinuous, twoPageGap: 60))
        #expect(abs(scale - (780.0 / 860.0)) < 1e-9)
    }

    @Test
    func nonPositiveViewDimensionsReturnIdentityScale() {
        #expect(FitEngine.scale(for: inputs(viewWidth: 0, displayMode: .singlePage)) == 1.0)
        #expect(FitEngine.scale(for: inputs(viewHeight: 0, displayMode: .singlePageContinuous)) == 1.0)
    }

    @Test
    func nonPositivePageDimensionsReturnIdentityScale() {
        #expect(FitEngine.scale(for: inputs(pageWidth: 0, displayMode: .twoUp)) == 1.0)
        #expect(FitEngine.scale(for: inputs(pageHeight: 0, displayMode: .singlePage)) == 1.0)
    }
}
