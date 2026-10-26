import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Serves a fixed image per destination name.
final class StubImageNames: EmbeddedImageProvider, @unchecked Sendable {
    let images: [String: NSImage]
    init(_ images: [String: NSImage]) { self.images = images }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { images[reference.name] }
    func fingerprint() -> AnyHashable { images.keys.sorted() }
}

/// A real wrapper, coordinator and window around one note with images, laid
/// out in a 672 pt reading column.
@MainActor final class MountedImageEditor {
    static let columnWidth: CGFloat = 672

    let state: TableEditorState
    let wrapper: NativeTextViewWrapper
    let coordinator: NativeTextViewCoordinator
    let scroll: NSScrollView
    let window: NSWindow
    let main: NativeTextView

    init(source: String, images: [String: NSImage]) throws {
        _ = NSApplication.shared
        let state = TableEditorState(source)
        // Tests group their own gestures: no event loop closes AppKit's groups.
        state.undo.groupsByEvent = false
        self.state = state
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = Self.columnWidth
        configuration.services.images = StubImageNames(images)
        wrapper = NativeTextViewWrapper(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            configuration: configuration,
            fontSize: 16,
            documentId: UUID().uuidString,
            editorController: state.controller,
            forcedAppearanceName: .aqua,
            undoManager: state.undo
        )
        coordinator = wrapper.makeCoordinator()
        scroll = wrapper.makeNativeView(coordinator: coordinator)
        main = try #require(scroll.nativeTextView)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = scroll
        window.orderBack(nil)
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        // The caret stays at the end of the note, outside every image.
        main.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: main))
    }

    func close() {
        NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
        window.close()
    }

    func settle() async {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let layout = main.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
            main.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The character carrying the image on the line that contains `marker`.
    func imageAnchor(onLineOf marker: String) throws -> Int {
        let text = main.string as NSString
        let line = text.lineRange(for: NSRange(location: text.range(of: marker).location, length: 0))
        let storage = try #require(main.textStorage)
        var anchor: Int?
        storage.enumerateAttribute(.renderedBlockImage, in: line) { value, range, stop in
            if value != nil { anchor = range.location; stop.pointee = true }
        }
        return try #require(anchor, "no rendered image on the line of \(marker)")
    }

    private func fragment(at anchor: Int) throws -> MarkdownTextLayoutFragment {
        let layout = try #require(main.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(layout.documentRange.location, offsetBy: anchor))
        return try #require(layout.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment)
    }

    /// The drawn image rect on the line of `marker`, in text-container coordinates.
    func imageFrame(onLineOf marker: String) throws -> CGRect {
        let anchor = try imageAnchor(onLineOf: marker)
        return try #require(try fragment(at: anchor).blockImageFrame(at: anchor))
    }

    /// The anchor line's x and typographic advance, in text-container coordinates.
    func anchorLine(onLineOf marker: String) throws -> (minX: CGFloat, width: CGFloat) {
        let anchor = try imageAnchor(onLineOf: marker)
        let fragment = try fragment(at: anchor)
        let content = try #require(main.textLayoutManager?.textContentManager)
        let local = content.offset(from: fragment.rangeInElement.location,
                                   to: try #require(content.location(content.documentRange.location, offsetBy: anchor)))
        let line = try #require(fragment.textLineFragments.first { NSLocationInRange(local, $0.characterRange) })
        let bounds = line.typographicBounds
        return (fragment.layoutFragmentFrame.minX + bounds.minX + line.locationForCharacter(at: local).x, bounds.width)
    }

    /// One key command, delivered as AppKit delivers it (`doCommand(by:)`), as one Undo group.
    func press(_ selector: Selector) {
        state.undo.beginUndoGrouping()
        main.doCommand(by: selector)
        state.undo.endUndoGrouping()
    }

    /// Typed text replacing the selection, as one Undo group.
    func type(_ text: String) {
        state.undo.beginUndoGrouping()
        main.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        state.undo.endUndoGrouping()
    }

    /// The image token (`![…](…)` or `![[…]]`) on the line of `marker`.
    func imageToken(onLineOf marker: String) throws -> MarkdownToken {
        let text = main.string as NSString
        let line = text.lineRange(for: NSRange(location: text.range(of: marker).location, length: 0))
        return try #require(coordinator.parsedDocument(for: main.string).tokens.first {
            ($0.kind == .imageLink || $0.kind == .imageEmbed) && NSLocationInRange($0.range.location, line)
        })
    }

    /// Whether the image on the line of `marker` is drawn collapsed (no Markdown showing).
    func isCollapsed(onLineOf marker: String) throws -> Bool {
        let storage = try #require(main.textStorage)
        let token = try imageToken(onLineOf: marker)
        let anchor = try imageAnchor(onLineOf: marker)
        return storage.attribute(.markdownBlockSourceRange, at: anchor, effectiveRange: nil) != nil
            && storage.attribute(.latexBlockOffsetY, at: token.range.location, effectiveRange: nil) == nil
    }

    /// The top of the line holding `needle`, in view coordinates.
    func lineTop(of needle: String) throws -> CGFloat {
        let location = (main.string as NSString).range(of: needle).location
        try #require(location != NSNotFound)
        return try #require(main.lineFrame(at: location)).minY
    }

    /// The middle of the image drawn on the line of `marker`, in view coordinates.
    func imageCenter(onLineOf marker: String) throws -> NSPoint {
        let rect = try #require(main.renderedImageRect(at: try imageAnchor(onLineOf: marker)))
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// A mouse event at a view point.
    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: main.convert(point, to: nil), modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    /// The text view drawn into a bitmap, `rect` in view coordinates.
    func snapshot(_ rect: NSRect) throws -> NSBitmapImageRep {
        let bitmap = try #require(main.bitmapImageRepForCachingDisplay(in: rect))
        main.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }
}

enum TestImages {
    /// A plain image of `size` points (and pixels).
    static func solid(_ size: CGSize, color: NSColor = .gray) -> NSImage {
        drawn(size) { color.setFill(); NSRect(origin: .zero, size: size).fill() }
    }

    static let topLeft = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let topRight = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    static let bottomLeft = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let bottomRight = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    /// Four coloured quadrants as the image is seen: red top-left, green
    /// top-right, blue bottom-left, yellow bottom-right.
    static func quadrants(_ side: CGFloat = 100) -> NSImage {
        drawn(CGSize(width: side, height: side)) {
            let half = side / 2
            // Bitmap contexts run bottom-up: y = half is the top row of quadrants.
            for (color, origin) in [(topLeft, CGPoint(x: 0, y: half)), (topRight, CGPoint(x: half, y: half)),
                                    (bottomLeft, CGPoint(x: 0, y: 0)), (bottomRight, CGPoint(x: half, y: 0))] {
                color.setFill()
                NSRect(origin: origin, size: CGSize(width: half, height: half)).fill()
            }
        }
    }

    private static func drawn(_ size: CGSize, _ body: () -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// True when `color` is an opaque, saturated colour whose hue is nearest
    /// `expected`'s among the four quadrants. Colour management shifts drawn
    /// colours (a pure green reads back near 0.46, 0.98, 0.30), so the test is
    /// which hue it is; the page and text are unsaturated and match none.
    static func matches(_ color: NSColor?, _ expected: NSColor) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
              color.saturationComponent > 0.4, color.brightnessComponent > 0.4 else { return false }
        func hueDistance(_ other: NSColor) -> CGFloat {
            let delta = abs(color.hueComponent - (other.usingColorSpace(.sRGB)?.hueComponent ?? -1))
            return min(delta, 1 - delta)
        }
        let quadrants = [topLeft, topRight, bottomLeft, bottomRight]
        return quadrants.min(by: { hueDistance($0) < hueDistance($1) }) === expected
    }
}
