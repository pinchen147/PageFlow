//
//  ToolbarPeekTests.swift
//  PageFlowTests
//
//  The peek rules: the folded toolbar opens over the tabs while the pointer
//  is on it and folds after a grace period once it leaves, held open by a
//  menu, never opened by a tab drag or right after the fold button.
//

import Testing
@testable import PageFlow

@MainActor
struct ToolbarPeekTests {
    private let enterFolded = ToolbarPeek.Event.pointerEntered(isOpen: false, isDragging: false)

    @Test
    func hoveringTheSphereOpensItAndLeavingFoldsAfterTheGrace() {
        var peek = ToolbarPeek()
        #expect(peek.handle(enterFolded) == .cancel)
        #expect(peek.isPeeking)
        #expect(peek.handle(.pointerExited) == .start)
        #expect(peek.isPeeking, "it folds only once the grace passes")
        #expect(peek.handle(.graceElapsed) == .keep)
        #expect(!peek.isPeeking)
    }

    @Test
    func comingBackWithinTheGraceKeepsItOpen() {
        var peek = ToolbarPeek()
        _ = peek.handle(enterFolded)
        _ = peek.handle(.pointerExited)
        #expect(peek.handle(.pointerEntered(isOpen: true, isDragging: false)) == .cancel)
        _ = peek.handle(.graceElapsed)   // a timer that fired before its cancel landed
        #expect(peek.isPeeking)
    }

    @Test
    func anOpenToolbarOrATabDragDoesNotPeek() {
        var open = ToolbarPeek()
        _ = open.handle(.pointerEntered(isOpen: true, isDragging: false))
        #expect(!open.isPeeking)

        var dragging = ToolbarPeek()
        _ = dragging.handle(.pointerEntered(isOpen: false, isDragging: true))
        #expect(!dragging.isPeeking)
    }

    @Test
    func aMenuHoldsThePeekUntilItCloses() {
        var peek = ToolbarPeek()
        _ = peek.handle(enterFolded)
        #expect(peek.handle(.menuOpened) == .cancel)
        #expect(peek.handle(.pointerExited) == .cancel, "no fold timer while the menu is open")
        _ = peek.handle(.graceElapsed)
        #expect(peek.isPeeking)
        #expect(peek.handle(.menuClosed) == .start)
        _ = peek.handle(.graceElapsed)
        #expect(!peek.isPeeking)
    }

    @Test
    func aMenuClosingUnderThePointerKeepsThePeek() {
        var peek = ToolbarPeek()
        _ = peek.handle(enterFolded)
        _ = peek.handle(.menuOpened)
        #expect(peek.handle(.menuClosed) == .keep)
        #expect(peek.isPeeking)
    }

    @Test
    func theFoldButtonFoldsAndBlocksAPeekUntilThePointerLeaves() {
        var peek = ToolbarPeek()
        _ = peek.handle(enterFolded)
        #expect(peek.handle(.unpinned) == .cancel)
        #expect(!peek.isPeeking)
        _ = peek.handle(enterFolded)
        #expect(!peek.isPeeking, "the folded sphere under the pointer reopened at once")
        _ = peek.handle(.pointerExited)
        _ = peek.handle(enterFolded)
        #expect(peek.isPeeking)
    }

    @Test
    func pinningOpensAtOnce() {
        var peek = ToolbarPeek()
        #expect(peek.handle(.pinned) == .cancel)
        #expect(peek.isPeeking)
    }

    @Test
    func hidingTheChromeEndsThePeek() {
        var peek = ToolbarPeek()
        _ = peek.handle(enterFolded)
        _ = peek.handle(.unpinned)
        #expect(peek.handle(.dismissed) == .cancel)
        #expect(peek == ToolbarPeek(), "a dismissed peek starts over")
    }
}
