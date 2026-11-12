//
//  TabRecency.swift
//  PageFlow
//
//  One window's tabs in most-recently-used order, behind Ctrl-Tab. Pure: the
//  window's TabManager reports what happens, and the keyboard reports when
//  Control goes up.
//
//  A press of Ctrl-Tab starts a cycle. Each tap moves through the order as it
//  stood when the cycle began, and only the release of Control puts the tab it
//  landed on at the head. So a tap and release goes to the previous tab, a
//  second one comes back, and tapping while holding walks further back.
//

import Foundation

struct TabRecency: Equatable {
    enum Direction {
        /// Toward less recently used tabs (Ctrl-Tab).
        case older
        /// Back toward more recently used tabs (Ctrl-Shift-Tab).
        case newer
    }

    /// Most recently used first.
    private(set) var order: [UUID] = []
    /// While a cycle runs, the place in `order` it has reached.
    private(set) var cyclePosition: Int?

    var isCycling: Bool { cyclePosition != nil }

    /// `id` is now the active tab. A cycle's own step leaves the order alone;
    /// anything else (a click, ⌘1, an opened document) ends the cycle.
    mutating func noteActivated(_ id: UUID?) {
        if let cyclePosition, order[cyclePosition] == id { return }
        cyclePosition = nil
        guard let id else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// A tab arrived in this window without being shown: nothing here has used it yet.
    mutating func noteArrivedHidden(_ id: UUID) {
        if !order.contains(id) { order.append(id) }
    }

    /// The tab left this window: closed, failed to open, or moved away.
    mutating func remove(_ id: UUID) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        guard let position = cyclePosition else { return }
        if index == position {
            cyclePosition = nil
        } else if index < position {
            cyclePosition = position - 1
        }
    }

    /// One tap: the tab to show next, or nil when there is nowhere to go.
    /// `tabs` and `active` are the window's own, so a tab this order never heard
    /// of still takes part, behind the ones that have been used.
    mutating func step(_ direction: Direction, tabs: [UUID], active: UUID?) -> UUID? {
        for id in order where !tabs.contains(id) { remove(id) }
        for id in tabs where !order.contains(id) { order.append(id) }
        guard let active, order.contains(active) else { return nil }
        if cyclePosition == nil || cyclePosition.map({ order[$0] }) != active {
            noteActivated(active)
        }
        guard order.count > 1 else { return nil }
        let position = cyclePosition ?? 0
        let next = (position + (direction == .older ? 1 : order.count - 1)) % order.count
        cyclePosition = next
        return order[next]
    }

    /// Control went up: the tab the cycle reached becomes the most recent.
    mutating func commit() {
        guard let position = cyclePosition else { return }
        cyclePosition = nil
        let id = order.remove(at: position)
        order.insert(id, at: 0)
    }
}
