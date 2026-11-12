//
//  NavigationTrail.swift
//  PageFlow
//
//  Back and Forward over a document's jumps, shared by Markdown and EPUB.
//

import Foundation

/// Go Back/Forward (⌘[ / ⌘]) for Markdown and EPUB — a pure two-stack trail of
/// positions, the peer of the PDF view's page-navigation history. A jump
/// (outline click, Go to Line) records the departure position; going back pushes
/// the current position onto the forward stack, so the trail walks both ways.
/// New jumps clear the forward stack (browser semantics). Markdown stores text
/// locations (ADR-0021) and EPUB book locations, so zoom and reflow never
/// strand an entry.
struct NavigationTrail<Position: Equatable & Sendable>: Equatable, Sendable {
    /// Oldest-first; a runaway jump session prunes from the front.
    private(set) var backStack: [Position] = []
    private(set) var forwardStack: [Position] = []

    private static var capacity: Int { 100 }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A second jump from the same place adds nothing new to go back to.
    mutating func recordJump(from position: Position) {
        if backStack.last != position { backStack.append(position) }
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
        forwardStack.removeAll()
    }

    mutating func goBack(from current: Position) -> Position? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return target
    }

    mutating func goForward(from current: Position) -> Position? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return target
    }
}
