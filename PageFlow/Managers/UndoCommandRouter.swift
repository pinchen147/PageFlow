import AppKit
import Observation

/// Edit commands belong to the focused text field or editor while it is editing:
/// the Find bar, a PDF comment, a book's note, a Markdown comment. An empty field
/// history must never fall through to the document's Undo stack, where ⌘Z would
/// remove the mark a note belongs to. The Markdown editor is an editor too, and
/// its history is the document's stack, so routing to it changes nothing. A table
/// cell's editor keeps no history: its keystrokes are source edits on that stack,
/// so its commands stay the document's.
@MainActor
@Observable
final class UndoCommandRouter {
    private struct FieldState: Equatable {
        var responderID: ObjectIdentifier?
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
        if let field = commandOwner { return Self.availability(of: field) }
        return fallback
    }

    /// Menu commands also use this observation to leave an editable field's
    /// shortcuts with that field. Resolve live ownership again at invocation.
    var focusedTextView: NSTextView? {
        _ = fieldState
        return keyWindow()?.firstResponder as? NSTextView
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

    private var commandOwner: NSTextView? {
        guard let field = keyWindow()?.firstResponder as? NSTextView,
              field.isFieldEditor || (field.isEditable && field.allowsUndo) else { return nil }
        return field
    }

    private func commandManager(fallback: UndoManager?) -> UndoManager? {
        if let field = commandOwner { return field.allowsUndo ? field.undoManager : nil }
        return fallback
    }

    private static func availability(of field: NSTextView) -> UndoAvailability {
        guard field.allowsUndo, let manager = field.undoManager else { return UndoAvailability() }
        // Reading canRedo can settle registrations and posts a checkpoint. Do
        // not observe checkpoints: doing so would recursively refresh this read.
        return UndoAvailability(manager)
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
        let field = commandOwner
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
        let updated = FieldState(responderID: window?.firstResponder.map(ObjectIdentifier.init),
                                 ownsCommands: field != nil, availability: field.map(Self.availability(of:)) ?? UndoAvailability())
        if updated != fieldState { fieldState = updated }
    }
}
