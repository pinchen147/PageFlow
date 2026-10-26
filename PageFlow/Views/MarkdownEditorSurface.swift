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
        isDisplayed = editor.isDisplayed
        isFocused = editor.isFocused
        configuration = editor.nativeEditor
        configuration.updateNativeView(nativeView, coordinator: coordinator)
    }

    func detach(from container: MarkdownEditorSurfaceContainer) {
        guard owner === container else { return }
        focusGeneration &+= 1
        nativeView.removeFromSuperview()
        owner = nil
    }

    func suspend() {
        guard !isReleased else { return }
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

    /// SwiftUI may reuse this container for replacement content, or keep it
    /// through an eviction/reselection before its next reconciliation pass.
    func reconcile(content: MarkdownContent, editor: MarkdownEditorView) {
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
