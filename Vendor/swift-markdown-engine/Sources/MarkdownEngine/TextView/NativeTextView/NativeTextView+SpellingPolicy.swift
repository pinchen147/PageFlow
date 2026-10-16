//
//  NativeTextView+SpellingPolicy.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Spell-check suppression inside code spans, code blocks, LaTeX, and other
//  coordinator-flagged tokens — anything that should be exempt from the
//  default underline pass.
//

import AppKit

extension NativeTextView {
    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        // Only the live editor suppresses markers inside code, math and link
        // syntax, through the coordinator's cached parse. A view with no
        // coordinator (the print view, a view mid-mount) takes the marker as
        // is: the old fallback re-parsed the whole document per misspelling.
        if value != 0, let coordinator = delegate as? NativeTextViewCoordinator {
            let text = self.string
            if coordinator.isInsideCode(range: charRange, in: text) { return }
            if coordinator.isInsideLatex(location: charRange.location, in: text) { return }
            if coordinator.isInsideSpellcheckSuppressedToken(range: charRange, in: text) { return }
        }
        super.setSpellingState(value, range: charRange)
    }
}
