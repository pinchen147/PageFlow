//
//  TrafficLightsView.swift
//  PageFlow
//
//  Custom traffic lights that appear on hover
//

import SwiftUI

struct TrafficLightsView: View {
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: DesignTokens.trafficLightSpacing) {
                trafficLight(color: .red, action: closeWindow)
                trafficLight(color: .yellow, action: minimizeWindow)
                trafficLight(color: .green, action: maximizeWindow)
            }
            .padding(DesignTokens.trafficLightContainerPadding)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                    .allowsHitTesting(false)
            )
            .cornerRadius(DesignTokens.floatingToolbarCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .strokeBorder(.white.opacity(0.22))
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            .opacity(isHovering ? 1 : 0)
        }
        .frame(height: DesignTokens.trafficLightHotspotHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
            case .ended:
                isHovering = false
            }
        }
    }

    private func trafficLight(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: DesignTokens.trafficLightSize, height: DesignTokens.trafficLightSize)
        }
        .buttonStyle(.plain)
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }

    private func minimizeWindow() {
        NSApplication.shared.keyWindow?.miniaturize(nil)
    }

    private func maximizeWindow() {
        NSApplication.shared.keyWindow?.zoom(nil)
    }
}
