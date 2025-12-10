//
//  GlassScroller.swift
//  PageFlow
//
//  Custom NSScroller with glassmorphism design matching TabItemView and TrafficLightsView.
//

import AppKit

class GlassScroller: NSScroller {
    
    override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.scrollerStyle = .overlay
        self.knobStyle = .default
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.scrollerStyle = .overlay
        self.knobStyle = .default
    }
    
    override func drawKnob() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        
        // Inset the knob slightly to make it look floating
        // Standard knob fills the width; we want a pill shape
        let knobRect = self.rect(for: .knob)
        let radius = min(knobRect.width, knobRect.height) / 2
        
        // 1. Shadow
        // Matches DesignTokens: color: .black.opacity(0.1), radius: 10, y: 5
        // Note: CoreGraphics Y axis is inverted relative to SwiftUI
        let shadowColor = CGColor(gray: 0, alpha: 0.1)
        context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: shadowColor)
        
        // Path construction
        let path = CGPath(roundedRect: knobRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        
        // 2. Fill
        // Matches DesignTokens.floatingToolbarBase (RGB 0.196, 0.196, 0.196)
        // Opacity needs to be high enough to be visible without blur (since we can't do live blur easily here)
        // We use 0.8 opacity to simulate the dark glass look
        context.setFillColor(red: 0.196, green: 0.196, blue: 0.196, alpha: 0.8)
        context.fillPath()
        
        // Restore state to draw border without shadow
        context.restoreGState()
        context.saveGState()
        
        // 3. Border
        // Matches DesignTokens: .white.opacity(0.22)
        context.addPath(path)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        context.setLineWidth(1.0)
        context.strokePath()
        
        context.restoreGState()
    }
}
