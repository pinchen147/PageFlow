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
        let knobRect = rect(for: .knob)
        
        // Calculate corner radius for capsule shape (half of the shorter side)
        let radius = min(knobRect.width, knobRect.height) / 2
        let path = NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius)
        
        NSGraphicsContext.saveGraphicsState()
        
        // 1. Shadow
        // Matches DesignTokens: color: .black.opacity(0.1), radius: 10, y: 5
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
        shadow.shadowOffset = NSSize(width: 0, height: -5) // Downward shadow in standard coords
        shadow.shadowBlurRadius = 10
        shadow.set()
        
        // 2. Fill
        // Matches DesignTokens.floatingToolbarBase (RGB 0.196, 0.196, 0.196)
        let fillColor = NSColor(red: 0.196, green: 0.196, blue: 0.196, alpha: 0.8)
        fillColor.setFill()
        path.fill()
        
        NSGraphicsContext.restoreGraphicsState()
        
        // 3. Border
        // Matches DesignTokens: .white.opacity(0.22)
        let borderColor = NSColor(white: 1, alpha: 0.22)
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}
