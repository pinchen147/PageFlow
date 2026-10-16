//
//  TabBarGestureTests.swift
//  PageFlowTests
//

import AppKit
import SwiftUI
import Testing
@testable import PageFlow

@Suite(.serialized)
@MainActor
struct TabBarGestureTests {
    @Test(arguments: [1, 2])
    func tabPressSelectsImmediatelyAndReleaseDoesNotSelectAgain(clickCount: Int) throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        let point = CGPoint(x: 30, y: 16)

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: point, clickCount: clickCount))

        #expect(fixture.manager.activeTabID == fixture.firstTabID)
        #expect(fixture.clicks == [.selectTab(fixture.firstTabID)])
        #expect(!TabDragController.shared.isActive)

        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: point, clickCount: clickCount))

        #expect(fixture.clicks == [.selectTab(fixture.firstTabID)])
        #expect(!TabDragController.shared.isActive)
    }

    @Test(arguments: [1, 2])
    func tabDragStartsOnlyBeyondFivePoints(clickCount: Int) throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        let origin = CGPoint(x: 30, y: 16)

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: origin, clickCount: clickCount))
        fixture.view.mouseDragged(with: try fixture.event(
            .leftMouseDragged, at: CGPoint(x: 35, y: 16), clickCount: clickCount
        ))

        #expect(!TabDragController.shared.isActive)

        fixture.view.mouseDragged(with: try fixture.event(
            .leftMouseDragged, at: CGPoint(x: 36, y: 16), clickCount: clickCount
        ))

        #expect(TabDragController.shared.isActive)
        #expect(TabDragController.shared.activeDrag?.tabID == fixture.firstTabID)
    }

    @Test(arguments: Button.allCases)
    func buttonPressDoesNotSelectOrDragAndValidReleaseFiresOnce(button: Button) throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        fixture.manager.selectTab(fixture.firstTabID)
        fixture.apply()
        let point = button.point

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: point, clickCount: 2))
        fixture.view.mouseDragged(with: try fixture.event(
            .leftMouseDragged, at: CGPoint(x: point.x + 6, y: point.y), clickCount: 2
        ))

        #expect(fixture.clicks.isEmpty)
        #expect(fixture.manager.activeTabID == fixture.firstTabID)
        #expect(!TabDragController.shared.isActive)

        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: point, clickCount: 2))

        #expect(fixture.clicks == [button.target(firstTabID: fixture.firstTabID)])
        #expect(!TabDragController.shared.isActive)

        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: point, clickCount: 2))
        #expect(fixture.clicks.count == 1)
    }

    @Test(arguments: Button.allCases)
    func releasingOutsidePressedButtonCancelsItsAction(button: Button) throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        fixture.manager.selectTab(fixture.firstTabID)
        fixture.apply()

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: button.point))
        fixture.view.mouseUp(with: try fixture.event(
            .leftMouseUp, at: CGPoint(x: button.point.x + 40, y: button.point.y)
        ))

        #expect(fixture.clicks.isEmpty)
        #expect(fixture.manager.activeTabID == fixture.firstTabID)
        #expect(!TabDragController.shared.isActive)
    }

    @Test
    func newlyVisibleCloseButtonDoesNotChangeThePressedTabAction() throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        // The inactive, unhovered tab has no close button at this location.
        let point = CGPoint(x: 115, y: 16)

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: point))

        #expect(fixture.manager.activeTabID == fixture.firstTabID)
        #expect(fixture.clicks == [.selectTab(fixture.firstTabID)])

        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: point))

        #expect(fixture.clicks == [.selectTab(fixture.firstTabID)])
    }

    @Test
    func dragRetainsOriginalGrabOffsetAcrossSelectionLayoutChange() throws {
        let fixture = try GestureFixture()
        defer { fixture.close() }
        // Original tab frame: (10, 3, 120, 26). The grab is 19 from its left,
        // 21 from its bottom; selecting it synchronously moves/resizes the tab.
        fixture.framesAfterSelection = [
            fixture.firstTabID: CGRect(x: 60, y: 3, width: 80, height: 26),
            fixture.secondTabID: CGRect(x: 150, y: 3, width: 120, height: 26)
        ]
        let origin = CGPoint(x: 29, y: 8)
        let thresholdPoint = CGPoint(x: 35, y: 8)

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: origin, clickCount: 2))
        fixture.view.mouseDragged(with: try fixture.event(
            .leftMouseDragged, at: thresholdPoint, clickCount: 2
        ))

        #expect(fixture.manager.activeTabID == fixture.firstTabID)
        #expect(TabDragController.shared.activeDrag?.tabID == fixture.firstTabID)
        let preview = try #require(NSApp.windows.first {
            $0.contentView is NSHostingView<TabDragPreviewView>
        })
        let pointer = fixture.screenPoint(at: thresholdPoint)

        #expect(abs(preview.frame.minX - (pointer.x - 19)) < 0.01)
        #expect(abs(preview.frame.minY - (pointer.y - 21)) < 0.01)
    }

    enum Button: CaseIterable, Sendable {
        case close
        case newTab

        var point: CGPoint {
            switch self {
            case .close: CGPoint(x: 115, y: 16)
            case .newTab: CGPoint(x: 286, y: 16)
            }
        }

        func target(firstTabID: UUID) -> TabBarClickTarget {
            switch self {
            case .close: .closeTab(firstTabID)
            case .newTab: .newTab
            }
        }
    }
}

@MainActor
private final class GestureFixture {
    let manager: TabManager
    let view = TabBarMouseNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 32))
    let window: NSWindow
    let firstTabID: UUID
    let secondTabID: UUID
    var clicks: [TabBarClickTarget] = []
    var framesAfterSelection: [UUID: CGRect]?
    private var tabFrames: [UUID: CGRect]

    init() throws {
        TabDragController.shared.cancelDrag()
        let manager = TabManager()
        manager.newMarkdownDocument()
        manager.newMarkdownDocument()
        self.manager = manager
        firstTabID = try #require(manager.tabs.first?.id)
        secondTabID = try #require(manager.tabs.last?.id)
        tabFrames = [
            firstTabID: CGRect(x: 10, y: 3, width: 120, height: 26),
            secondTabID: CGRect(x: 140, y: 3, width: 120, height: 26)
        ]
        window = NSWindow(
            contentRect: CGRect(x: 100, y: 300, width: 400, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        apply()
        window.contentView = view
    }

    func apply() {
        view.apply(
            tabManager: manager,
            tabFrames: tabFrames,
            newTabButtonFrame: CGRect(x: 274, y: 3, width: 24, height: 26),
            hoveredTabID: nil,
            activeTabID: manager.activeTabID,
            onHover: { _ in },
            onClick: { [weak self] target in
                guard let self else { return }
                clicks.append(target)
                if case .selectTab(let tabID) = target {
                    manager.selectTab(tabID)
                    if let framesAfterSelection {
                        tabFrames = framesAfterSelection
                    }
                    apply()
                }
            }
        )
    }

    func event(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    func screenPoint(at point: CGPoint) -> CGPoint {
        window.convertPoint(toScreen: view.convert(point, to: nil))
    }

    func close() {
        TabDragController.shared.cancelDrag()
        window.contentView = nil
        window.close()
    }
}
