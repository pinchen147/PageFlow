import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
@Suite("Navigation rail policy", .serialized)
struct NavigationRailPolicyTests {
    @Test
    func railPreferenceDefaultsOnAndPersistsBothValues() throws {
        let suite = "pageflow.rail-policy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showNavigationRail)
        settings.showNavigationRail = false
        #expect(!SettingsManager(defaults: defaults).showNavigationRail)
        settings.showNavigationRail = true
        #expect(SettingsManager(defaults: defaults).showNavigationRail)
    }

    @Test(arguments: [false, true])
    func automaticLoadAndRestoredAutoScaleSuppressTheRail(_ restoredAutoScale: Bool) throws {
        let suite = "pageflow.rail-load.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rail-\(UUID()).pdf")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let document = try #require(makeTextDocument(pages: ["First", "Second"]))
        try #require(document.write(to: url))
        let manager = PDFManager()
        manager.documentStateStore = DocumentStateStore(defaults: defaults)
        defer { manager.closeDocument() }
        #expect(manager.loadDocument(from: url) == .success)
        #expect(manager.pendingFit == FitRequest(scrollToTop: true))
        #expect(manager.suppressesNavigationRail)
        manager.zoomIn()
        #expect(!manager.suppressesNavigationRail)
        manager.documentStateStore.save(DocumentViewState(pageIndex: 1, scaleFactor: 1.25, isAutoScaling: restoredAutoScale), for: url)
        manager.requestFitOnce()
        #expect(manager.loadDocument(from: url) == .success)
        #expect(manager.isAutoScaling == restoredAutoScale)
        #expect(manager.pendingFit == nil)
        #expect(manager.suppressesNavigationRail == restoredAutoScale)
    }

    @Test
    func explicitFitSurvivesConsumptionAndPassiveViewChanges() {
        let manager = makeManager()
        manager.requestFitOnce()
        #expect(manager.suppressesNavigationRail)
        manager.pendingFit = nil
        #expect(manager.suppressesNavigationRail)
        manager.goToPage(1)
        manager.ingestScaleChange(1.37)
        manager.ingestDisplayModeChange(.twoUp)
        #expect(manager.suppressesNavigationRail)
    }

    enum ManualZoom: CaseIterable { case zoomIn, zoomOut, actualSize, setZoom }
    @Test(arguments: ManualZoom.allCases)
    func deliberateZoomClearsFittedReading(_ command: ManualZoom) {
        let manager = makeManager()
        manager.requestFitOnce()
        switch command {
        case .zoomIn: manager.zoomIn()
        case .zoomOut: manager.zoomOut()
        case .actualSize: manager.resetZoom()
        case .setZoom: manager.setZoom(manager.scaleFactor)
        }
        #expect(!manager.suppressesNavigationRail)
        #expect(manager.pendingFit == nil)
        #expect(!manager.isAutoScaling)
    }

    @Test
    func autoScaleOnAndOffExpressFittedReadingIntent() {
        let manager = makeManager()
        manager.setAutoScaling(true)
        #expect(manager.isAutoScaling)
        #expect(manager.suppressesNavigationRail)
        #expect(manager.pendingFit == nil)
        manager.toggleAutoScale()
        #expect(!manager.isAutoScaling)
        #expect(!manager.suppressesNavigationRail)
        manager.toggleAutoScale()
        #expect(manager.suppressesNavigationRail)
        manager.zoomIn()
        #expect(!manager.isAutoScaling)
        #expect(!manager.suppressesNavigationRail)
    }

    @Test
    func tabActivationAndWindowTransferPreserveFitWithoutAffectingManualSidebar() throws {
        let source = TabManager()
        let session = try #require(source.activeSession)
        let manager = try #require(session.content.pdf?.pdfManager)
        manager.document = makeTestDocument(pageCount: 2)
        manager.currentPage = manager.document?.page(at: 0)
        manager.requestFitOnce()
        manager.pendingFit = nil
        session.uiState.showingOutline = true
        session.captureViewSnapshot()
        manager.ingestScaleChange(2)
        session.restoreViewSnapshot()
        #expect(manager.scaleFactor == 1)
        #expect(manager.suppressesNavigationRail)
        let destination = TabManager(createInitialTab: false)
        #expect(source.moveTab(session.id, to: destination, at: 0))
        #expect(destination.activePDFManager === manager)
        #expect(manager.suppressesNavigationRail)
        #expect(session.uiState.showingOutline)
        manager.zoomIn()
        #expect(session.uiState.showingOutline)
    }

    @Test
    func documentReplacementAndCloseClearOnlyTheOldFitIntent() {
        let manager = makeManager()
        manager.requestFitOnce()
        let sameDocument = manager.document
        manager.document = sameDocument
        #expect(manager.suppressesNavigationRail)
        manager.document = makeTestDocument(pageCount: 1)
        #expect(!manager.suppressesNavigationRail)
        manager.requestFitOnce()
        manager.closeDocument()
        #expect(!manager.suppressesNavigationRail)
    }

    @Test
    func controlScrollRejectsAnOverlayBeforeMutatingAnyZoomState() throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        manager.setAutoScaling(true)
        view.autoScales = true
        manager.pendingFit = FitRequest(scrollToTop: false)
        let overlay = NSView(frame: view.frame)
        try #require(window.contentView).addSubview(overlay, positioned: .above, relativeTo: view)
        let event = try scrollEvent(in: window)
        let scale = view.scaleFactor
        #expect(!coordinator.processControlScroll(event: event, pdfView: view))
        #expect(view.scaleFactor == scale)
        #expect(view.autoScales)
        #expect(view.interpolationQuality == .high)
        #expect(manager.isAutoScaling)
        #expect(manager.pendingFit != nil)
        #expect(manager.suppressesNavigationRail)
        overlay.removeFromSuperview()
        #expect(coordinator.processControlScroll(event: event, pdfView: view))
        #expect(view.scaleFactor != scale)
        #expect(!manager.isAutoScaling)
        #expect(manager.pendingFit == nil)
        #expect(!manager.suppressesNavigationRail)
    }

    @Test
    func controlScrollRejectsForeignHiddenDetachedAndZeroDeltaInput() throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        let foreign = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { foreign.close(); window.close(); coordinator.removeScrollMonitor() }
        manager.requestFitOnce()
        #expect(!coordinator.processControlScroll(event: try scrollEvent(in: foreign), pdfView: view))
        view.isHidden = true
        #expect(!coordinator.processControlScroll(event: try scrollEvent(in: window), pdfView: view))
        view.isHidden = false
        #expect(!coordinator.processControlScroll(event: try scrollEvent(in: window, delta: 0), pdfView: view))
        view.removeFromSuperview()
        #expect(!coordinator.processControlScroll(event: try scrollEvent(in: window), pdfView: view))
        #expect(manager.suppressesNavigationRail)
        #expect(manager.pendingFit != nil)
        #expect(manager.scaleFactor == 1)
    }

    enum NativeZoom: CaseIterable { case zoomIn, zoomOut, actualSize, pinch }
    @Test(arguments: NativeZoom.allCases)
    func nativeUserZoomClearsFitButPassiveScaleDoesNot(_ command: NativeZoom) throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        manager.requestFitOnce()
        view.scaleFactor = 1.2
        coordinator.scaleChanged(Notification(name: .PDFViewScaleChanged, object: view))
        #expect(manager.suppressesNavigationRail)
        switch command {
        case .zoomIn: view.zoomIn(nil)
        case .zoomOut: view.zoomOut(nil)
        case .actualSize: view.actualSize(nil)
        case .pinch:
            #expect(coordinator.processMagnification(event: InputEvent(window: window, type: .magnify, delta: 0.1), pdfView: view))
        }
        #expect(!manager.suppressesNavigationRail)
        #expect(manager.pendingFit == nil)
    }

    @Test(arguments: [false, true])
    func internalModeFitSuppressesTheRailAndResizePreservesIt(_ explicitlyFitted: Bool) async {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        if explicitlyFitted {
            manager.requestFitOnce()
            manager.pendingFit = nil
        }
        manager.displayMode = .twoUp
        coordinator.project(view, documentDidChange: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfDisplayModeSettleDelay + 0.05) {
                continuation.resume()
            }
        }
        #expect(manager.scaleFactor != 1, "Positive control: the internal fit executed")
        view.setFrameSize(NSSize(width: 270, height: 280))
        #expect(manager.suppressesNavigationRail)
    }

    @Test
    func pinchRejectsOverlayZeroDeltaAndRetiredOwnership() {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        manager.requestFitOnce()
        #expect(!coordinator.processMagnification(event: InputEvent(window: window, type: .magnify, delta: 0), pdfView: view))
        #expect(manager.suppressesNavigationRail)
        let overlay = NSView(frame: view.frame)
        window.contentView?.addSubview(overlay, positioned: .above, relativeTo: view)
        #expect(!coordinator.processMagnification(event: InputEvent(window: window, type: .magnify, delta: 0.1), pdfView: view))
        #expect(manager.suppressesNavigationRail)
        overlay.removeFromSuperview()
        coordinator.setActive(isFocused: false, isDisplayed: false, pdfView: view)
        view.zoomIn(nil)
        #expect(manager.suppressesNavigationRail)
        #expect(manager.pendingFit != nil)
    }

    @Test
    func contextMenuActualSizeRestoresTheRail() throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        manager.requestFitOnce()
        view.scaleFactor = 1.5
        let menu = try pageMenu(in: window, view: view)
        let item = try #require(menu.items.first { $0.action == #selector(StablePDFView.actualSize(_:)) })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(view.scaleFactor == 1)
        #expect(!manager.suppressesNavigationRail)
        #expect(manager.pendingFit == nil)
    }

    @Test
    func contextMenuAutomaticResizeOwnsFittedReadingIntent() throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        let menu = try pageMenu(in: window, view: view)
        let index = try #require(menu.items.firstIndex { $0.action == #selector(StablePDFView.automaticallyResize(_:)) })
        menu.performActionForItem(at: index)
        #expect(view.autoScales)
        #expect(manager.isAutoScaling)
        #expect(manager.suppressesNavigationRail)
        // An idempotent native fit remains an explicit reading choice, including
        // after restoring Auto-Scale from disk without restoring rail intent.
        manager.document = makeTestDocument(pageCount: 2)
        view.document = manager.document
        view.autoScales = true
        manager.isAutoScaling = true
        #expect(!manager.suppressesNavigationRail)
        menu.performActionForItem(at: index)
        #expect(manager.suppressesNavigationRail)
        manager.setAutoScaling(false)
        coordinator.project(view, documentDidChange: false)
        #expect(!view.autoScales)
        #expect(!manager.suppressesNavigationRail)
    }

    @Test(arguments: [false, true])
    func nativeAutoScaleIntentDoesNotRequireAnEnglishMenuTitle(_ alreadyEnabled: Bool) throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        let menu = try pageMenu(in: window, view: view)
        let index = try #require(menu.items.firstIndex { $0.action == #selector(StablePDFView.automaticallyResize(_:)) })
        menu.items[index].title = "自动调整大小"
        view.autoScales = alreadyEnabled
        manager.isAutoScaling = alreadyEnabled
        #expect(!manager.suppressesNavigationRail)
        menu.performActionForItem(at: index)
        #expect(view.autoScales)
        #expect(manager.isAutoScaling)
        #expect(manager.suppressesNavigationRail)
    }

    @Test
    func projectedFitRemainsSuppressedAfterItsRequestIsConsumed() async {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        manager.requestFitOnce()
        coordinator.project(view, documentDidChange: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(manager.pendingFit == nil)
        #expect(manager.scaleFactor != 1)
        #expect(manager.suppressesNavigationRail)
    }

    @Test
    func supersededNativeViewCannotClearTheCurrentDocumentIntent() {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        let successor = NSObject()
        manager.liveDestinationProviderOwner = ObjectIdentifier(successor)
        manager.requestFitOnce()
        view.actualSize(nil)
        #expect(manager.suppressesNavigationRail)
        #expect(manager.pendingFit != nil)
        manager.liveDestinationProviderOwner = nil
        manager.document = makeTestDocument(pageCount: 1)
        manager.requestFitOnce()
        #expect(!coordinator.processMagnification(event: InputEvent(window: window, type: .magnify, delta: 0.1), pdfView: view))
        #expect(!coordinator.processControlScroll(event: InputEvent(window: window, type: .scrollWheel, delta: 1), pdfView: view))
        view.zoomIn(nil)
        #expect(manager.suppressesNavigationRail)
        #expect(manager.pendingFit != nil)
        #expect(view.scaleFactor == 1)
    }

    @Test(arguments: NativeZoom.allCases)
    func attachedViewWithoutOwnershipCallbackRejectsManualZoom(_ command: NativeZoom) throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        manager.setAutoScaling(true)
        view.autoScales = true
        let scale = view.scaleFactor
        view.onUserZoom = nil
        try #require(view.window === window && view.document != nil)
        switch command {
        case .zoomIn: view.zoomIn(nil)
        case .zoomOut: view.zoomOut(nil)
        case .actualSize: view.actualSize(nil)
        case .pinch:
            #expect(!view.beginUserMagnification(with: InputEvent(window: window, type: .magnify, delta: 0.1)))
        }
        #expect(view.scaleFactor == scale)
        #expect(view.autoScales)
        #expect(manager.isAutoScaling)
        #expect(manager.suppressesNavigationRail)
    }

    @Test
    func retainedResizeMenuCannotChangeAnAttachedDismantledView() throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        let menu = try pageMenu(in: window, view: view)
        let index = try #require(menu.items.firstIndex { $0.action == #selector(StablePDFView.automaticallyResize(_:)) })
        let host = PDFViewHost(pdfView: view)
        host.frame = NSRect(x: 30, y: 30, width: 300, height: 300)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        PDFViewWrapper.dismantleNSView(host, coordinator: coordinator)
        try #require(view.window === window && view.document != nil && view.onUserZoom == nil)
        let scale = view.scaleFactor
        menu.performActionForItem(at: index)
        #expect(view.scaleFactor == scale)
        #expect(!view.autoScales)
        #expect(!manager.isAutoScaling)
        #expect(!manager.suppressesNavigationRail)
    }

    @Test(arguments: [false, true])
    func localizedNativeSizingCommandsAreIdentifiedBeforeConfiguration(_ hasIdentifier: Bool) throws {
        let (manager, view, coordinator, window) = makeNativeFixture()
        defer { window.close(); coordinator.removeScrollMonitor() }
        coordinator.configureUserZoom(on: view)
        let event = try pageMenuEvent(in: window)
        let menu = try #require(view.menu(for: event))
        let automaticResize = try #require(menu.items.first { $0.identifier?.rawValue == "_setAutoSize:" })
        let actualSize = try #require(menu.items.first { $0.identifier?.rawValue == "_setActualSize:" })
        let unrelated = try #require(menu.items.first { $0.identifier?.rawValue == "goToNextPage:" })
        let unrelatedAction = unrelated.action
        let unrelatedTarget = unrelated.target as AnyObject?
        let pdfKit = Bundle(for: PDFView.self)
        if hasIdentifier {
            // Values verified in the installed PDFKit Localizable table (zh_CN).
            automaticResize.title = "自动调整大小"
            actualSize.title = "实际大小"
        } else {
            automaticResize.identifier = NSUserInterfaceItemIdentifier("different-native-resize-id")
            actualSize.identifier = NSUserInterfaceItemIdentifier("different-native-actual-size-id")
            automaticResize.title = pdfKit.localizedString(forKey: "Auto Size", value: nil, table: "Localizable")
            actualSize.title = pdfKit.localizedString(forKey: "Actual Size", value: nil, table: "Localizable")
        }
        view.configureNativeSizingActions(in: menu)
        #expect(unrelated.action == unrelatedAction)
        #expect((unrelated.target as AnyObject?) === unrelatedTarget)
        view.autoScales = true
        manager.isAutoScaling = true
        #expect(!manager.suppressesNavigationRail)
        let automaticIndex = try #require(menu.items.firstIndex { $0 === automaticResize })
        menu.performActionForItem(at: automaticIndex)
        #expect(manager.suppressesNavigationRail)
        let actualIndex = try #require(menu.items.firstIndex { $0 === actualSize })
        menu.performActionForItem(at: actualIndex)
        #expect(view.scaleFactor == 1)
        #expect(!view.autoScales)
        #expect(!manager.isAutoScaling)
        #expect(!manager.suppressesNavigationRail)
    }

    private func pageMenu(in window: NSWindow, view: StablePDFView) throws -> NSMenu {
        let event = try pageMenuEvent(in: window)
        return view.buildContextMenu(for: event, at: view.convert(event.locationInWindow, from: nil))
    }

    private func pageMenuEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 150, y: 150), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    private func makeManager() -> PDFManager {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: 2)
        manager.currentPage = manager.document?.page(at: 0)
        return manager
    }

    private func makeNativeFixture() -> (PDFManager, StablePDFView, PDFViewWrapper.Coordinator, NSWindow) {
        let manager = makeManager()
        let view = StablePDFView(frame: NSRect(x: 30, y: 30, width: 300, height: 300))
        view.document = manager.document
        view.autoScales = false
        view.scaleFactor = 1
        view.interpolationQuality = .high
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.layoutIfNeeded()
        let coordinator = PDFViewWrapper.Coordinator(pdfManager: manager, annotationManager: AnnotationManager(), commentManager: CommentManager(), isActive: true)
        return (manager, view, coordinator, window)
    }

    private func scrollEvent(in window: NSWindow, delta: CGFloat = 1) throws -> NSEvent {
        InputEvent(window: window, type: .scrollWheel, delta: delta)
    }

    /// Only event data is synthetic; native hit testing, PDFKit and policy are real.
    private final class InputEvent: NSEvent {
        let targetWindow: NSWindow
        let inputType: NSEvent.EventType
        let delta: CGFloat

        init(window: NSWindow, type: NSEvent.EventType, delta: CGFloat) {
            targetWindow = window
            inputType = type
            self.delta = delta
            super.init()
        }

        required init?(coder: NSCoder) { fatalError("Not archived") }
        override var window: NSWindow? { targetWindow }
        override var type: NSEvent.EventType { inputType }
        override var locationInWindow: NSPoint { NSPoint(x: 150, y: 150) }
        override var modifierFlags: NSEvent.ModifierFlags { .control }
        override var scrollingDeltaY: CGFloat { delta }
        override var magnification: CGFloat { delta }
    }
}
