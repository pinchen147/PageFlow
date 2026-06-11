//
//  RailFollowTests.swift
//  PageFlowTests
//

import SwiftUI
import Testing
@testable import PageFlow

struct RailFollowTests {
    private let topAnchor = UnitPoint(x: 0.5, y: 0.2)    // forward travel
    private let bottomAnchor = UnitPoint(x: 0.5, y: 0.8) // backward travel

    @Test
    func repositionsWhenVisibilityNotYetMeasured() {
        // Empty visible set = the rail hasn't reported geometry yet; always land the page.
        let move = RailFollow.move(from: 0, to: 5, visiblePages: [])
        #expect(move == RailFollow.Move(pageIndex: 5, anchor: topAnchor))
    }

    @Test
    func staysStillWhenDestinationStrictlyInsideVisibleBand() {
        // Visible 2...8, destination 5 has a cell of margin each side -> no scroll.
        #expect(RailFollow.move(from: 4, to: 5, visiblePages: [2, 3, 4, 5, 6, 7, 8]) == nil)
    }

    @Test
    func repositionsWhenDestinationSitsOnTheVisibleEdge() {
        // Destination equals the first visible page -> not strictly inside -> reposition.
        #expect(RailFollow.move(from: 6, to: 2, visiblePages: [2, 3, 4, 5, 6])
                == RailFollow.Move(pageIndex: 2, anchor: bottomAnchor))
        // Destination equals the last visible page -> reposition.
        #expect(RailFollow.move(from: 2, to: 6, visiblePages: [2, 3, 4, 5, 6])
                == RailFollow.Move(pageIndex: 6, anchor: topAnchor))
    }

    @Test
    func repositionsWhenDestinationIsOutsideVisibleBand() {
        let move = RailFollow.move(from: 5, to: 20, visiblePages: [3, 4, 5, 6, 7])
        #expect(move == RailFollow.Move(pageIndex: 20, anchor: topAnchor))
    }

    @Test
    func forwardTravelAnchorsNearTopBackwardNearBottom() {
        #expect(RailFollow.move(from: 0, to: 10, visiblePages: [])?.anchor == topAnchor)
        #expect(RailFollow.move(from: 10, to: 0, visiblePages: [])?.anchor == bottomAnchor)
    }

    @Test
    func sameIndexCountsAsForwardTravel() {
        // newIndex >= oldIndex, so an unchanged index uses the forward (top) anchor.
        #expect(RailFollow.move(from: 3, to: 3, visiblePages: [])?.anchor == topAnchor)
    }
}
