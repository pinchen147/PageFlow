import AppKit
import Observation

/// Edit commands belong to the focused native field while it is editing. An
/// empty field history must never fall through to the document's Undo stack.
@MainActor
@Observable
final class UndoCommandRouter {
    private struct FieldState: Equatable {
        var ownsCommands = false
        var availability = UndoAvailability()
    }

    private var fieldState = FieldState()
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private weak var observedManager: UndoManager?
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []
    /// The window whose first responder owns edit commands: the app's key
    /// window. Tests name theirs, since a test host started in the background
    /// is never allowed to become active.
    @ObservationIgnored private let keyWindow: () -> NSWindow?

    init(keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow = keyWindow
        _ = NSApplication.shared
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification, NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification, NSControl.textDidChangeNotification
        ]
        focusObservers = names.map { name in
            NotificationCenter.default.addMainActorObserver(forName: name) { [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    deinit {
        for observer in focusObservers + undoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        responderObservation?.invalidate()
    }

    func availability(fallback: UndoAvailability) -> UndoAvailability {
        // Observe the cached snapshot for menu invalidation, but resolve actual
        // focus again so a command never uses the previous field or window.
        _ = fieldState
        if let field = fieldEditor { return Self.availability(of: field) }
        return fallback
    }

    func undo(fallback: UndoManager?) {
        let manager = commandManager(fallback: fallback)
        if manager?.canUndo == true { manager?.undo() }
        refresh()
    }

    func redo(fallback: UndoManager?) {
        let manager = commandManager(fallback: fallback)
        if manager?.canRedo == true { manager?.redo() }
        refresh()
    }

    private var fieldEditor: NSTextView? {
        guard let field = keyWindow()?.firstResponder as? NSTextView, field.isFieldEditor else { return nil }
        return field
    }

    private func commandManager(fallback: UndoManager?) -> UndoManager? {
        if let field = fieldEditor { return field.allowsUndo ? field.undoManager : nil }
        return fallback
    }

    private static func availability(of field: NSTextView) -> UndoAvailability {
        guard field.allowsUndo, let manager = field.undoManager else { return UndoAvailability() }
        // Reading canRedo can settle registrations and posts a checkpoint. Do
        // not observe checkpoints: doing so would recursively refresh this read.
        let canRedo = manager.canRedo
        return UndoAvailability(canUndo: manager.canUndo, canRedo: canRedo)
    }

    private func refresh() {
        let window = keyWindow()
        if observedWindow !== window {
            responderObservation?.invalidate()
            observedWindow = window
            responderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        let field = fieldEditor
        let manager = field?.undoManager
        if observedManager !== manager {
            undoObservers.forEach(NotificationCenter.default.removeObserver(_:))
            observedManager = manager
            let names: [Notification.Name] = [
                .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange
            ]
            undoObservers = manager.map { manager in
                names.map { name in
                    NotificationCenter.default.addMainActorObserver(forName: name, object: manager) { [weak self] in
                        self?.refresh()
                    }
                }
            } ?? []
        }
        let updated = FieldState(ownsCommands: field != nil, availability: field.map(Self.availability(of:)) ?? UndoAvailability())
        if updated != fieldState { fieldState = updated }
    }
}
