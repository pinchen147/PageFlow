import AppKit

extension MarkdownEditorConfiguration {
    func hasSamePresentation(as other: Self) -> Bool {
        theme == other.theme && markers == other.markers && codeBlock == other.codeBlock
            && inlineCode == other.inlineCode && lists == other.lists && headings == other.headings
            && imageEmbed == other.imageEmbed && blockLatex == other.blockLatex
            && diagramLanguages == other.diagramLanguages
            && checkbox == other.checkbox && link == other.link && paragraph == other.paragraph
    }

    func hasSameLayout(as other: Self) -> Bool {
        overscroll == other.overscroll && dragSelection == other.dragSelection
            && safeAreaInsets == other.safeAreaInsets && scrollers == other.scrollers
            && textInsets == other.textInsets && readingWidth == other.readingWidth
            && centersZoomedOutColumn == other.centersZoomedOutColumn
            && showsHiddenContentRow == other.showsHiddenContentRow
    }

    func hasSameBus(as other: Self) -> Bool {
        let lhs = services.bus
        let rhs = other.services.bus
        return lhs.scopeByObject == rhs.scopeByObject
            && lhs.applyUnderlineRequest == rhs.applyUnderlineRequest
            && lhs.applyBoldRequest == rhs.applyBoldRequest
            && lhs.applyItalicRequest == rhs.applyItalicRequest
            && lhs.applyHeadingRequest == rhs.applyHeadingRequest
            && lhs.selectionBoldDidChange == rhs.selectionBoldDidChange
            && lhs.selectionItalicDidChange == rhs.selectionItalicDidChange
            && lhs.findScrollToRange == rhs.findScrollToRange
            && lhs.findClearHighlights == rhs.findClearHighlights
    }

    func hasSameServices(as other: Self) -> Bool {
        sameService(services.images, other.services.images, defaultType: NoOpEmbeddedImageProvider.self)
            && sameService(services.wikiLinks, other.services.wikiLinks, defaultType: NoOpWikiLinkResolver.self)
            && sameService(services.syntaxHighlighter, other.services.syntaxHighlighter, defaultType: PlainTextSyntaxHighlighter.self)
            && sameService(services.latex, other.services.latex, defaultType: NoOpLatexRenderer.self)
            && sameService(services.diagram, other.services.diagram, defaultType: NoOpBlockDiagramRenderer.self)
    }

    private func sameService(_ lhs: Any, _ rhs: Any, defaultType: Any.Type) -> Bool {
        if type(of: lhs) == defaultType && type(of: rhs) == defaultType { return true }
        // Non-default value services have no equality contract; refresh them
        // conservatively. Reference services use stable instance identity.
        guard type(of: lhs) is AnyClass, type(of: rhs) is AnyClass else { return false }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }
}
