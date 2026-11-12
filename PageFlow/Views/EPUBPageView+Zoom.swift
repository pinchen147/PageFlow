//
//  EPUBPageView+Zoom.swift
//  PageFlow
//
//  Opening a page's figure or table large: double-click an image, or use
//  Zoom Image / Zoom Table in the context menu. The table is the chapter's
//  whole table, even where it runs over several pages.
//

import AppKit
import EPUBKit

extension EPUBPageView {
    // The text view delegate's own selector: the conformance is on the class.
    @objc(textView:doubleClickedOnCell:inRect:atIndex:)
    func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol,
                  in cellFrame: NSRect, at charIndex: Int) {
        zoomImage(at: charIndex)
    }

    /// Zoom Image and Zoom Table for what is under the pointer.
    func zoomMenuItems(at charIndex: Int) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if attachment(at: charIndex) != nil {
            items.append(EPUBMenuItem("Zoom Image") { [weak self] in self?.zoomImage(at: charIndex) })
        }
        if tableInChapter(at: charIndex) != nil {
            items.append(EPUBMenuItem("Zoom Table") { [weak self] in self?.zoomTable(at: charIndex) })
        }
        return items
    }

    /// The book image drawn at a character on this page, if one is.
    func attachment(at index: Int) -> NSTextAttachment? {
        guard let storage = textView.textStorage, index >= 0, index < storage.length,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              EPUBAttachmentImage.isImage(attachment) else { return nil }
        return attachment
    }

    @discardableResult
    func zoomImage(at index: Int) -> Bool {
        guard let attachment = attachment(at: index) else { return false }
        EPUBZoomPanel.showImage(of: attachment, title: zoomTitle("Figure"), over: window, origin: content?.document)
        return true
    }

    /// The table holding a character on this page, as a range of its chapter.
    func tableInChapter(at index: Int) -> NSRange? {
        guard let content, let text = content.text, let page = content.range,
              index >= 0, index < page.length, NSMaxRange(page) <= text.length else { return nil }
        return EPUBZoomTable.range(at: page.location + index, in: text)
    }

    @discardableResult
    func zoomTable(at index: Int) -> Bool {
        guard let content, let text = content.text, let range = tableInChapter(at: index) else { return false }
        EPUBZoomPanel.showTable(text.attributedSubstring(from: range),
                                background: EPUBTextStyling.themeBackgroundColor(for: content.palette),
                                title: zoomTitle("Table"), over: window, origin: content.document, sourcePalette: content.palette)
        return true
    }

    private func zoomTitle(_ kind: String) -> String {
        guard let header = content?.header, !header.isEmpty else { return kind }
        return "\(kind) — \(header)"
    }
}
