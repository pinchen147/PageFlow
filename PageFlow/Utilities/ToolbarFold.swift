//
//  ToolbarFold.swift
//  PageFlow
//
//  The pure decision of whether the floating toolbar holds its full width in
//  the top row, sits folded into its glass sphere, or springs open over the
//  tabs.
//

import CoreGraphics

/// The toolbar's fold state. "Always show toolbar" pins it open; unpinned it
/// rests as a sphere and opens over the tabs while the pointer is on it. A
/// pinned toolbar still folds while the tabs wouldn't fit beside it open.
struct ToolbarFold: Equatable {
    /// "Always show toolbar".
    var isPinned: Bool
    /// The pointer opened the folded toolbar; it floats over the tabs.
    var isPeeking: Bool
    /// What the tab strip needs to show all its tabs.
    var tabsWidth: CGFloat
    /// The tab strip and the toolbar slot, as laid out now.
    var tabStripWidth: CGFloat
    var slotWidth: CGFloat
    /// The open toolbar's natural width.
    var openWidth: CGFloat

    /// Strip plus slot is the same whether the toolbar holds its width or
    /// not, so folding never flips the decision that caused it.
    var holdsWidth: Bool {
        isPinned && tabsWidth <= tabStripWidth + slotWidth - openWidth + 0.5
    }

    var isOpen: Bool { holdsWidth || isPeeking }

    /// Open over the tabs without holding its width: a peek, including one
    /// of a pinned toolbar that crowded tabs keep folded.
    var isFloating: Bool { isOpen && !holdsWidth }

    /// The open toolbar's trailing button pins an unpinned toolbar (keeping
    /// a peek open) and unpins a pinned one, even one that crowded tabs keep
    /// folded: pinning that would change nothing.
    var offersPin: Bool { isOpen && !isPinned }

    /// How far the open toolbar reaches over the tab strip: only while it
    /// floats there.
    var overhang: CGFloat {
        isFloating ? max(0, openWidth - slotWidth) : 0
    }

    /// The part of the tab strip under the floating toolbar.
    var coveredStripWidth: CGFloat { min(overhang, tabStripWidth) }

    /// The floating toolbar reaches past the whole strip, over the tab
    /// switcher in front of it.
    var coversTabSwitcher: Bool { overhang > tabStripWidth }

    /// How far left of the slot's trailing edge the pointer opens the toolbar
    /// (the peek zone): the part of the row the open toolbar covers, so it
    /// opens only where it will be and the pointer needn't land on the
    /// sphere. Folded, that stops at the tabs (`tabsWidth` is the tabs at
    /// rest, so a slid-out sliver doesn't move it); open, it is the whole
    /// toolbar, so the pointer can travel over it.
    var peekReach: CGFloat {
        let folded = slotWidth + min(max(0, openWidth - slotWidth), max(0, tabStripWidth - tabsWidth))
        return isOpen ? max(folded, openWidth) : folded
    }
}
