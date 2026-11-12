//
//  TransientToastOverlay.swift
//  PageFlow
//
//  The ONE transient-message pill for a window — "Saved", "Save failed.",
//  "Couldn't open N files" — mounted once per window (TabContainerView), so
//  every content type shows the identical pill in the identical place and a
//  third surface can never need a third copy. Driven by a TYPED observable
//  event on the window's own `TabManager`, so multi-window scoping is
//  structural (each overlay observes only its own manager), not filtered.
//

import SwiftUI

/// One transient pill event. The `id` makes posting the SAME message twice a
/// distinct event (re-triggers the pill + its dismiss timer).
struct TransientToast: Equatable {
    let id: UUID
    let message: String
    /// How long it shows, in seconds.
    var duration: TimeInterval = 2
}

struct TransientToastOverlay: View {
    let tabManager: TabManager

    @State private var message: String?
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            if let message {
                Text(message)
                    .font(.caption)
                    .padding(.horizontal, DesignTokens.spacingMD)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassPanel(.glassPanel)
                    .pageFlowPanelTransition(edge: .bottom)
                    // Above the bottom strip, clear of the status chip and Find.
                    .padding(.bottom, TopChromeView.height(toolbarScale: SettingsManager.shared.toolbarScale)
                        + DesignTokens.spacingXS)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: message)
        .allowsHitTesting(false)
        .onChange(of: tabManager.transientToast) { _, toast in
            guard let toast else {
                dismissWorkItem?.cancel()
                message = nil
                return
            }
            guard !toast.message.isEmpty else { return }
            show(toast.message, for: toast.duration)
        }
    }

    private func show(_ text: String, for duration: TimeInterval) {
        dismissWorkItem?.cancel()
        message = text
        let workItem = DispatchWorkItem { message = nil }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}
