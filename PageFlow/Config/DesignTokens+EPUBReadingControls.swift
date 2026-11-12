//
//  DesignTokens+EPUBReadingControls.swift
//  PageFlow
//
//  Sizes for the EPUB reader's text settings and highlight styles.
//

import AppKit

extension DesignTokens {
    /// The paragraph spacing slider's step, in ems.
    static let epubParagraphSpacingStep: CGFloat = 0.25
    /// Room for a setting's value beside its slider.
    static let epubSettingValueWidth: CGFloat = 36
    /// The typography popover's width.
    static let epubTypographyPopoverWidth: CGFloat = 280
    /// How far an underline highlight's colour is deepened toward black on
    /// light and sepia paper, where a pale line would barely show.
    static let epubUnderlineDeepening: CGFloat = 0.25
    /// An underline darker than this takes the text colour on dark paper.
    static let epubUnderlineLeastBrightnessOnDark: CGFloat = 0.35
}
