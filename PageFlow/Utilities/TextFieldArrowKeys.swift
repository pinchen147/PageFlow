//
//  TextFieldArrowKeys.swift
//  PageFlow
//
//  The Go menu's page commands sit on ⌘-arrows by default. A menu's key
//  equivalent reaches the menu before a text field's own handling, so with one
//  of these keys ⌘↓ would turn the page instead of moving the caret.
//

import AppKit

enum TextFieldArrowKeys {
    /// Hands an arrow key that reached a menu command to the text field being
    /// typed in. Returns whether it did; the command then does nothing.
    static func passOn(_ event: NSEvent?, to responder: NSResponder?) -> Bool {
        guard let event, event.type == .keyDown, let textView = responder as? NSTextView, textView.isEditable,
              let key = event.specialKey, [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key) else { return false }
        textView.keyDown(with: event)
        return true
    }
}
