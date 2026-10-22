//
//  ImageCropRenderTests.swift
//  MarkdownEngineTests
//
//  A crop draws only the kept part of the source image, the right way up, and
//  every image is clipped to 4 pt rounded corners (doc 26 §2.7, I4). The file
//  itself is never touched: the crop is a source rect at draw time.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image crop rendering", .serialized)
struct ImageCropRenderTests {
    /// `image` drawn by the fragment's helper into a transparent, flipped
    /// 40 × 40 bitmap, as TextKit hands the fragment a flipped context.
    private func drawn(crop: CGRect?, radius: CGFloat = 0) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmapContext = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let cg = bitmapContext.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: 40, height: 40))
        cg.translateBy(x: 0, y: 40)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        MarkdownTextLayoutFragment.drawBlockImage(TestImages.quadrants(), in: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                  crop: crop, cornerRadius: radius)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test("each quadrant crop draws only that quadrant's colour (the y flip)", arguments: [
        (CGRect(x: 0, y: 0, width: 0.5, height: 0.5), TestImages.topLeft),
        (CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), TestImages.topRight),
        (CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), TestImages.bottomLeft),
        (CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), TestImages.bottomRight),
    ])
    func quadrantCrop(_ crop: CGRect, _ expected: NSColor) throws {
        let rep = try drawn(crop: crop)
        for x in stride(from: 2, to: 38, by: 4) {
            for y in stride(from: 2, to: 38, by: 4) {
                #expect(TestImages.matches(rep.colorAt(x: x, y: y), expected), "pixel (\(x), \(y)): \(String(describing: rep.colorAt(x: x, y: y)))")
            }
        }
    }

    @Test("an uncropped image draws upright; corners are transparent within the 4 pt radius")
    func uprightAndRounded() throws {
        let plain = try drawn(crop: nil, radius: 4)
        #expect(TestImages.matches(plain.colorAt(x: 10, y: 10), TestImages.topLeft))
        #expect(TestImages.matches(plain.colorAt(x: 30, y: 30), TestImages.bottomRight))
        let cropped = try drawn(crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), radius: 4)
        for (x, y) in [(0, 0), (39, 0), (0, 39), (39, 39)] {
            #expect((cropped.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.05, "corner (\(x), \(y)) is clipped")
        }
        #expect(TestImages.matches(cropped.colorAt(x: 4, y: 4), TestImages.topLeft), "inside the radius is drawn")
    }

    @Test("in the editor, `crop=0,0,0.5,0.5` shows only the top-left quadrant")
    func editorDrawsTheCrop() async throws {
        let source = "Intro.\n\n![Q|crop=0,0,0.5,0.5|200](q.png)\n\n![Whole|200](q.png)\n\nEnd."
        let editor = try MountedImageEditor(source: source, images: ["q.png": TestImages.quadrants()])
        defer { editor.close() }
        await editor.settle()
        let origin = editor.main.textContainerOrigin

        let cropFrame = try editor.imageFrame(onLineOf: "![Q")
        #expect(abs(cropFrame.width - 200) < 0.01 && abs(cropFrame.height - 200) < 0.01)
        let cropped = try editor.snapshot(cropFrame.offsetBy(dx: origin.x, dy: origin.y))
        for fx in [0.2, 0.5, 0.8] {
            for fy in [0.2, 0.5, 0.8] {
                let color = cropped.colorAt(x: Int(fx * Double(cropped.pixelsWide)), y: Int(fy * Double(cropped.pixelsHigh)))
                #expect(TestImages.matches(color, TestImages.topLeft), "(\(fx), \(fy)): \(String(describing: color))")
            }
        }
        #expect(!TestImages.matches(cropped.colorAt(x: 0, y: 0), TestImages.topLeft), "the corner is rounded off")

        let wholeFrame = try editor.imageFrame(onLineOf: "![Whole")
        let whole = try editor.snapshot(wholeFrame.offsetBy(dx: origin.x, dy: origin.y))
        let (w, h) = (Double(whole.pixelsWide), Double(whole.pixelsHigh))
        #expect(TestImages.matches(whole.colorAt(x: Int(0.25 * w), y: Int(0.25 * h)), TestImages.topLeft))
        #expect(TestImages.matches(whole.colorAt(x: Int(0.75 * w), y: Int(0.25 * h)), TestImages.topRight))
        #expect(TestImages.matches(whole.colorAt(x: Int(0.25 * w), y: Int(0.75 * h)), TestImages.bottomLeft))
        #expect(TestImages.matches(whole.colorAt(x: Int(0.75 * w), y: Int(0.75 * h)), TestImages.bottomRight))
    }
}
