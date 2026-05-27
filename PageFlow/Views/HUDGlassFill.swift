//
//  HUDGlassFill.swift
//  PageFlow
//
//  AppKit-backed fallback fill for shared Liquid Glass surfaces. On macOS 26
//  the bridge uses NSGlassEffectView; on older releases it preserves the
//  darker NSVisualEffectView(.hudWindow) look PageFlow already shipped.
//

import SwiftUI
import AppKit

struct HUDGlassFill: NSViewRepresentable {
    var cornerRadius: CGFloat = DesignTokens.floatingToolbarCornerRadius
    var tint: PageFlowGlassTint = .dark
    /// Tint opacity applied over the blur (md-preview uses 0.12). The base
    /// color is the same dark gray used by DesignTokens.floatingToolbarBase.
    var tintOpacity: CGFloat = 0.12

    func makeNSView(context: Context) -> HUDGlassFillView {
        let view = HUDGlassFillView()
        view.apply(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity)
        return view
    }

    func updateNSView(_ nsView: HUDGlassFillView, context: Context) {
        nsView.apply(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity)
    }
}

final class HUDGlassFillView: NSView {
    private let backdrop: NSView
    private let glassBackdrop: AnyObject?
    private let visualBackdrop: NSVisualEffectView?
    private let tintOverlay: NSView?
    private var currentCornerRadius: CGFloat?
    private var currentVariant: PageFlowGlassVariant?
    private var currentTint: PageFlowGlassTint?
    private var currentTintOpacity: CGFloat?

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            backdrop = glass
            glassBackdrop = glass
            visualBackdrop = nil
            tintOverlay = nil
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            backdrop = blur
            glassBackdrop = nil
            visualBackdrop = blur
            tintOverlay = NSView()
        }

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // The shadow is left to the SwiftUI side so callers can match
        // md-preview's lifted-up shadow (y:-3) without us baking it in.

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        var constraints = [
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]

        if let tintOverlay {
            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            addSubview(tintOverlay)
            constraints += [
                tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                tintOverlay.topAnchor.constraint(equalTo: topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Click-through: the visual fill must never swallow events from the
    // SwiftUI content layered on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        cornerRadius: CGFloat,
        tint: PageFlowGlassTint,
        tintOpacity: CGFloat,
        variant: PageFlowGlassVariant = .regular
    ) {
        if currentCornerRadius != cornerRadius {
            layer?.cornerRadius = cornerRadius
            if #available(macOS 26.0, *),
               let glassBackdrop = glassBackdrop as? NSGlassEffectView {
                glassBackdrop.cornerRadius = cornerRadius
            }
            currentCornerRadius = cornerRadius
        }

        if currentVariant != variant {
            if #available(macOS 26.0, *),
               let glassBackdrop = glassBackdrop as? NSGlassEffectView {
                glassBackdrop.style = variant == .clear ? .clear : .regular
            }
            currentVariant = variant
        }

        if currentTint != tint || currentTintOpacity != tintOpacity {
            let tintColor = tint.nsColor(opacity: tintOpacity)
            visualBackdrop?.material = tint == .light ? .popover : .hudWindow
            if #available(macOS 26.0, *),
               let glassBackdrop = glassBackdrop as? NSGlassEffectView {
                glassBackdrop.tintColor = tintColor
            }
            tintOverlay?.layer?.backgroundColor = tintColor.cgColor
            currentTint = tint
            currentTintOpacity = tintOpacity
        }
    }
}
