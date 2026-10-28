import AppKit
import Testing
@testable import PageFlow

@MainActor
@Suite("PDF rail compositing", .serialized)
struct PDFRailContrastTests {
    private func composite(_ rail: NavigationRailView, over paper: NSColor,
                           scale: Int) throws -> NSBitmapImageRep {
        let width = Int(rail.bounds.width) * scale
        let height = Int(rail.bounds.height) * scale
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        paper.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        rail.effectiveAppearance.performAsCurrentDrawingAppearance { rail.draw(rail.bounds) }
        context.flushGraphics()
        return bitmap
    }

    private func luminance(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: Int) throws -> Double {
        let color = try #require(bitmap.colorAt(x: Int(x * CGFloat(scale)), y: Int(y * CGFloat(scale)))?.usingColorSpace(.sRGB))
        func linear(_ value: CGFloat) -> Double {
            let component = Double(value)
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    @Test("Active and inactive PDF marks remain visible over light and dark paper in either appearance",
          arguments: [false, true], [1, 2])
    func readableMarks(dark: Bool, scale: Int) throws {
        let rail = NavigationRailView(frame: NSRect(x: 0, y: 0, width: 100, height: 180))
        rail.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        rail.configure(kind: .pdf, count: 3, visible: [0], identity: "contrast", eligible: true, topInset: 20)
        try #require(rail.geometry.marks.count == 3)
        for whitePaper in [false, true] {
            let paper: NSColor = whitePaper ? .white : .black
            let bitmap = try composite(rail, over: paper, scale: scale)
            for (index, mark) in rail.geometry.marks.enumerated() {
                // Samples lie inside the flat mark and in the gap below it, so
                // antialiased edges cannot disguise disappearing semantic ink.
                let ink = try luminance(bitmap, x: 16, y: mark.y, scale: scale)
                let background = try luminance(bitmap, x: 16, y: mark.y + 4, scale: scale)
                let contrast = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                #expect(contrast >= (index == 0 ? 3 : 1.3),
                        "Page mark \(index) disappeared: dark=\(dark), whitePaper=\(whitePaper), contrast=\(contrast)")
                let outside = try luminance(bitmap, x: 60, y: mark.y, scale: scale)
                #expect(abs(outside - (whitePaper ? 1 : 0)) < 0.01,
                        "Rail drawing must not recolor paper outside its existing lane")
            }
        }
    }
}
