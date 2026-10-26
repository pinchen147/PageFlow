import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFDeferredProjectionTests {
    enum Interruption: CaseIterable {
        case none, zoom, zoomRoundTrip, autoScale, replacement, closed, hidden, dismantled
    }

    @Test(arguments: Interruption.allCases)
    func displayModeFitRespectsNewerIntent(_ interruption: Interruption) async throws {
        let manager = PDFManager()
        let document = try #require(makeTextDocument(text: "Original PDF"))
        manager.document = document
        manager.currentPage = document.page(at: 0)
        manager.scaleFactor = 1
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.autoScales = false
        view.scaleFactor = 1
        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: true
        )
        defer { coordinator.removeScrollMonitor(); view.removeRightClickMonitor() }
        manager.displayMode = .twoUp
        coordinator.project(view, documentDidChange: false)
        #expect(view.displayMode == .twoUp)
        #expect(manager.scaleFactor == 1, "The display-mode fit has been admitted but has not executed")

        switch interruption {
        case .none:
            break
        case .zoom:
            manager.setZoom(2.5)
            coordinator.project(view, documentDidChange: false)
        case .zoomRoundTrip:
            manager.setZoom(2.5)
            manager.setZoom(1)
        case .closed:
            manager.closeDocument()
        case .autoScale:
            manager.toggleAutoScale()
            coordinator.project(view, documentDidChange: false)
        case .replacement:
            let replacement = try #require(makeTextDocument(text: "Replacement PDF"))
            manager.document = replacement
            manager.currentPage = replacement.page(at: 0)
            manager.setZoom(2.5)
        case .hidden:
            coordinator.setActive(isFocused: false, isDisplayed: false, pdfView: view)
        case .dismantled:
            PDFViewWrapper.dismantleNSView(PDFViewHost(pdfView: view), coordinator: coordinator)
        }
        let expectedScale = manager.scaleFactor
        // A queue barrier after the production settle deadline, not a delay used
        // to race an edit: every interruption above precedes callback execution.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfDisplayModeSettleDelay + 0.05) {
                continuation.resume()
            }
        }
        if interruption == .none {
            #expect(PDFViewWrapper.scalesDiffer(manager.scaleFactor, expectedScale), "Positive control: an uninterrupted display-mode change must still fit")
            #expect(!PDFViewWrapper.scalesDiffer(view.scaleFactor, manager.scaleFactor))
        } else {
            #expect(manager.scaleFactor == expectedScale, "An obsolete view callback must not overwrite newer intent")
        }
    }

    @Test
    func displayModeFitSurvivesNativePageReflow() async throws {
        let document = makeTestDocument(pageCount: 6)
        let originalPage = try #require(document.page(at: 3))
        let manager = PDFManager()
        manager.document = document
        manager.currentPage = originalPage
        manager.currentPageIndex = 3
        manager.displayMode = .singlePage
        manager.scaleFactor = 1
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 1
        view.go(to: originalPage)
        try #require(view.currentPage === originalPage)

        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: true
        )
        let notifications = NotificationCenter.default
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.pageChanged(_:)),
                                  name: .PDFViewPageChanged, object: view)
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.scaleChanged(_:)),
                                  name: .PDFViewScaleChanged, object: view)
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.displayModeChanged(_:)),
                                  name: .PDFViewDisplayModeChanged, object: view)
        var pageNotifications = 0
        let observation = notifications.addObserver(forName: .PDFViewPageChanged, object: view, queue: nil) { _ in
            MainActor.assumeIsolated { pageNotifications += 1 }
        }
        defer {
            notifications.removeObserver(observation)
            notifications.removeObserver(coordinator)
            coordinator.removeScrollMonitor()
            view.removeRightClickMonitor()
        }

        manager.displayMode = .twoUp
        coordinator.project(view, documentDidChange: false)
        // PDFKit's spread reflow can change its current page. Where the native
        // implementation keeps it unchanged, navigate the real view before the
        // admitted fit executes; both paths use its scoped page notification.
        if view.currentPage === originalPage {
            view.go(to: try #require(document.page(at: 4)))
        }
        try #require(pageNotifications > 0 && view.currentPage !== originalPage,
                     "The fixture must deliver an actual native page transition while the mode fit is pending")
        try #require(view.displayMode == .twoUp && manager.scaleFactor == 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfDisplayModeSettleDelay + 0.05) {
                continuation.resume()
            }
        }
        let currentPage = try #require(view.currentPage)
        #expect(manager.currentPage === currentPage)
        #expect(manager.currentPageIndex == document.index(for: currentPage))
        #expect(PDFViewWrapper.scalesDiffer(manager.scaleFactor, 1),
                "Native page ingestion must not discard the fit required by the new display mode")
        #expect(!PDFViewWrapper.scalesDiffer(view.scaleFactor, manager.scaleFactor))
    }

    @Test(arguments: [false, true])
    func currentNativeFeedbackStaysLiveInWarmTabs(hidden: Bool) throws {
        let document = makeTestDocument(pageCount: 6)
        let manager = PDFManager()
        manager.document = document
        manager.currentPage = document.page(at: 0)
        manager.scaleFactor = 1
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.autoScales = false
        view.scaleFactor = 1
        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: !hidden
        )
        coordinator.setActive(isFocused: !hidden, isDisplayed: !hidden, pdfView: view)
        let notifications = NotificationCenter.default
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.pageChanged(_:)),
                                  name: .PDFViewPageChanged, object: view)
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.scaleChanged(_:)),
                                  name: .PDFViewScaleChanged, object: view)
        var scaleEvents = 0
        var pageEvents = 0
        let scaleObserver = notifications.addObserver(forName: .PDFViewScaleChanged, object: view, queue: nil) { _ in
            MainActor.assumeIsolated { scaleEvents += 1 }
        }
        let pageObserver = notifications.addObserver(forName: .PDFViewPageChanged, object: view, queue: nil) { _ in
            MainActor.assumeIsolated { pageEvents += 1 }
        }
        defer {
            notifications.removeObserver(scaleObserver)
            notifications.removeObserver(pageObserver)
            notifications.removeObserver(coordinator)
            coordinator.removeScrollMonitor()
            view.removeRightClickMonitor()
        }
        view.scaleFactor = 2.25
        view.go(to: try #require(document.page(at: 4)))
        try #require(scaleEvents > 0 && pageEvents > 0,
                     "The real PDFView must deliver both scoped native notifications")
        #expect(!PDFViewWrapper.scalesDiffer(manager.scaleFactor, view.scaleFactor))
        #expect(manager.currentPage === view.currentPage)
        #expect(manager.currentPageIndex == document.index(for: try #require(view.currentPage)))
    }

    @Test
    func intermediateProjectionScaleCannotOverwriteItsFinalExplicitZoom() async throws {
        let document = makeTestDocument(pageCount: 6)
        let manager = PDFManager()
        manager.document = document
        manager.currentPage = document.page(at: 0)
        manager.displayMode = .singlePage
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = true
        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: true
        )
        // Not displayed: the display-mode change also schedules a refit 0.1 s
        // out, newer intent that may legitimately replace the zoom, and under
        // a busy main queue (the full suite) it can land before this test's
        // one-turn wait. Hidden views reject that refit; the native feedback
        // ingest under test runs either way.
        coordinator.setActive(isFocused: false, isDisplayed: false, pdfView: view)
        let notifications = NotificationCenter.default
        notifications.addObserver(coordinator, selector: #selector(PDFViewWrapper.Coordinator.scaleChanged(_:)),
                                  name: .PDFViewScaleChanged, object: view)
        var nativeScales: [CGFloat] = []
        let observer = notifications.addObserver(forName: .PDFViewScaleChanged, object: view, queue: nil) { _ in
            MainActor.assumeIsolated { nativeScales.append(view.scaleFactor) }
        }
        defer {
            notifications.removeObserver(observer)
            notifications.removeObserver(coordinator)
            coordinator.invalidateDeferredProjection(dismantled: true)
            view.removeRightClickMonitor()
        }
        manager.setZoom(1.75)
        manager.displayMode = .twoUp
        coordinator.project(view, documentDidChange: false)
        try #require(nativeScales.contains { PDFViewWrapper.scalesDiffer($0, 1.75) } && nativeScales.last == 1.75,
                     "Projection must emit an actual intermediate scale followed by its final explicit zoom")
        try #require(view.scaleFactor == 1.75 && manager.scaleFactor == 1.75)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(manager.scaleFactor == 1.75, "Intermediate projector feedback must not replace the final command")
        #expect(view.scaleFactor == 1.75)
    }

    @Test
    func equalValuedFitCommandsDoNotLetTheOlderCallbackConsumeTheNewRequest() async throws {
        let manager = PDFManager()
        let document = try #require(makeTextDocument(text: "Fit command ownership"))
        manager.document = document
        manager.currentPage = document.page(at: 0)
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: true
        )
        manager.requestFitOnce()
        coordinator.project(view, documentDidChange: false)
        manager.requestFitOnce()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(manager.pendingFit == FitRequest(scrollToTop: false), "The earlier callback must leave a later identical command pending")
        coordinator.project(view, documentDidChange: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(manager.pendingFit == nil, "The later command must still be consumable")
    }
}
