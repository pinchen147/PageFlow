import AppKit
import SwiftUI

/// Retained AppKit host for visible semantic editing and throwing source export.
public struct SemanticNativeTextViewWrapper: NSViewRepresentable {
    public var options: NativeTextViewWrapper
    public var configuration: MarkdownEditorConfiguration {
        get { options.configuration }
        set { options.configuration = newValue }
    }
    public var isDisplayed: Bool {
        get { options.isDisplayed }
        set { options.isDisplayed = newValue }
    }
    public var isFocused: Bool {
        get { options.isFocused }
        set { options.isFocused = newValue }
    }
    public var editorController: MarkdownEditorController? { options.editorController }

    public init(options: NativeTextViewWrapper) { self.options = options }

    /// Keeps failed imports explicit instead of silently opening an empty editable document.
    @MainActor
    public final class Coordinator {
        var owner: NativeSemanticDocumentCoordinator?
        var host: SemanticEditorHostSession?
        var comments: MarkdownCommentsController?
        var appliedReadingPositionToken: UUID?
        var appliedZoomToken: UUID?
        var lastHostMagnification: CGFloat?
        var lastFittedMagnification: CGFloat?
        var userLeftWidthFit = false
        var isProjectingZoom = false
        var isRestoringReadingPosition = false
        var lastFocused = false
        var lastDisplayed = true
        var hiddenReadingPosition: ReadingPosition?
        var pendingVisiblePosition: ReadingPosition?
        var configuredFontName: String?
        var configuredFontSize: CGFloat?
        var failure: Error?
        var updateGeneration: UInt64 = 0
        var pendingExternalSource: String?
        var lastBindingSource: String
        weak var controller: MarkdownEditorController?

        init(options: NativeTextViewWrapper) {
            lastBindingSource = options.text
            do {
                owner = try NativeSemanticDocumentCoordinator(source: options.text,
                    configuration: options.configuration, undoManager: options.undoManager ?? UndoManager(),
                    fontName: options.fontName, fontSize: options.fontSize)
                if let owner { host = SemanticEditorHostSession(owner: owner) }
            } catch { failure = error }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(options: options) }

    public func makeNSView(context: Context) -> NSScrollView {
        makeNativeView(coordinator: context.coordinator)
    }

    public func updateNSView(_ view: NSScrollView, context: Context) {
        updateNativeView(view, coordinator: context.coordinator)
    }

    public func makeNativeView(coordinator: Coordinator) -> NSScrollView {
        guard let owner = coordinator.owner else {
            options.editorController?.sessionFailure = coordinator.failure
            let scroll = NSScrollView()
            let errorView = NSTextView()
            errorView.isEditable = false
            errorView.string = "Unable to open this document: \(coordinator.failure?.localizedDescription ?? "Unknown import error")"
            scroll.documentView = errorView
            return scroll
        }
        let scroll = owner.makeNativeView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        options.scrollViewConfigurator?(scroll)
        updateNativeView(scroll, coordinator: coordinator)
        return scroll
    }

    public func updateNativeView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.updateGeneration &+= 1
        let updateGeneration = coordinator.updateGeneration
        guard let owner = coordinator.owner else { return }
        if coordinator.lastDisplayed && !options.isDisplayed {
            coordinator.hiddenReadingPosition = coordinator.host?.readingPosition()
        } else if !coordinator.lastDisplayed && options.isDisplayed {
            coordinator.pendingVisiblePosition = coordinator.hiddenReadingPosition
        }
        coordinator.lastDisplayed = options.isDisplayed
        if coordinator.controller !== options.editorController {
            if coordinator.controller?.semanticCoordinator === owner {
                coordinator.controller?.semanticCoordinator = nil
                coordinator.controller?.semanticHost = nil
                coordinator.controller?.semanticComments = nil
            }
            coordinator.comments?.tearDown()
            coordinator.comments = nil
            coordinator.controller = options.editorController
        }
        options.editorController?.semanticCoordinator = owner
        owner.tableWidthsController = options.editorController
        owner.refreshTableWidths()
        options.editorController?.semanticHost = coordinator.host
        coordinator.host?.controller = options.editorController
        coordinator.host?.configure(bus: options.configuration.services.bus, documentID: options.documentId)
        if coordinator.configuredFontName != options.fontName || coordinator.configuredFontSize != options.fontSize
            || !options.configuration.hasSamePresentation(as: owner.configuration)
            || !options.configuration.hasSameLayout(as: owner.configuration)
            || !options.configuration.hasSameServices(as: owner.configuration) {
            if owner.updateConfiguration(options.configuration, fontName: options.fontName, fontSize: options.fontSize) {
                coordinator.configuredFontName = options.fontName
                coordinator.configuredFontSize = options.fontSize
            }
        }
        owner.onLinkClick = options.onLinkClick
        owner.onOpenLocalLink = options.onOpenLocalLink
        owner.onPasteImage = options.onPasteImage
        owner.onDropDocuments = options.onDropDocuments
        owner.opensDroppedFile = options.opensDroppedFile
        owner.onImportImages = options.onImportImages
        owner.onFileDragHover = options.onFileDragHover
        owner.onRequestFocus = options.onRequestFocus
        owner.onKeyCommand = { [weak coordinator] command in
            guard let coordinator else { return false }
            switch command {
            case .toggleFold, .collapseAll, .expandAll:
                return coordinator.host?.fold(command) ?? false
            case .comment:
                coordinator.controller?.performCommentCommand()
                return coordinator.comments != nil
            case .toggleComments:
                guard let controller = coordinator.controller else { return false }
                controller.commentsMode = controller.commentsMode == .hidden ? .margin : .hidden
                return true
            default: return false
            }
        }
        owner.onLayoutChange = { [weak coordinator, weak scroll] in
            guard let coordinator, let scroll else { return }
            self.projectZoom(scroll, coordinator: coordinator)
            self.restoreReadingRequest(scroll, coordinator: coordinator)
            coordinator.host?.foldControls.refresh()
        }
        owner.onInputSettled = { [weak coordinator, weak scroll, weak owner] in
            // AppKit can settle marked text inside another input callback. Admit
            // replacements only after the complete native input stack unwinds.
            DispatchQueue.main.async {
                guard let coordinator, let scroll, let owner, coordinator.owner === owner,
                      coordinator.updateGeneration == updateGeneration else { return }
                self.updateNativeView(scroll, coordinator: coordinator)
                coordinator.host?.inputSettled()
            }
        }
        owner.onSelectionChange = { [weak coordinator] in
            guard let coordinator, let owner = coordinator.owner else { return }
            coordinator.host?.refreshFolds()
            coordinator.controller?.onFormatStateChange?(owner.currentFormatState)
            coordinator.controller?.onSectionNavigationChange?(coordinator.host?.navigationSnapshot())
        }
        owner.keyBindings = options.editorController?.keyBindings ?? options.configuration.keyBindings
        let binding = options.$text
        owner.onCommittedSourceChange = { [weak coordinator] source in
            guard let coordinator, coordinator.pendingExternalSource == nil else { return }
            coordinator.lastBindingSource = source
            binding.wrappedValue = source
        }
        // Retain authoritative external loads across protected native input. Old-owner
        // publication cannot overwrite the pending load, and saves fail until admission.
        if options.editorController?.pendingSemanticReload == true
            || !options.text.utf16.elementsEqual(coordinator.lastBindingSource.utf16) {
            coordinator.pendingExternalSource = options.text
        }
        if let incoming = coordinator.pendingExternalSource {
            do {
                try owner.replaceSource(incoming)
                if let anchors = coordinator.comments?.semanticAnchors, let controller = options.editorController {
                    try anchors.load(controller.commentThreads)
                }
                coordinator.lastBindingSource = incoming
                coordinator.pendingExternalSource = nil
                coordinator.hiddenReadingPosition = nil
                coordinator.pendingVisiblePosition = nil
                options.editorController?.sessionFailure = nil
                options.editorController?.pendingSemanticReload = false
            } catch {
                options.editorController?.sessionFailure = error
                owner.onExportFailure?(error)
            }
        }
        if coordinator.pendingExternalSource == nil, coordinator.comments == nil, let controller = options.editorController {
            do {
                coordinator.comments = try MarkdownCommentsController(semanticOwner: owner,
                    editorController: controller, scrollView: scroll, store: controller.commentStore)
                controller.semanticComments = coordinator.comments
            } catch { controller.sessionFailure = error }
        }
        owner.textView.isEditable = options.isEditable
        scroll.isHidden = !options.isDisplayed
        scroll.appearance = options.forcedAppearanceName.flatMap(NSAppearance.init(named:))
        scroll.contentInsets = NSEdgeInsets(top: options.configuration.safeAreaInsets.top,
            left: options.configuration.safeAreaInsets.leading,
            bottom: options.configuration.safeAreaInsets.bottom,
            right: options.configuration.safeAreaInsets.trailing)
        projectZoom(scroll, coordinator: coordinator)
        restoreReadingRequest(scroll, coordinator: coordinator)
        applyFocus(scroll, coordinator: coordinator)
    }

    private func applyFocus(_ scroll: NSScrollView, coordinator: Coordinator) {
        let focused = options.isFocused && options.isDisplayed
        guard focused != coordinator.lastFocused else { return }
        coordinator.lastFocused = focused
        guard focused else { return }
        DispatchQueue.main.async { [weak coordinator, weak scroll] in
            guard let coordinator, coordinator.lastFocused, let scroll,
                  !scroll.isHiddenOrHasHiddenAncestor, let window = scroll.window,
                  let target = scroll.markdownEditorKeyView, target.window === window,
                  window.firstResponder !== target,
                  coordinator.comments?.ownsAnnotationResponder(window.firstResponder) != true else { return }
            coordinator.owner?.textView.preservingSemanticViewport(requireEdit: false, revealCaret: false) {
                window.makeFirstResponder(target)
            }
        }
    }

    private func restoreReadingRequest(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard !coordinator.isRestoringReadingPosition, !coordinator.isProjectingZoom,
              scroll.window != nil, !scroll.isHiddenOrHasHiddenAncestor,
              scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0 else { return }
        coordinator.isRestoringReadingPosition = true
        defer { coordinator.isRestoringReadingPosition = false }
        if let position = options.editorController?.semanticReloadPosition {
            if coordinator.host?.restore(position) == true {
                options.editorController?.semanticReloadPosition = nil
            }
        } else if let request = options.readingPositionRequest,
                  coordinator.appliedReadingPositionToken != request.token,
                  coordinator.host?.restore(request.position) == true {
            coordinator.appliedReadingPositionToken = request.token
            coordinator.pendingVisiblePosition = nil
        } else if let position = coordinator.pendingVisiblePosition,
                  coordinator.host?.restore(position) == true {
            coordinator.pendingVisiblePosition = nil
        }
    }

    public static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.lastFocused = false
        if let owner = coordinator.owner {
            do { _ = try owner.flushCommittedSource() }
            catch { owner.onExportFailure?(error) }
            if coordinator.controller?.semanticCoordinator === owner { coordinator.controller?.semanticCoordinator = nil }
            owner.onCommittedSourceChange = nil
            owner.onLayoutChange = nil
            owner.onInputSettled = nil
            owner.onSelectionChange = nil
            owner.onKeyCommand = nil
            owner.selectionBar?.uninstall()
            owner.imageControls?.uninstall()
            owner.objectPopover?.performClose(nil)
            owner.imageCropView?.close(applied: false)
            owner.imageAltPopover?.close(restoreFocus: false)
            owner.documentStorage.detachSourceBlocks()
            owner.textView.textLayoutManager?.renderingAttributesValidator = nil
            owner.textView.textLayoutManager?.textContainer = nil
        }
        coordinator.comments?.tearDown()
        coordinator.comments = nil
        coordinator.host?.foldControls.uninstall()
        coordinator.host?.stop()
        coordinator.host = nil
        coordinator.owner = nil
        view.documentView = nil
    }
}
