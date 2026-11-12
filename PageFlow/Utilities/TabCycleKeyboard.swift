//
//  TabCycleKeyboard.swift
//  PageFlow
//
//  The keys behind Ctrl-Tab. A local event monitor, because two things can't
//  come from a menu item: the release of Control, which ends a cycle, and going
//  ahead of the focused view, where a note or comment editor would take ⌃⇥ for
//  itself. Only a document window's keys are taken, so Settings can record the
//  chord and a sheet or panel keeps its own.
//

import AppKit

@MainActor
final class TabCycleKeyboard {
    static let shared = TabCycleKeyboard()

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// The window with a cycle running, and the modifiers that keep it running.
    private weak var cycling: TabManager?
    private var heldModifiers: NSEvent.ModifierFlags = []
    var isFullKeyboardAccessEnabled: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, in: event.window)
        }
        observeCycleEnders()
    }

    func observeCycleEnders() {
        // Control can go up in another app, where no event of it reaches this one.
        observers.append(NotificationCenter.default.addMainActorObserver(forName: NSApplication.didResignActiveNotification) { [weak self] in
            self?.endCycle()
        })
        // A menu's tracking loop keeps the release of Control from the monitor (ADR-0005).
        observers.append(NotificationCenter.default.addMainActorObserver(forName: NSMenu.didBeginTrackingNotification) { [weak self] in
            self?.endCycle()
        })
    }

    /// The monitor's whole decision: returns the event to pass it on, nil to take it.
    func handle(_ event: NSEvent, in window: NSWindow?, keyWindow: NSWindow? = nil,
                tabManager: @MainActor (NSWindow) -> TabManager? = { @MainActor in WindowRegistry.shared.tabManager(for: $0) }) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            if cycling != nil, !event.modifierFlags.isSuperset(of: heldModifiers) { endCycle() }
            return event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click takes over, and may open a context menu (see `observeCycleEnders`).
            endCycle()
            return event
        case .keyDown:
            guard let (shortcut, direction) = Self.recentTabCommand(matching: event) else {
                // The View menu can still have Reset disabled for the tab we just left.
                // Resolve the key against the document that will actually receive it.
                guard ShortcutModel.current(for: "actualSize").matches(event: event),
                      let window, window === (keyWindow ?? NSApp.keyWindow), window.attachedSheet == nil,
                      !TabDragController.shared.isActive, let manager = tabManager(window),
                      manager.canResetZoom else { return event }
                if let field = window.firstResponder as? NSTextView, field.isEditable {
                    guard !field.isFieldEditor, !field.hasMarkedText(),
                          let note = manager.activeMarkdownContent, !note.ownsAnnotationResponder(field),
                          let surface = note.retainedEditorSurface, field.isDescendant(of: surface.nativeView)
                    else { return event }
                }
                manager.resetZoom()
                return nil
            }
            guard let window, let manager = tabManager(window),
                  !TabDragController.shared.isActive else { return event }
            // With nowhere to go the key stays macOS's, which uses it to move focus.
            guard manager.tabs.count > 1 else { return event }
            // Past here it's ours. A composition has to finish first, and a
            // held-down Tab shouldn't race through the tabs.
            let isComposing = (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
            guard !isComposing, !event.isARepeat else { return nil }
            // Full Keyboard Access leaves a text view by this key, since Tab types
            // there. Move focus here: passed on, the enabled menu item would take it.
            if isFullKeyboardAccessEnabled(), window.firstResponder is NSTextView {
                if direction == .older { window.selectNextKeyView(nil) } else { window.selectPreviousKeyView(nil) }
                return nil
            }
            if cycling !== manager { endCycle() }
            manager.stepRecentTab(direction)
            heldModifiers = shortcut.nsModifierFlags.subtracting(.shift)
            if manager.tabRecency.isCycling, event.modifierFlags.isSuperset(of: heldModifiers), !heldModifiers.isEmpty {
                cycling = manager
            } else {
                manager.commitRecentTabCycle()
            }
            return nil
        default:
            return event
        }
    }

    private func endCycle() {
        cycling?.commitRecentTabCycle()
        cycling = nil
    }

    private static func recentTabCommand(matching event: NSEvent) -> (ShortcutModel, TabRecency.Direction)? {
        let older = ShortcutModel.current(for: "selectRecentTab")
        if older.matches(event: event) { return (older, .older) }
        let newer = ShortcutModel.current(for: "selectRecentTabReversed")
        if newer.matches(event: event) { return (newer, .newer) }
        return nil
    }
}
