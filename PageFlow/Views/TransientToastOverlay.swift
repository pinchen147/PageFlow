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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, DesignTokens.spacingMD)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: message)
        .allowsHitTesting(false)
        .onChange(of: tabManager.transientToast) { _, toast in
            guard let toast, !toast.message.isEmpty else { return }
            show(toast.message)
        }
    }

    private func show(_ text: String) {
        dismissWorkItem?.cancel()
        message = text
        let workItem = DispatchWorkItem { message = nil }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
}
