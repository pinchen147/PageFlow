import AppKit

extension MarkdownTableEditingSession {
    /// Word formatting does not move the table, but Undo may run after native
    /// navigation has focused a different cell or table.
    struct FormattingSelection {
        let tableLocation: Int
        let row: Int
        let column: Int
        let before: NSRange
        let after: NSRange

        var inverse: Self {
            Self(tableLocation: tableLocation, row: row, column: column, before: after, after: before)
        }
    }

    /// Cached against the decoded cell buffer; movement never reparses an unchanged cell.
    var emphasisProjection: MarkdownEmphasisProjection {
        if let projection = cachedEmphasisProjection, projection.source.utf16.elementsEqual(editor.string.utf16) { return projection }
        let projection = MarkdownEmphasisProjection(source: editor.string, scope: .inline)
        cachedEmphasisProjection = projection
        return projection
    }

    var emphasisVisibleSelection: NSRange {
        let projection = emphasisProjection
        let selection = editor.selectedRange()
        let start = projection.visibleOffset(forSourceOffset: selection.location)
        let end = projection.visibleOffset(forSourceOffset: NSMaxRange(selection))
        return NSRange(location: start, length: end - start)
    }

    var inheritedCellEmphasisTraits: MarkdownEmphasisTraits {
        let projection = emphasisProjection
        let offset = editor.selectedRange().location
        let visible = projection.visibleOffset(forSourceOffset: offset)
        if editor.selectedRange().length > 0 {
            return projection.traits(atVisibleOffset: visible, affinity: .downstream)
        }
        if visible == (projection.visibleText as NSString).length {
            return projection.traits(atVisibleOffset: visible, affinity: .upstream)
        }
        return projection.traits(atSourceOffset: offset)
    }

    var effectiveEmphasisTraits: MarkdownEmphasisTraits {
        emphasisTypingState.effectiveTraits(inheriting: inheritedCellEmphasisTraits)
    }

    func adoptCellEmphasisSelection() {
        guard !refreshing, !isComposing else { return }
        emphasisTypingState.adopt()
        normalizeEmphasisSelection()
        updateEmphasisTypingAttributes()
    }

    func normalizeEmphasisSelection() {
        normalizeCellRichBoundarySelection()
        let projection = emphasisProjection
        guard !projection.hiddenDelimiterRanges.isEmpty else { return }
        let selected = editor.selectedRange()
        let visible = emphasisVisibleSelection
        let downstream = projection.sourceOffset(forVisibleOffset: visible.location, affinity: .downstream)
        let upstream = projection.sourceOffset(forVisibleOffset: visible.location, affinity: .upstream)
        let prefersUpstream = visible.length == 0 && projection.traits(atSourceOffset: upstream).rawValue.nonzeroBitCount
            > projection.traits(atSourceOffset: downstream).rawValue.nonzeroBitCount
        let start = visible.length > 0 ? upstream : (prefersUpstream ? upstream : downstream)
        let end = visible.length == 0 ? start : projection.sourceOffset(forVisibleOffset: NSMaxRange(visible), affinity: .downstream)
        let normalized = NSRange(location: start, length: max(0, end - start))
        guard selected != normalized else { return }
        refreshing = true
        editor.setSelectedRange(normalized)
        refreshing = false
    }

    private func cellEmphasisIsLiteral(at offset: Int, projection: MarkdownEmphasisProjection) -> Bool {
        projection.tokens.contains {
            [.inlineCode, .inlineLatex, .codeBlock, .blockLatex].contains($0.kind) && NSLocationInRange(offset, $0.range)
        }
    }

    func toggleCellEmphasis(_ style: MarkdownInlineStyle) -> Bool {
        guard [.bold, .italic, .underline].contains(style) else { return false }
        let trait = MarkdownEmphasisTraits(style: style)
        guard editor.selectedRange().length == 0, !trait.isEmpty else { return false }
        let projection = emphasisProjection
        if cellEmphasisIsLiteral(at: editor.selectedRange().location, projection: projection) { return true }
        if case .word(let plan) = MarkdownNativeWordFormatting.resolve(style: style, sourceOffset: editor.selectedRange().location,
            projection: projection, navigator: cellWordNavigator, writingDirection: editor.baseWritingDirection) {
            guard let plan else { return true }
            let before = editor.selectedRange()
            endTypingRun()
            refreshing = true
            editor.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
            editor.setSelectedRange(plan.selectionAfter)
            refreshing = false
            emphasisTypingState.adopt()
            _ = commitInput(actionName: style.actionName, coalescing: false, selectionBefore: before)
            return true
        }
        emphasisTypingState.toggle(trait, inheriting: inheritedCellEmphasisTraits)
        endTypingRun()
        updateEmphasisTypingAttributes()
        coordinator?.selectionBar?.setNeedsUpdate()
        return true
    }

    /// Source Undo reloads this same cell before restoring the command's native selection.
    func restoreFormattingSelection(_ change: FormattingSelection) {
        if table?.range.location != change.tableLocation {
            guard begin(range: NSRange(location: change.tableLocation, length: 0),
                        row: change.row, column: change.column, selecting: .start) else { return }
        } else if row != change.row || column != change.column {
            select(row: change.row, column: change.column)
        }
        let selection = change.after
        guard isActive, row == change.row, column == change.column,
              selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= (editor.string as NSString).length else { return }
        let wasRefreshing = refreshing
        refreshing = true
        editor.setSelectedRange(selection)
        refreshing = wasRefreshing
        updateEmphasisTypingAttributes()
    }

    func updateEmphasisTypingAttributes() {
        guard let coordinator else { return }
        let base = MarkdownTableLayout.cellFont(for: coordinator.baseFontAndStyle().0)
        let resolved = cellEmphasisFont(base, traits: effectiveEmphasisTraits)
        var attributes = editor.typingAttributes
        attributes[.font] = resolved.font
        attributes[.underlineStyle] = effectiveEmphasisTraits.contains(.underline) ? NSUnderlineStyle.single.rawValue : 0
        attributes[.foregroundColor] = row == 0 ? coordinator.configuration.theme.tableHeaderText : coordinator.configuration.theme.bodyText
        attributes[.kern] = nil
        editor.typingAttributes = attributes
    }

    private func cellEmphasisFont(_ base: NSFont, traits: MarkdownEmphasisTraits) -> (font: NSFont, synthetic: Bool) {
        var symbolic = base.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        let result = ItalicFallback.resolveFont(traits: symbolic, descriptor: base.fontDescriptor,
                                               size: base.pointSize, fallback: base)
        return (result.font, result.syntheticOblique)
    }

    /// Compose styles over source storage, then conceal only parser-admitted emphasis delimiters.
    func applyCellEmphasis(baseFont: NSFont) {
        guard !isComposing, let storage = editor.textStorage, storage.length > 0 else { return }
        let projection = emphasisProjection
        let ns = editor.string as NSString
        let boundaries = Set([0, storage.length] + projection.styleSpans.flatMap {
            [$0.token.contentRange.location, NSMaxRange($0.token.contentRange)]
        }).sorted()
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let range = NSRange(location: start, length: end - start)
            let traits = projection.styleSpans.reduce(into: MarkdownEmphasisTraits()) { result, span in
                if NSIntersectionRange(span.token.contentRange, range).length > 0 { result.formUnion(span.traits) }
            }
            let resolved = cellEmphasisFont(baseFont, traits: traits)
            storage.addAttribute(.font, value: resolved.font, range: range)
            storage.addAttribute(.underlineStyle, value: traits.contains(.underline) ? NSUnderlineStyle.single.rawValue : 0, range: range)
            for overlay in ItalicFallback.syntheticItalicOverlays(forRun: resolved.font, range: range, in: ns,
                                                                 noItalicFace: resolved.synthetic) {
                storage.addAttributes(overlay.attributes, range: overlay.range)
            }
        }
        let markerFont = NSFont.systemFont(ofSize: 0.01)
        for range in projection.hiddenDelimiterRanges {
            storage.addAttributes([.font: markerFont, .foregroundColor: NSColor.clear,
                                   .kern: -HeadingHelpers.hiddenRunWidth(ns.substring(with: range), font: markerFont)], range: range)
        }
        updateEmphasisTypingAttributes()
    }

    /// Code spans and links in the cell's source look as the grid draws them
    /// (`MarkdownStyler.formattedCellString`): code in the cell's monospaced
    /// face on its chip, link text in the link colour, underlined. Their
    /// recognized markers remain concealed while their content stays editable.
    func applyCellInlineStyles(baseFont: NSFont) {
        guard !isComposing, let coordinator, let storage = editor.textStorage, storage.length > 0 else { return }
        let theme = coordinator.configuration.theme
        let codeBackground = coordinator.configuration.services.syntaxHighlighter.backgroundColor()
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let linkAttributes = MarkdownStyler.cellLinkAttributes(theme: theme)
        var links: [NSRange] = []
        var concealed: [NSRange] = []
        func content(between markers: [NSRange]) -> NSRange? {
            guard let first = markers.first, let last = markers.last, markers.count > 1 else { return nil }
            return NSRange(location: NSMaxRange(first), length: max(0, last.location - NSMaxRange(first)))
        }
        func code(_ range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                storage.addAttribute(.font, value: MarkdownStyler.cellCodeFont(codeFont, inheriting: value as? NSFont ?? baseFont), range: run)
            }
            storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
        }
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let range, let content):
                    code(content)
                    for marker in [NSRange(location: range.location, length: content.location - range.location),
                                   NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
                    where marker.length > 0 { concealed.append(marker) }
                case .link(let range, let text, _, let markers, let children):
                    links.append(range)
                    storage.addAttributes(linkAttributes, range: text)
                    concealed += markers
                    concealed.append(NSRange(location: NSMaxRange(text), length: NSMaxRange(range) - NSMaxRange(text)))
                    walk(children)
                case .wikiLink(let range, let name, _, let markers):
                    links.append(range)
                    let label = name
                    storage.addAttributes(linkAttributes, range: label)
                    concealed += markers
                    concealed.append(NSRange(location: range.location, length: label.location - range.location))
                    concealed.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label)))
                case .emphasis(_, _, let markers, let children), .underline(_, let markers, let children):
                    concealed += markers
                    walk(children)
                case .strikethrough(_, let markers, let children):
                    if let content = content(between: markers) {
                        storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                               .strikethroughColor: theme.bodyText], range: content)
                    }
                    concealed += markers
                    walk(children)
                case .highlight(_, let markers, let children):
                    if let content = content(between: markers) {
                        storage.addAttribute(.backgroundColor, value: theme.highlight, range: content)
                    }
                    concealed += markers
                    walk(children)
                case .escape(_, _, let marker):
                    concealed.append(marker)
                case .inlineLatex:
                    // Focused cells edit the complete formula source, including dollars.
                    break
                case .image(let range, let alt, let destination, _):
                    let description = ImageAltTokens.parse((editor.string as NSString).substring(with: alt)).description
                    let label = description.isEmpty ? destination : NSRange(location: alt.location, length: description.utf16.count)
                    concealed.append(NSRange(location: range.location, length: label.location - range.location))
                    concealed.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label)))
                case .imageEmbed(let range, let target, _):
                    let ns = editor.string as NSString
                    let raw = ns.substring(with: target)
                    let name = ImageEmbedReference(content: raw)?.name ?? ImageAltTokens.parse(raw).description
                    let label = ns.range(of: name, range: target)
                    if label.location != NSNotFound {
                        concealed.append(NSRange(location: range.location, length: label.location - range.location))
                        concealed.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label)))
                    }
                case .text:
                    break
                }
            }
        }
        storage.beginEditing()
        walk(InlineParser.parse(editor.string))
        MarkdownStyler.styleBareLinks(in: storage, theme: theme, excluding: links)
        // Conceal after semantic styles so nested links/code cannot repaint syntax.
        let markerFont = NSFont.systemFont(ofSize: 0.01)
        for range in concealed where range.length > 0 {
            storage.addAttributes([.font: markerFont, .foregroundColor: NSColor.clear,
                                   .backgroundColor: NSColor.clear, .kern: -markerFont.pointSize], range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.strikethroughStyle, range: range)
        }
        storage.endEditing()
    }

    /// Input is planned in decoded source coordinates and committed by the existing table transaction.
    @discardableResult
    func insertCellEmphasisText(_ text: String, replacing range: NSRange) -> Bool {
        guard isActive, !isComposing, !isRangeMode, admittedSource() != nil else { return false }
        let projection = emphasisProjection
        let traits = effectiveEmphasisTraits
        guard !projection.hiddenDelimiterRanges.isEmpty || !traits.isEmpty || !emphasisTypingState.disabled.isEmpty else { return false }
        let target = range.location == NSNotFound ? editor.selectedRange() : range
        guard !cellEmphasisIsLiteral(at: target.location, projection: projection) else { return false }
        guard let result = emphasisReplacement(text, range: target, projection: projection, traits: traits) else { return false }
        pendingEditRange = target
        refreshing = true
        editor.string = result.text
        editor.setSelectedRange(result.selection)
        refreshing = false
        pendingEmphasisTypingBefore = emphasisTypingState
        // Manual delimiters can promote provisional italic to bold. Inherit
        // that new parse unless the user explicitly chose a typing override.
        let followsParsedStyle = emphasisTypingState.enabled.isEmpty && emphasisTypingState.disabled.isEmpty
        if !followsParsedStyle || text.isEmpty || !text.allSatisfy({ $0 == "*" || $0 == "_" }) {
            emphasisTypingState.retainTypingTraits(traits)
        }
        _ = commitInput()
        normalizeCommittedEmphasisCaret()
        return true
    }

    private func emphasisReplacement(_ text: String, range: NSRange, projection: MarkdownEmphasisProjection,
                                     traits: MarkdownEmphasisTraits) -> (text: String, selection: NSRange)? {
        let source = projection.source as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return nil }
        let plan: MarkdownEmphasisEditPlan?
        if range.length > 0 {
            let start = projection.visibleOffset(forSourceOffset: range.location)
            let end = projection.visibleOffset(forSourceOffset: NSMaxRange(range))
            plan = MarkdownEmphasisEditPlanner.replacement(text: text, visibleRange: NSRange(location: start, length: end - start),
                                                          traits: traits, projection: projection)
        } else {
            guard !text.isEmpty else { return (projection.source, range) }
            plan = MarkdownEmphasisEditPlanner.insertion(text: text, atSourceOffset: range.location, traits: traits, projection: projection)
        }
        guard let plan else { return nil }
        return (source.replacingCharacters(in: plan.replacementRange, with: plan.replacement), plan.selectionAfter)
    }

    func handleCellEmphasisCommand(_ selector: Selector) -> Bool {
        guard !isComposing, !isRangeMode else { return false }
        let projection = emphasisProjection
        guard !projection.hiddenDelimiterRanges.isEmpty || !emphasisTypingState.enabled.isEmpty || !emphasisTypingState.disabled.isEmpty else { return false }
        if cellEmphasisIsLiteral(at: editor.selectedRange().location, projection: projection) { return false }
        let selection = emphasisVisibleSelection
        let length = (projection.visibleText as NSString).length
        let command = NSStringFromSelector(selector)
        if command.hasPrefix("move"), command.contains("Word") {
            let navigator = cellWordNavigator
            navigator.string = projection.visibleText
            navigator.baseWritingDirection = editor.baseWritingDirection
            navigator.setSelectedRange(selection, affinity: editor.selectionAffinity, stillSelecting: false)
            navigator.doCommand(by: selector)
            let moved = navigator.selectedRange()
            let start = projection.sourceOffset(forVisibleOffset: moved.location, affinity: .downstream)
            let end = moved.length == 0 ? start : projection.sourceOffset(forVisibleOffset: NSMaxRange(moved), affinity: .upstream)
            refreshing = true
            editor.setSelectedRange(NSRange(location: start, length: max(0, end - start)), affinity: navigator.selectionAffinity, stillSelecting: false)
            refreshing = false
            normalizeEmphasisSelection()
            emphasisTypingState.adopt()
            endTypingRun()
            updateEmphasisTypingAttributes()
            return true
        }
        let backward: Bool
        let deleting: Bool
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): (backward, deleting) = (true, false)
        case #selector(NSResponder.moveRight(_:)): (backward, deleting) = (false, false)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)): (backward, deleting) = (true, false)
        case #selector(NSResponder.moveRightAndModifySelection(_:)): (backward, deleting) = (false, false)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteWordBackward(_:)): (backward, deleting) = (true, true)
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:)): (backward, deleting) = (false, true)
        default: return false
        }
        if deleting {
            var range = selection
            if range.length == 0 {
                let next: Int
                if command.contains("Word") {
                    cellWordNavigator.string = projection.visibleText
                    cellWordNavigator.baseWritingDirection = editor.baseWritingDirection
                    cellWordNavigator.setSelectedRange(range)
                    cellWordNavigator.doCommand(by: NSSelectorFromString(backward ? "moveWordBackward:" : "moveWordForward:"))
                    next = cellWordNavigator.selectedRange().location
                } else {
                    next = projection.nextVisibleOffset(from: range.location, direction: backward ? -1 : 1)
                }
                range = NSRange(location: min(range.location, next), length: abs(range.location - next))
            }
            guard range.length > 0 else { return true }
            guard let plan = MarkdownEmphasisEditPlanner.deletion(visibleRange: range, projection: projection) else { return false }
            pendingEditRange = editor.selectedRange()
            refreshing = true
            editor.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
            editor.setSelectedRange(plan.selectionAfter)
            refreshing = false
            _ = commitInput()
            return true
        }
        if selector == #selector(NSResponder.moveRight(_:)), selection == NSRange(location: 0, length: length), length > 0 { return false }
        let edge = backward ? selection.location : NSMaxRange(selection)
        if selection.length == 0, (backward ? edge == 0 : edge == length) { return false }
        // Keep AppKit's visual bidi order and selection anchor. Re-dispatch only
        // while movement consumed source delimiters without moving visibly.
        refreshing = true
        navigatingCellEmphasis = true
        let limit = projection.hiddenDelimiterRanges.reduce(1) { $0 + $1.length }
        for _ in 0..<limit {
            let before = editor.selectedRange()
            editor.doCommand(by: selector)
            if emphasisVisibleSelection != selection || editor.selectedRange() == before { break }
        }
        navigatingCellEmphasis = false
        refreshing = false
        normalizeEmphasisSelection()
        emphasisTypingState.adopt()
        updateEmphasisTypingAttributes()
        return true
    }

    func copyCellEmphasis(cut: Bool, to board: NSPasteboard) -> Bool {
        guard !isRangeMode, !isComposing, editor.selectedRange().length > 0 else { return false }
        let projection = emphasisProjection
        let visible = emphasisVisibleSelection
        let markdown = projection.balancedMarkdown(forVisibleRange: visible)
        board.clearContents()
        board.setString(markdown, forType: .string)
        if cut {
            endTypingRun()
            guard let plan = MarkdownEmphasisEditPlanner.deletion(visibleRange: visible, projection: projection) else { return true }
            refreshing = true
            editor.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
            editor.setSelectedRange(plan.selectionAfter)
            refreshing = false
            _ = commitInput(actionName: "Cut", coalescing: false)
        }
        return true
    }
    func beginCellEmphasisComposition(replacing range: NSRange) {
        guard emphasisComposition == nil, !isComposing else { return }
        let projection = emphasisProjection
        let visible = projection.visibleOffset(forSourceOffset: range.location)
        let inherited = range.length == 0 ? inheritedCellEmphasisTraits
            : projection.traits(atVisibleOffset: visible, affinity: .downstream)
        emphasisComposition = (editor.string, range, emphasisTypingState.effectiveTraits(inheriting: inherited))
    }

    /// Marked text remains wholly native. Only the final committed buffer receives wrappers.
    func finishCellEmphasisComposition() {
        guard let original = emphasisComposition else { return }
        emphasisComposition = nil
        let oldText = original.source as NSString
        let newText = editor.string as NSString
        // The input method's committed span belongs to its original replacement
        // selection. A text diff can mistake shared characters for unchanged text
        // and lose the closing markers that the native selection replaced.
        guard !oldText.isEqual(to: editor.string) else { return }
        let start = original.selection.location
        let end = editor.selectedRange().location
        guard start >= 0, end >= start, end <= newText.length,
              NSMaxRange(original.selection) <= oldText.length else { return }
        let text = newText.substring(with: NSRange(location: start, length: end - start))
        let expected = oldText.replacingCharacters(in: original.selection, with: text)
        guard (expected as NSString).isEqual(to: editor.string) else { return }
        let projection = MarkdownEmphasisProjection(source: original.source, scope: .inline)
        guard !cellEmphasisIsLiteral(at: start, projection: projection),
              let result = emphasisReplacement(text, range: original.selection,
                projection: projection, traits: original.traits) else { return }
        pendingEditRange = original.selection
        refreshing = true
        editor.string = result.text
        editor.setSelectedRange(result.selection)
        refreshing = false
        pendingEmphasisTypingBefore = emphasisTypingState
        emphasisTypingState.retainTypingTraits(original.traits)
    }

}
