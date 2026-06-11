//
//  NavigationHistory.swift
//  PageFlow
//
//  Back/forward page history for one document — a pure value type.
//

import Foundation

/// The back/forward page stacks behind PDFManager's Back/Forward, extracted as a
/// pure value type so the stack behaviour — depth cap, and clearing the forward
/// stack on a fresh jump — is unit-testable without a live view.
///
/// The owner (PDFManager) supplies the current page on each step and applies the
/// returned target; this type never touches the `PDFView` or the manager's state.
/// `canGoBack`/`canGoForward` are read through PDFManager's computed forwarders,
/// so SwiftUI still invalidates when the history changes (the stored `var` is the
/// observed property).
struct NavigationHistory {
    /// Maximum remembered back entries before the oldest is dropped.
    let maxDepth: Int

    private var back: [NavigationEntry] = []
    private var forward: [NavigationEntry] = []

    init(maxDepth: Int = 50) {
        self.maxDepth = maxDepth
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Records a jump away from `currentPageIndex`: pushes it onto the back stack
    /// (dropping the oldest past the depth cap) and clears forward, since a new
    /// jump invalidates redo.
    mutating func push(_ currentPageIndex: Int) {
        back.append(NavigationEntry(pageIndex: currentPageIndex))
        if back.count > maxDepth {
            back.removeFirst()
        }
        forward.removeAll()
    }

    /// Pops the back stack, recording `currentPageIndex` onto forward. Returns the
    /// page to navigate to, or `nil` when there is nothing to go back to.
    mutating func stepBack(from currentPageIndex: Int) -> Int? {
        guard let entry = back.popLast() else { return nil }
        forward.append(NavigationEntry(pageIndex: currentPageIndex))
        return entry.pageIndex
    }

    /// Pops the forward stack, recording `currentPageIndex` onto back. Returns the
    /// page to navigate to, or `nil` when there is nothing to go forward to.
    mutating func stepForward(from currentPageIndex: Int) -> Int? {
        guard let entry = forward.popLast() else { return nil }
        back.append(NavigationEntry(pageIndex: currentPageIndex))
        return entry.pageIndex
    }

    mutating func clear() {
        back.removeAll()
        forward.removeAll()
    }
}
