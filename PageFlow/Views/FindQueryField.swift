import SwiftUI

/// Uses the window's shared field editor for typing, selection, composition and Undo.
struct FindQueryField: NSViewRepresentable {
    let driver: any FindDriving
    @Binding var isVisible: Bool
    let focusRequest: Int

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: DesignTokens.searchFieldFontSize)
        field.placeholderString = "Search"
        field.setAccessibilityLabel("Find text")
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.allowsUndo = true
        field.delegate = field
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.queryField = self
        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true && field.stringValue != driver.query {
            field.stringValue = driver.query
        }
        field.requestFocusIfNeeded()
    }

    static func dismantleNSView(_ field: Field, coordinator: Void) {
        field.queryField = nil
        field.delegate = nil
    }

    /// The window shares its field editor. Only the query currently using it can offer a match.
    static func matchToCopy(firstResponder: NSResponder?) -> String? {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor,
              editor.selectedRange().length == 0 else { return nil }
        let owner: AnyObject? = editor.delegate
        guard let field = owner as? Field, field.currentEditor() === editor else { return nil }
        return field.queryField?.driver.currentMatchText
    }

    final class Field: NSTextField, NSTextFieldDelegate {
        fileprivate var queryField: FindQueryField?
        private var fulfilledFocusRequest: Int?
        private var focusScheduled = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for event in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)),
                                                       name: event, object: window)
            }
            requestFocusIfNeeded()
        }

        @objc private func windowUpdated(_ notification: Notification) {
            requestFocusIfNeeded()
        }

        private var needsFocus: Bool {
            guard let queryField, queryField.isVisible, let window, window.isKeyWindow,
                  !isHiddenOrHasHiddenAncestor else { return false }
            return fulfilledFocusRequest != queryField.focusRequest || window.firstResponder === window
        }

        fileprivate func requestFocusIfNeeded() {
            guard needsFocus, !focusScheduled else { return }
            focusScheduled = true
            // Let AppKit finish the current window or tab transition before changing responder.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                focusScheduled = false
                guard needsFocus, let window else { return }
                if currentEditor() == nil || window.firstResponder !== currentEditor() {
                    window.makeFirstResponder(self)
                }
                if let editor = currentEditor(), window.firstResponder === editor {
                    fulfilledFocusRequest = queryField?.focusRequest
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            queryField?.driver.setQuery(stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            queryField?.driver.next()
            return true
        }
    }
}
