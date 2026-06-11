//
//  NavigationHistoryTests.swift
//  PageFlowTests
//

import Testing
@testable import PageFlow

struct NavigationHistoryTests {
    @Test
    func freshHistoryHasNothingToNavigate() {
        var history = NavigationHistory()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.stepBack(from: 3) == nil)
        #expect(history.stepForward(from: 3) == nil)
    }

    @Test
    func pushEnablesBackAndRecordsTheOrigin() {
        var history = NavigationHistory()
        history.push(2)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)

        // Stepping back from the page we jumped to (7) returns the origin (2).
        #expect(history.stepBack(from: 7) == 2)
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test
    func backThenForwardRoundTrips() {
        var history = NavigationHistory()
        history.push(2)                          // back: [2]
        #expect(history.stepBack(from: 7) == 2)   // back: [], forward: [7]
        #expect(history.stepForward(from: 2) == 7) // forward: [], back: [2]
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test
    func aFreshJumpClearsForward() {
        var history = NavigationHistory()
        history.push(1)
        _ = history.stepBack(from: 5)            // forward: [5]
        #expect(history.canGoForward)

        history.push(9)                          // a new jump invalidates redo
        #expect(!history.canGoForward)
    }

    @Test
    func depthCapDropsOldestBackEntries() {
        var history = NavigationHistory(maxDepth: 2)
        history.push(0)
        history.push(1)
        history.push(2)                          // back capped to [1, 2]; 0 dropped

        #expect(history.stepBack(from: 99) == 2)
        #expect(history.stepBack(from: 2) == 1)
        #expect(history.stepBack(from: 1) == nil) // 0 was dropped by the cap
    }

    @Test
    func clearEmptiesBothStacks() {
        var history = NavigationHistory()
        history.push(1)
        _ = history.stepBack(from: 4)            // back: [], forward: [4]
        history.clear()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }
}
