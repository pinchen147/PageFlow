//
//  FitEngine.swift
//  PageFlow
//
//  Pure, display-mode-aware "fit to view" scale calculation.
//

import CoreGraphics
import PDFKit

/// The single source of the fit-to-view formula.
///
/// `FitEngine` is intentionally pure: `scale(for:)` depends only on its
/// `FitInputs` snapshot, never on a live `PDFView`. Callers gather the live
/// geometry into `FitInputs`, call `scale(for:)`, then apply the result
/// (adding any zoom bump and clamping to the allowed range). Keeping the
/// formula here makes the four display-mode branches deterministic and
/// unit-testable without AppKit or a rendered view.
enum FitEngine {
    /// A geometry snapshot sufficient to compute a fit scale.
    struct FitInputs: Equatable {
        var viewWidth: CGFloat
        var viewHeight: CGFloat
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var displayMode: PDFDisplayMode
        var padding: CGFloat
        var twoPageGap: CGFloat
    }

    /// The fit-to-view scale for the given inputs.
    ///
    /// Returns `1.0` when the geometry is not yet valid (non-positive view or
    /// page dimensions), matching the behaviour callers relied on while the
    /// view was still laying out.
    static func scale(for inputs: FitInputs) -> CGFloat {
        guard inputs.viewWidth > 0, inputs.viewHeight > 0 else { return 1.0 }
        guard inputs.pageWidth > 0, inputs.pageHeight > 0 else { return 1.0 }

        let availableWidth = inputs.viewWidth - inputs.padding
        let availableHeight = inputs.viewHeight - inputs.padding

        switch inputs.displayMode {
        case .singlePage:
            let widthScale = availableWidth / inputs.pageWidth
            let heightScale = availableHeight / inputs.pageHeight
            return min(widthScale, heightScale)

        case .singlePageContinuous:
            return availableWidth / inputs.pageWidth

        case .twoUp:
            let twoPageWidth = inputs.pageWidth * 2 + inputs.twoPageGap
            let widthScale = availableWidth / twoPageWidth
            let heightScale = availableHeight / inputs.pageHeight
            return min(widthScale, heightScale)

        case .twoUpContinuous:
            let twoPageWidth = inputs.pageWidth * 2 + inputs.twoPageGap
            return availableWidth / twoPageWidth

        @unknown default:
            return availableWidth / inputs.pageWidth
        }
    }
}
