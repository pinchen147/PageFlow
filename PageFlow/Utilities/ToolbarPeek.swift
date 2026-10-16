//
//  ToolbarPeek.swift
//  PageFlow
//
//  The pure rules of the peek: the folded toolbar springing open over the
//  tabs while the pointer is on it, and folding again after it leaves.
//

/// The peek's state and its rules. The chrome feeds it pointer, menu, drag
/// and button events and runs the fold grace timer it asks for.
struct ToolbarPeek: Equatable {
    /// The toolbar floats open over the tabs.
    private(set) var isPeeking = false
    /// The pointer is on the sphere or the open toolbar.
    private(set) var isHovered = false
    /// The fold button was just pressed under the pointer: no peek until the
    /// pointer leaves.
    private(set) var isSuppressed = false
    /// A menu is open. SwiftUI's menus can't be told apart, so any menu holds
    /// an open peek; one opened from the toolbar keeps it from folding under
    /// the menu, and one opened elsewhere only delays the fold.
    private(set) var isMenuOpen = false

    enum Event: Equatable {
        /// The pointer reached the sphere or the open toolbar.
        case pointerEntered(isOpen: Bool, isDragging: Bool)
        case pointerExited
        case menuOpened
        case menuClosed
        /// The fold grace period ran out.
        case graceElapsed
        /// The fold button: unpin and fold under the pointer.
        case unpinned
        /// A sphere click or the keep-open button: pin it open.
        case pinned
        /// The toolbar hid with the tabs, or a tab drag began.
        case dismissed
    }

    /// What the chrome does with its fold grace timer after an event.
    enum Timer: Equatable {
        case keep
        case start
        case cancel
    }

    mutating func handle(_ event: Event) -> Timer {
        switch event {
        case .pointerEntered(let isOpen, let isDragging):
            isHovered = true
            // A tab dragged past the sphere must not open the toolbar over
            // the strip it is being dropped on.
            if !isOpen, !isSuppressed, !isDragging { isPeeking = true }
            return .cancel
        case .pointerExited:
            isHovered = false
            isSuppressed = false
            return foldAfterGrace
        case .menuOpened:
            isMenuOpen = true
            return .cancel
        case .menuClosed:
            isMenuOpen = false
            return isHovered ? .keep : foldAfterGrace
        case .graceElapsed:
            if !isHovered, !isMenuOpen { isPeeking = false }
            return .keep
        case .unpinned:
            isSuppressed = true
            isPeeking = false
            return .cancel
        case .pinned:
            // It opens at once even when crowded tabs keep a pinned toolbar
            // folded.
            isPeeking = true
            return .cancel
        case .dismissed:
            isPeeking = false
            isHovered = false
            isSuppressed = false
            return .cancel
        }
    }

    /// An open peek folds once the grace period passes without the pointer
    /// or a menu holding it.
    private var foldAfterGrace: Timer {
        isPeeking && !isMenuOpen ? .start : .cancel
    }
}
