import AppKit

extension NativeSemanticTextView {
    func drawSemanticCodeBackgrounds() {
        guard let owner = semanticCoordinator, let storage = textStorage, let layout = textLayoutManager,
              let content = layout.textContentManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        owner.configuration.services.syntaxHighlighter.backgroundColor().setFill()
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard offset >= 0, offset < storage.length,
                  case .code? = storage.attribute(NativeSemanticAttributes.paragraphRole, at: offset, effectiveRange: nil) as? NativeSemanticParagraphRole else { return true }
            let rect = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            NSRect(x: textContainerOrigin.x, y: rect.minY, width: textContainer?.size.width ?? rect.width, height: rect.height).fill()
            return true
        }
    }

    func drawSemanticQuoteRules() {
        guard let owner = semanticCoordinator, let storage = textStorage, let layout = textLayoutManager,
              let content = layout.textContentManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        owner.configuration.theme.mutedText.withAlphaComponent(0.45).setFill()
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard offset >= 0, offset < storage.length,
                  case .quote(let depth)? = storage.attribute(NativeSemanticAttributes.paragraphRole, at: offset, effectiveRange: nil) as? NativeSemanticParagraphRole else { return true }
            let rect = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let step = (font?.pointSize ?? 16) * 1.5
            for index in 0..<max(1, depth) {
                NSRect(x: textContainerOrigin.x + CGFloat(index) * step + 4, y: rect.minY + 2,
                       width: 2, height: max(1, rect.height - 4)).fill()
            }
            return true
        }
    }
}
