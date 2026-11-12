//
//  PanelTransition.swift
//  PageFlow
//
//  How the floating panels come and go: sidebars, comments, Find and the
//  toast slide in from their edge as they fade, or only fade with Reduce Motion.
//

import SwiftUI

extension View {
    /// The insertion and removal transition for a panel attached to `edge`:
    /// slides and fades, or, when Reduce Motion is on, only fades.
    func pageFlowPanelTransition(edge: Edge) -> some View {
        modifier(PanelTransitionModifier(edge: edge))
    }
}

private struct PanelTransitionModifier: ViewModifier {
    let edge: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(PanelTransitionModifier.transition(edge: edge, reduceMotion: reduceMotion))
    }

    static func transition(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}
