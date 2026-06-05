//
//  ProximityMagnification.swift
//  PageFlow
//
//  Dock-style proximity magnification. Elements inside a `proximityField()`
//  smoothly scale up as the cursor approaches their center, giving the glass
//  toolbar a responsive, "alive" feel instead of a binary hover state.
//
//  Usage:
//      HStack { … }
//          .proximityField()                 // declares the field
//      // and on each element inside it:
//      label.proximityMagnified()            // scales with cursor proximity
//
//  Honors Reduce Motion and is a no-op outside a `proximityField()`.
//

import SwiftUI

private enum Proximity {
    /// Coordinate space shared between the field and its magnified elements.
    static let space = "pageflow.proximityField"
    /// Peak scale of the element directly under the cursor.
    static let maxScale: CGFloat = 1.55
    /// Distance (pt) from an element's center at which magnification fades to zero.
    static let radius: CGFloat = 90
    /// Falloff curve exponent. >1 sharpens the peak so the hovered icon clearly
    /// dominates its neighbors instead of blending into a gentle gradient.
    static let sharpness: CGFloat = 2.4
    /// Ease applied only when the cursor leaves, so icons settle back smoothly.
    /// Active tracking is intentionally unanimated so it follows the cursor 1:1.
    static let settle = Animation.easeOut(duration: 0.16)
}

// MARK: - Environment

private struct ProximityCursorXKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Cursor X in the field's coordinate space, or `nil` when not hovering.
    fileprivate var proximityCursorX: CGFloat? {
        get { self[ProximityCursorXKey.self] }
        set { self[ProximityCursorXKey.self] = newValue }
    }
}

// MARK: - Public API

extension View {
    /// Declares a proximity field. Descendants marked with `proximityMagnified()`
    /// scale up as the cursor nears them. Pass `isEnabled: false` to suspend the
    /// effect without changing the view hierarchy (elements rest at scale 1).
    func proximityField(isEnabled: Bool = true) -> some View {
        modifier(ProximityFieldModifier(isEnabled: isEnabled))
    }

    /// Scales this view up as the cursor approaches its center, Dock-style.
    /// No effect outside a `proximityField()` or under Reduce Motion.
    func proximityMagnified() -> some View {
        modifier(ProximityMagnifiedModifier())
    }
}

// MARK: - Field

private struct ProximityFieldModifier: ViewModifier {
    let isEnabled: Bool
    @State private var cursorX: CGFloat?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(Proximity.space))
            .onContinuousHover(coordinateSpace: .named(Proximity.space)) { phase in
                switch phase {
                case .active(let location):
                    // Quantize to a 4pt grid so a smooth cursor sweep commits ~half
                    // as many environment writes; each write re-evaluates every
                    // magnified element, and the easing animation hides the coarser step.
                    cursorX = isEnabled ? (location.x / 4).rounded() * 4 : nil
                case .ended:
                    cursorX = nil
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { cursorX = nil }
            }
            .environment(\.proximityCursorX, cursorX)
    }
}

// MARK: - Element

private struct ProximityMagnifiedModifier: ViewModifier {
    @Environment(\.proximityCursorX) private var cursorX
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centerX: CGFloat?

    private var scale: CGFloat {
        guard !reduceMotion, let cursorX, let centerX else { return 1 }
        let falloff = max(0, 1 - abs(cursorX - centerX) / Proximity.radius)
        let peak = pow(falloff, Proximity.sharpness)
        return 1 + peak * (Proximity.maxScale - 1)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .background(
                GeometryReader { proxy in
                    // scaleEffect is render-only, so this reports the stable layout center.
                    Color.clear.onChange(
                        of: proxy.frame(in: .named(Proximity.space)).midX,
                        initial: true
                    ) { _, midX in
                        centerX = midX
                    }
                }
            )
            // No animation while tracking → instant follow; ease only on exit.
            .animation(cursorX == nil ? Proximity.settle : nil, value: scale)
    }
}
