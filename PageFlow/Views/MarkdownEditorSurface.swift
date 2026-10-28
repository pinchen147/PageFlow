import AppKit
import MarkdownEngine
import SwiftUI

/// Each SwiftUI mount supplies a container; the document keeps the actual editor
/// so AppKit undo actions still address the live text storage after a window move.
struct MarkdownEditorSurface: NSViewRepresentable {
    let content: MarkdownContent
    let tabManager: TabManager
    let tabID: UUID
    let editor: MarkdownEditorView
    var railEnabled = false
    var railTopInset: CGFloat = 0
    var onShowSidebar: () -> Void = {}

    func makeNSView(context: Context) -> MarkdownEditorSurfaceContainer {
        let container = MarkdownEditorSurfaceContainer()
        reconcile(in: container)
        return container
    }

    func updateNSView(_ container: MarkdownEditorSurfaceContainer, context: Context) {
        reconcile(in: container)
    }

    func reconcile(in container: MarkdownEditorSurfaceContainer) {
        // A removed SwiftUI mount can update after the destination attaches. The
        // session owner, rather than callback order, decides who may mount it.
        guard tabManager.sessions[tabID]?.content.markdown === content,
              tabManager.renderedTabIDs.contains(tabID) else { return }
        container.reconcile(content: content, editor: editor)
        container.configureNavigationRail(content: content, eligible: railEnabled,
            topInset: railTopInset, onShowSidebar: onShowSidebar)
    }

    static func dismantleNSView(_ container: MarkdownEditorSurfaceContainer, coordinator: ()) {
        container.surface?.detach(from: container)
    }
}

@MainActor
final class RetainedMarkdownEditorSurface {
    let nativeView: NSScrollView
    private let coordinator: NativeTextViewCoordinator
    private var configuration: NativeTextViewWrapper
    private(set) weak var owner: MarkdownEditorSurfaceContainer?
    private var isDisplayed: Bool
    private var isFocused: Bool
    private var focusGeneration = 0
    private var isReleased = false
    private var presentationGeneration = 0

    /// Independent of rail settings: history also uses this active native host token.
    var activePresentation: Int? {
        guard !isReleased, isDisplayed, isFocused, let owner, owner.surface === self,
              let window = nativeView.window, owner.window === window,
              !nativeView.isHiddenOrHasHiddenAncestor else { return nil }
        return presentationGeneration
    }

    func ownsPresentation(_ generation: Int) -> Bool { activePresentation == generation }

    func hostWindowChanged(in container: MarkdownEditorSurfaceContainer) {
        guard owner === container else { return }
        presentationGeneration &+= 1
        container.navigationRailAdapter?.rail.invalidate()
    }

    init(editor: MarkdownEditorView) {
        configuration = editor.nativeEditor
        coordinator = configuration.makeCoordinator()
        nativeView = configuration.makeNativeView(coordinator: coordinator)
        isDisplayed = editor.isDisplayed
        isFocused = editor.isFocused
    }

    func attach(to container: MarkdownEditorSurfaceContainer, editor: MarkdownEditorView) {
        guard !isReleased else { return }
        focusGeneration &+= 1
        owner?.retireNavigationRail()
        presentationGeneration &+= 1
        owner = container
        container.surface = self
        nativeView.removeFromSuperview()
        container.addSubview(nativeView)
        container.resizeEditor()
        update(editor, in: container)
        refreshFocus(in: container)
    }

    func update(_ editor: MarkdownEditorView, in container: MarkdownEditorSurfaceContainer) {
        guard !isReleased, owner === container else { return }
        if isDisplayed != editor.isDisplayed || isFocused != editor.isFocused {
            presentationGeneration &+= 1
            container.navigationRailAdapter?.rail.invalidate()
        }
        isDisplayed = editor.isDisplayed
        isFocused = editor.isFocused
        configuration = editor.nativeEditor
        configuration.updateNativeView(nativeView, coordinator: coordinator)
        container.navigationRailAdapter?.hostPresenceChanged()
    }

    func detach(from container: MarkdownEditorSurfaceContainer) {
        guard owner === container else { return }
        container.retireNavigationRail()
        presentationGeneration &+= 1
        focusGeneration &+= 1
        nativeView.removeFromSuperview()
        owner = nil
    }

    func suspend() {
        guard !isReleased else { return }
        owner?.retireNavigationRail()
        presentationGeneration &+= 1
        focusGeneration &+= 1
        isDisplayed = false
        isFocused = false
        configuration.isDisplayed = false
        configuration.isFocused = false
        configuration.updateNativeView(nativeView, coordinator: coordinator)
        nativeView.removeFromSuperview()
        owner = nil
    }

    func release() {
        guard !isReleased else { return }
        owner?.retireNavigationRail()
        presentationGeneration &+= 1
        isReleased = true
        focusGeneration &+= 1
        nativeView.removeFromSuperview()
        owner = nil
        NativeTextViewWrapper.dismantleNSView(nativeView, coordinator: coordinator)
    }

    func refreshFocus(in container: MarkdownEditorSurfaceContainer) {
        guard !isReleased, owner === container, let window = container.window else { return }
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self, weak container, weak window] in
            guard let self, let container, let window,
                  generation == self.focusGeneration, self.owner === container,
                  container.window === window, self.isDisplayed, self.isFocused,
                  let keyView = self.nativeView.markdownEditorKeyView,
                  keyView.window === window, !keyView.isHiddenOrHasHiddenAncestor,
                  window.firstResponder !== keyView else { return }
            window.makeFirstResponder(keyView)
        }
    }
}

@MainActor
final class MarkdownEditorSurfaceContainer: NSView {
    weak var surface: RetainedMarkdownEditorSurface?
    private(set) var navigationRailAdapter: MarkdownNavigationRailAdapter?

    func configureNavigationRail(content: MarkdownContent, eligible: Bool, topInset: CGFloat,
                                 onShowSidebar: @escaping () -> Void) {
        guard surface === content.retainedEditorSurface, surface?.owner === self else { return }
        if navigationRailAdapter == nil, eligible {
            navigationRailAdapter = MarkdownNavigationRailAdapter(content: content, container: self)
        }
        navigationRailAdapter?.update(eligible: eligible, topInset: topInset, onShowSidebar: onShowSidebar)
    }

    func retireNavigationRail() {
        navigationRailAdapter?.detach()
        navigationRailAdapter = nil
    }

    /// Query only the retained native subtree, never the window (which would recurse).
    func nativeControl(at windowPoint: NSPoint) -> NSView? {
        guard let scroll = surface?.nativeView, surface?.owner === self,
              scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
              let parent = scroll.superview,
              let hit = scroll.hitTest(parent.convert(windowPoint, from: nil)) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== scroll {
            if Self.isNativeControl(view) { return hit }
            ancestor = view.superview
        }
        return nil
    }

    func nativeControlRects(in destination: NSView) -> [NSRect] {
        guard let scroll = surface?.nativeView, surface?.owner === self else { return [] }
        var result: [NSRect] = []
        func inspect(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if Self.isNativeControl(view) {
                let rect = destination.convert(view.bounds, from: view)
                if rect.intersects(destination.bounds) { result.append(rect) }
                return
            }
            for child in view.subviews { inspect(child) }
        }
        for child in scroll.subviews { inspect(child) }
        return result
    }

    private static func isNativeControl(_ view: NSView) -> Bool {
        view is NSControl || view.accessibilityRole() == .button || view.accessibilityRole() == .disclosureTriangle
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let rail = navigationRailAdapter?.rail, rail.eligible {
            let local = rail.convert(point, from: superview)
            if let panel = rail.panel, panel.frame.contains(local) { return rail.hitTest(convert(point, from: superview)) }
            if local.x >= 0, local.x < 44, local.y >= 0, local.y < rail.bounds.height,
               let native = nativeControl(at: convert(convert(point, from: superview), to: nil)) { return native }
        }
        return super.hitTest(point)
    }

    /// SwiftUI may reuse this container for replacement content, or keep it
    /// through an eviction/reselection before its next reconciliation pass.
    func reconcile(content: MarkdownContent, editor: MarkdownEditorView) {
        // The rail is a sibling of the editor, so both need the document's scheme.
        appearance = editor.forcedAppearanceName.flatMap { NSAppearance(named: $0) }
        let retained: RetainedMarkdownEditorSurface
        if let existing = content.retainedEditorSurface {
            retained = existing
        } else {
            retained = RetainedMarkdownEditorSurface(editor: editor)
            content.retainedEditorSurface = retained
        }
        if retained.owner === self {
            retained.update(editor, in: self)
        } else {
            surface?.detach(from: self)
            retained.attach(to: self, editor: editor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        surface?.hostWindowChanged(in: self)
        // AppKit propagates attachment through the subtree before publication reads
        // the editor's window. One queued refresh also handles an off-window makeNSView.
        DispatchQueue.main.async { [weak self] in self?.navigationRailAdapter?.hostPresenceChanged() }
        surface?.refreshFocus(in: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeEditor()
    }

    override func layout() {
        super.layout()
        resizeEditor()
    }

    func resizeEditor() {
        guard let surface, surface.owner === self, bounds.width > 0, bounds.height > 0 else { return }
        if surface.nativeView.frame != bounds { surface.nativeView.frame = bounds }
    }
}
