import AppKit

extension NativeSemanticDocumentCoordinator {
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length else { return false }
        if let descriptor = storage.attribute(NativeSemanticAttributes.link, at: charIndex, effectiveRange: nil) as? SemanticInlineLink {
            switch descriptor {
            case .wiki(let target): onLinkClick?(target); return true
            case .url(let destination, _):
                guard let url = URL(string: destination) else { return true }
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                else { onOpenLocalLink?(url) }
                return true
            }
        }
        return false
    }

    func acceptFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard textView.isEditable, !hasActiveComposition, !isWritingToolsActive else { return false }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let documents = urls.filter { opensDroppedFile?($0) == true }
        let images = urls.filter { url in
            ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"].contains(url.pathExtension.lowercased())
        }
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        var accepted = documents.isEmpty ? false : onDropDocuments?(documents) == true
        if (!images.isEmpty || imageData != nil), let importer = onImportImages {
            let expected = revision
            let selection = textView.selectedRange()
            importer(MarkdownImageDrop(fileURLs: images, imageData: imageData)) { [weak self] sources in
                guard let self, !sources.isEmpty else { return }
                guard self.revision == expected, !self.textView.hasMarkedText(), !self.isWritingToolsActive else {
                    self.onExportFailure?(AdmissionFailure.activeComposition)
                    return
                }
                self.textView.setSelectedRange(selection)
                _ = self.pasteText(sources.joined(separator: "\n"), asMarkdown: true)
            }
            accepted = true
        }
        return accepted
    }
}
