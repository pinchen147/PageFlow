import AppKit

/// The ring around an image selected as a whole (doc 26 §3.5): 2 pt, 3 pt out
/// from the image, corner radius 4, in the primary label colour: black in
/// light, white in dark (owner decision O8). A subview of the text view, so it
/// scrolls and magnifies with the page; it never takes a click.
final class ImageChromeView: NSView {
    static let ringWidth: CGFloat = 2
    static let ringOffset: CGFloat = 3
    static let ringRadius: CGFloat = 4
    static let ringColor = NSColor(name: "ImageSelectionRing") { appearance in
        ChromePalette.isDark(appearance) ? .white : .black
    }

    /// The ring's frame around an image drawn in `imageRect` (text-view coordinates).
    static func ringFrame(around imageRect: NSRect) -> NSRect {
        imageRect.insetBy(dx: -(ringOffset + ringWidth), dy: -(ringOffset + ringWidth))
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.ringWidth / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: Self.ringRadius, yRadius: Self.ringRadius)
        path.lineWidth = Self.ringWidth
        Self.ringColor.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Keeps the ring on the object-selected image (doc 26 §3.5): placed from the
/// rect the image's layout fragment draws, refreshed when the selection
/// changes and whenever TextKit lays out or draws text. Read-only editors and
/// images outside the laid-out viewport show no ring. Nothing here lays text out.
final class ImageChromeController {
    weak var coordinator: NativeTextViewCoordinator?
    weak var textView: NativeTextView?
    let ring = ImageChromeView(frame: .zero)
    private var refreshScheduled = false

    init(coordinator: NativeTextViewCoordinator, textView: NativeTextView) {
        self.coordinator = coordinator
        self.textView = textView
        ring.isHidden = true
        textView.addSubview(ring, positioned: .above, relativeTo: nil)
    }

    func uninstall() { ring.removeFromSuperview() }

    /// The object selection moved: repaint the images it left and reached
    /// (their fragments hide the selection band, §3.3) and move the ring.
    func selectionDidChange(from old: ObjectSelection?) {
        if let old { textView?.redisplayRenderedImage(at: old.anchor) }
        if let anchor = coordinator?.objectSelection?.anchor { textView?.redisplayRenderedImage(at: anchor) }
        refresh()
    }

    /// TextKit laid out or drew text: the image may have moved. Once per turn.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    func refresh() {
        coordinator?.imageControls?.refresh()
        guard let main = textView, let image = coordinator?.objectSelection, main.isEditable,
              let rect = main.renderedImageRect(at: image.anchor) else {
            ring.isHidden = true
            return
        }
        let frame = ImageChromeView.ringFrame(around: rect)
        if ring.frame != frame { ring.frame = frame }
        // Grids and overlays mount later: the ring stays on top of them.
        if ring.superview !== main || main.subviews.last !== ring {
            main.addSubview(ring, positioned: .above, relativeTo: nil)
        }
        ring.isHidden = false
    }
}
