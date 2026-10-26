//
//  NativeTextView+TaskCheckbox.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Hit-test for `[ ]` / `[x]` checkbox glyphs and toggle the underlying text
//  + `.taskCheckbox` attribute, then nudge the coordinator to restyle the
//  enclosing paragraph.
//

import AppKit

extension NativeTextView {
    func toggleTaskCheckboxIfHit(event: NSEvent) -> Bool? {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )

        // Rect-based hit-test — characterIndex(for:) mis-maps clicks on lines
        // whose `[ ]` chars are hidden under the bullet/checkbox overlay.
        let fullRange = NSRange(location: 0, length: storage.length)
        var hitRange: NSRange? = nil
        var hitIsChecked = false
        storage.enumerateAttribute(.taskCheckbox, in: fullRange, options: []) { value, attrRange, stop in
            guard let isChecked = value as? Bool else { return }
            let rect = bridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
            if rect.contains(containerPoint) {
                hitRange = attrRange
                hitIsChecked = isChecked
                stop.pointee = true
            }
        }
        guard let effectiveRange = hitRange else { return nil }

        let nsText = storage.string as NSString
        let checkboxText = nsText.substring(with: effectiveRange)
        guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return nil }

        let replacement = hitIsChecked ? "[ ]" : "[x]"
        if shouldChangeText(in: effectiveRange, replacementString: replacement) {
            storage.replaceCharacters(in: effectiveRange, with: replacement)
            storage.addAttribute(.taskCheckbox, value: !hitIsChecked, range: effectiveRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: effectiveRange)
            didChangeText()
            bridge.invalidateDisplay(forCharacterRange: effectiveRange)
            if let coord = delegate as? NativeTextViewCoordinator {
                let paragraph = (storage.string as NSString).paragraphRange(for: effectiveRange)
                coord.restyleParagraphs([paragraph], in: self)
            }
        }
        return true
    }
}
