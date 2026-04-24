//
//  TabDragControllerTests.swift
//  PageFlowTests
//
//  Covers state-transition correctness and the cross-window cancel
//  regression (a teardown of one window must not abort an in-flight
//  drag from a different window).
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct TabDragControllerTests {
    // MARK: - Test Doubles

    /// Minimal `TabBarHandle` stand-in. Tests configure `containsResult`
    /// and `dropIndexResult` to drive the controller's resolve path
    /// without touching `NSApp.orderedWindows`.
    private final class FakeTabBarHandle: TabBarHandle {
        var window: NSWindow?
        var containsResult = false
        var dropIndexResult: Int?
        var screenFrameResult: CGRect = .zero

        func contains(screenPoint: CGPoint) -> Bool { containsResult }
        func dropIndex(for screenPoint: CGPoint) -> Int? { dropIndexResult }
        func screenFrame() -> CGRect { screenFrameResult }
    }

    private static func freshController() -> TabDragController {
        // Reset shared singleton between tests by force-cancelling any
        // lingering drag state from a previous test.
        let controller = TabDragController.shared
        controller.cancelDrag()
        return controller
    }

    private static let probePoint = CGPoint(x: 100, y: 100)

    private static func snapshot() -> TabDragPreviewSnapshot {
        TabDragPreviewSnapshot(title: "Test", isDirty: false, width: 120)
    }

    // MARK: - State Transitions

    @Test
    func beginDragSetsActiveDragAndIsActive() {
        let controller = Self.freshController()
        let manager = TabManager()
        let tabID = manager.tabs[0].id

        controller.beginDrag(
            tabID: tabID,
            in: manager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )

        #expect(controller.isActive == true)
        #expect(controller.activeDrag?.tabID == tabID)
        #expect(controller.activeDrag?.sourceManagerID == ObjectIdentifier(manager))

        controller.cancelDrag()
    }

    @Test
    func cancelDragResetsAllState() {
        let controller = Self.freshController()
        let manager = TabManager()
        let tabID = manager.tabs[0].id

        controller.beginDrag(
            tabID: tabID,
            in: manager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )
        controller.cancelDrag()

        #expect(controller.isActive == false)
        #expect(controller.activeDrag == nil)
    }

    // MARK: - Cross-Window Cancel Regression

    @Test
    func cancelDragIfSourceUnrelatedManagerDoesNotCancel() {
        let controller = Self.freshController()
        let sourceManager = TabManager()
        let unrelatedManager = TabManager()
        let tabID = sourceManager.tabs[0].id

        controller.beginDrag(
            tabID: tabID,
            in: sourceManager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )

        // Closing an unrelated window must NOT cancel a drag that
        // originated in a different window.
        controller.cancelDragIfSource(unrelatedManager)

        #expect(controller.isActive == true)
        #expect(controller.activeDrag?.tabID == tabID)

        controller.cancelDrag()
    }

    @Test
    func cancelDragIfSourceMatchingManagerCancels() {
        let controller = Self.freshController()
        let manager = TabManager()
        let tabID = manager.tabs[0].id

        controller.beginDrag(
            tabID: tabID,
            in: manager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )
        controller.cancelDragIfSource(manager)

        #expect(controller.isActive == false)
        #expect(controller.activeDrag == nil)
    }

    @Test
    func cancelDragIfSourceWithNoActiveDragIsNoOp() {
        let controller = Self.freshController()
        let manager = TabManager()

        controller.cancelDragIfSource(manager)

        #expect(controller.isActive == false)
        #expect(controller.activeDrag == nil)
    }

    // MARK: - updateDrag Dedup

    @Test
    func updateDragIsIdempotentWhenResolutionUnchanged() {
        let controller = Self.freshController()
        let manager = TabManager()
        let tabID = manager.tabs[0].id

        // Register a fake bar that always claims to contain the screen
        // point and report the same drop index.
        let handle = FakeTabBarHandle()
        handle.containsResult = true
        handle.dropIndexResult = 0
        controller.registerBar(handle, for: manager)
        defer { controller.unregisterBar(for: manager) }

        controller.beginDrag(
            tabID: tabID,
            in: manager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )

        // First updateDrag may mutate state to reflect the resolved
        // target. Subsequent calls with the same screen point + same bar
        // must NOT replace `activeDrag` (struct identity check via field
        // equality is the practical proxy).
        controller.updateDrag(to: Self.probePoint)
        let snapshotAfterFirstUpdate = controller.activeDrag

        controller.updateDrag(to: Self.probePoint)
        let snapshotAfterSecondUpdate = controller.activeDrag

        #expect(snapshotAfterFirstUpdate == snapshotAfterSecondUpdate)

        controller.cancelDrag()
    }

    // MARK: - Bar Registry Lifecycle

    @Test
    func registerAndUnregisterBarRoundTrip() {
        let controller = Self.freshController()
        let manager = TabManager()
        let handle = FakeTabBarHandle()

        controller.registerBar(handle, for: manager)
        controller.unregisterBar(for: manager)
        // No crash, no leaked state. Begin a drag and confirm the
        // controller still operates correctly with no bars registered.
        let tabID = manager.tabs[0].id
        controller.beginDrag(
            tabID: tabID,
            in: manager,
            snapshot: Self.snapshot(),
            screenPoint: Self.probePoint
        )
        #expect(controller.isActive == true)
        controller.cancelDrag()
    }

    // NOTE: A test for the double-click gate on `TabBarMouseNSView` is
    // intentionally deferred — it requires synthesizing an `NSEvent` with
    // a specific `clickCount`, which means plumbing through CGEvent or a
    // private NSEvent constructor. The gate logic is one line
    // (`canDrag = event.clickCount >= 2`) and the underlying behavior is
    // owned by AppKit's double-click detection. Not worth the mocking
    // weight for a one-line invariant.
}
