import AppKit

/// Edits one rendered table cell in place. There is one native input view per
/// document editor; grids are disposable presentations. Every committed
/// keystroke is a source transaction in the main editor, so save, search and
/// Undo only ever see Markdown source, never a separate table model.
///
/// The session never blocks its callers: a cell whose source changed underneath
/// it is retired, which at worst ends cell editing, never the editor.
final class MarkdownTableEditingSession: NSObject, NSTextViewDelegate {
    weak var coordinator: NativeTextViewCoordinator?
    let editor = MarkdownTableCellTextView(frame: .zero)
    private let editorScroll = NSScrollView(frame: .zero)
    weak var grid: MarkdownTableGridView?
    private var presentationOrigin = NSPoint.zero
    private var refocusOnMount = false

    private(set) var table: MarkdownTableSource?
    private(set) var row = 0
    private(set) var column = 0
    /// The table's source as last committed or observed; any other change to it is foreign.
    private var tableText = ""
    private var span = CellSpan(range: NSRange(location: 0, length: 0))
    private var documentGeneration = 0
    var refreshing = false
    var applyingSource = false
    /// Re-renders the table's image after a typing pause; the grid shows edits until then.
    private var renderTimer: Timer?
    /// The source range whose image the pending render refreshes.
    private var renderRange: NSRange?
    /// Distinguishes sessions, so deferred work for one cannot end the next.
    private var epoch = 0
    private let cellCache = MarkdownTableLayout.CellCache()
    /// Consecutive keystrokes in one cell, undone as one step.
    private var typingRun: TypingRun?
    /// The cell editor's range the pending keystroke replaces, from `shouldChangeTextIn`.
    private var pendingEditRange: NSRange?
    /// The one table showing its Markdown source because the user chose Edit
    /// Table Source. Every other table stays rendered wherever the caret is.
    private(set) var revealedSourceTableLocation: Int?
    /// A rectangular range of cells (doc 24 §7.5); nil in caret or text mode.
    var cellSelection: TableCellSelection?
    /// The selected cells' source when the range was made: a file change under
    /// them refuses destructive range edits until the user reselects.
    var rangeSnapshot: [CellCoord: String] = [:]
    /// The key this table's view-only column widths are kept under, once known.
    var widthKey: String?
    /// The table menu open now (Cell actions, Move), if any.
    weak var openMenu: TableMenuView?
    /// The range an Undo in progress puts back once its source edit lands.
    var pendingRangeRestore: (selection: TableCellSelection, location: Int)?

    /// Where the focused cell's text lives. A missing trailing cell is an insertion
    /// point plus the separators its first committed text needs.
    private struct CellSpan {
        var range: NSRange
        var prefix = ""
        var suffix = ""
    }

    /// Where the cell editor's selection lands when a cell is focused without a click.
    enum Entry: Equatable {
        case start, end, all
        /// A range of the cell's source text, relative to the cell's start.
        case range(NSRange)
    }

    /// Keystrokes in one cell, undone as one step. A run ends after 500 ms
    /// without typing, on a non-adjacent edit, and on any edit it did not make,
    /// so the source region it restores never needs mapping.
    private final class TypingRun {
        /// The source region the run's keystrokes rewrite.
        let location: Int
        var length: Int
        /// The region's source before the run.
        let original: String
        /// The cell editor's caret after the run's last keystroke.
        var caret: Int
        var idleTimer: Timer?

        init(location: Int, length: Int, original: String, caret: Int) {
            self.location = location
            self.length = length
            self.original = original
            self.caret = caret
        }
    }

    var isActive: Bool { table != nil }
    var isComposing: Bool { isActive && editor.hasProtectedInput }
    var preferredResponder: NSTextView? { isActive && editor.window != nil ? editor : nil }

    init(coordinator: NativeTextViewCoordinator) {
        self.coordinator = coordinator
        super.init()
        editor.session = self
        editor.delegate = self
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false
        // The cell's text wraps inside the cell as the raster wraps it; line
        // breaks are `<br>` in source (the reference editor: Return adds a line in the cell).
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.maximumNumberOfLines = 0
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
        editorScroll.drawsBackground = false
        editorScroll.borderType = .noBorder
        editorScroll.hasHorizontalScroller = false
        editorScroll.hasVerticalScroller = false
        editorScroll.documentView = editor
    }

    func owns(_ range: NSRange) -> Bool { table?.range.location == range.location }

    /// A draw-time remount request is unnecessary while the retained input
    /// already belongs to this canvas; avoid an idle draw/reconcile loop.
    func isMounted(in canvas: NSView) -> Bool {
        guard let grid else { return false }
        return grid.superview === canvas && editorScroll.superview === grid
    }

    func isSourceRevealed(_ range: NSRange) -> Bool { revealedSourceTableLocation == range.location }

    /// Show the table's Markdown source until the caret leaves it (Edit Table Source).
    func revealSource(of range: NSRange) { revealedSourceTableLocation = range.location }

    /// The caret left the revealed table: it renders again.
    func concealSource() { revealedSourceTableLocation = nil }

    // MARK: - Lifetime

    /// Focus the cell under `point` (in table coordinates) of the table at `range`.
    func begin(range: NSRange, point: NSPoint, in canvas: NSView, origin: NSPoint = .zero) -> Bool {
        finishInput()
        renderTableNow()
        guard let (source, geometry) = editableTable(at: range), let address = geometry.cell(at: point),
              let span = Self.cellSpan(in: source, row: address.row, column: address.column),
              let main = coordinator?.textView else { return false }
        start(source, row: address.row, column: address.column, span: span, origin: origin)
        mount(in: canvas, geometry: geometry)
        main.breakUndoCoalescing()
        focusEditor()
        showTableHintIfNeeded()
        return editor.window?.firstResponder === editor
    }

    /// Focus (row, column) of the table at `range` without a pointer: from the
    /// keyboard, Find, Undo or a caret placed in the table's source. A table
    /// that is not laid out yet takes the keyboard when it mounts.
    @discardableResult
    func begin(range: NSRange, row: Int, column: Int, selecting entry: Entry, validatedSource: MarkdownTableSource? = nil) -> Bool {
        finishInput()
        renderTableNow()
        var table: (MarkdownTableSource, MarkdownTableLayout)?
        PerfTrace.time("tableEntry.table") {
            if let validatedSource, validatedSource.range == range, let geometry = geometry(for: validatedSource) {
                table = (validatedSource, geometry)
            } else { table = editableTable(at: range) }
        }
        guard let (source, geometry) = table,
              let span = Self.cellSpan(in: source, row: row, column: column),
              let main = coordinator?.textView as? NativeTextView else { return false }
        // Find and other controls keep the keyboard; the cell takes it only from the document.
        let responder = main.window?.firstResponder
        let takesKeyboard = responder == nil || responder === main.window || responder === main || responder === editor
        let canvas = main.tableCanvas(forTableAt: source.range)
        PerfTrace.time("tableEntry.start") {
            start(source, row: row, column: column, span: span, origin: canvas?.origin ?? .zero)
        }
        place(entry)
        main.breakUndoCoalescing()
        guard let canvas else {
            refocusOnMount = takesKeyboard
            main.updateWideTableOverlays()
            return true
        }
        PerfTrace.time("tableEntry.mount") { mount(in: canvas.view, geometry: geometry) }
        if takesKeyboard {
            PerfTrace.time("tableEntry.focus") {
                focusEditor()
                revealFocusedCell()
            }
            showTableHintIfNeeded()
        }
        return true
    }

    /// The table at `range` as the document parses now, if the document admits cell editing.
    private func editableTable(at range: NSRange) -> (MarkdownTableSource, MarkdownTableLayout)? {
        guard let coordinator, let main = coordinator.textView, main.isEditable, main.window != nil,
              !coordinator.isWritingToolsActive, !coordinator.isComposing(in: main),
              let token = coordinator.parsedDocument(for: main.string).tokens.first(where: {
                  $0.kind == .table && $0.range.location == range.location
              }),
              let source = MarkdownTableSource(source: main.string, range: token.range),
              let geometry = geometry(for: source) else { return nil }
        if #available(macOS 15.0, *), main.isWritingToolsActive { return nil }
        return (source, geometry)
    }

    /// Make (row, column) the focused cell and move the document's caret into it.
    private func start(_ source: MarkdownTableSource, row: Int, column: Int, span: CellSpan, origin: NSPoint) {
        defer { coordinator?.tableActions?.caretMoved() }
        if table?.range.location != source.range.location { widthKey = nil }
        guard let coordinator, let main = coordinator.textView else { return }
        endTypingRun()
        adopt(source)
        // A note with widths set: know this table's key before any edit changes its header.
        if widthKey == nil, coordinator.editorController?.tableWidthsStore.widths.isEmpty == false {
            widthKey = coordinator.tableKey(forTableAt: source.range)
        }
        epoch &+= 1
        documentGeneration = coordinator.documentGeneration
        self.row = row
        self.column = column
        self.span = span
        presentationOrigin = origin
        revealedSourceTableLocation = nil
        adoptInputPolicy(of: main)
        // The document's caret moves into this table, so whatever was active before
        // (a revealed heading, say) settles now against a current parse.
        main.setSelectedRange(NSRange(location: span.range.location, length: 0))
        showCommittedCell()
    }

    func place(_ entry: Entry) {
        let length = (editor.string as NSString).length
        switch entry {
        case .start: editor.setSelectedRange(NSRange(location: 0, length: 0))
        case .end: editor.setSelectedRange(NSRange(location: length, length: 0))
        case .all: editor.setSelectedRange(NSRange(location: 0, length: length))
        case .range(let range):
            // `range` counts the cell's source; the editor shows `<br>` as a line break.
            let source = table.map { ($0.source as NSString).substring(with: span.range) } ?? editor.string
            let shown = Self.decodedCell(source, selection: range).selection
            let start = min(max(0, shown.location), length)
            editor.setSelectedRange(NSRange(location: start, length: min(max(0, shown.length), length - start)))
        }
    }

    private func adoptInputPolicy(of main: NSTextView) {
        editor.isAutomaticQuoteSubstitutionEnabled = main.isAutomaticQuoteSubstitutionEnabled
        editor.isAutomaticDashSubstitutionEnabled = main.isAutomaticDashSubstitutionEnabled
        editor.isAutomaticTextReplacementEnabled = main.isAutomaticTextReplacementEnabled
        editor.isAutomaticSpellingCorrectionEnabled = main.isAutomaticSpellingCorrectionEnabled
        editor.isAutomaticDataDetectionEnabled = main.isAutomaticDataDetectionEnabled
        editor.isAutomaticLinkDetectionEnabled = main.isAutomaticLinkDetectionEnabled
        editor.isContinuousSpellCheckingEnabled = main.isContinuousSpellCheckingEnabled
    }

    func select(row: Int, column: Int) {
        if cellSelection != nil { setCellSelection(nil) }
        defer { coordinator?.tableActions?.caretMoved() }
        finishInput()
        endTypingRun()
        guard let table, let span = Self.cellSpan(in: table, row: row, column: column) else { return }
        self.row = row
        self.column = column
        self.span = span
        showCommittedCell()
        placeEditor()
        grid?.needsDisplay = true
        revealFocusedCell()
        focusEditor()
    }

    /// Bring the focused cell into view in its table's horizontal scroller and in the document.
    func revealFocusedCell() {
        guard let grid, grid.geometry.cellRects.indices.contains(row),
              grid.geometry.cellRects[row].indices.contains(column),
              let main = coordinator?.textView else { return }
        let cell = grid.geometry.cellRects[row][column]
        grid.scrollToVisible(cell)
        main.scrollToVisible(grid.convert(cell, to: main))
    }

    /// Finish cell input and hand the keyboard back to the document with a caret at `location`.
    func end(selecting location: Int) {
        guard let main = coordinator?.textView else { retire(); return }
        finishInput()
        retire(movingCaret: false)
        let length = (main.string as NSString).length
        main.setSelectedRange(NSRange(location: min(max(0, location), length), length: 0))
        main.window?.makeFirstResponder(main)
        main.scrollRangeToVisible(main.selectedRange())
    }

    /// The document moved its selection out of this table (Go to Line, Find,
    /// a host command): end cell editing and leave that selection where it is.
    func yieldToDocumentSelection() {
        guard isActive, let main = coordinator?.textView else { return }
        let selection = main.selectedRange()
        let hadKeyboard = editor.window?.firstResponder === editor
        finishInput()
        retire(movingCaret: false)
        if hadKeyboard { main.window?.makeFirstResponder(main) }
        if main.selectedRange() != selection { main.setSelectedRange(selection) }
    }

    /// End cell editing without writing. Committed text is already in source; only
    /// provisional marked text is discarded.
    func retire() { retire(movingCaret: true) }

    private func retire(movingCaret: Bool) {
        guard !applyingSource, let current = table else { return }
        if cellSelection != nil { setCellSelection(nil) }
        endTypingRun()
        let window = editor.window
        let hadKeyboard = window?.firstResponder === editor
        if editor.hasMarkedText() {
            refreshing = true
            editor.discardMarkedText()
            refreshing = false
        }
        renderTableNow()
        // Ended before the caret moves, so the document's selection handler
        // sees prose, not a cell to follow.
        table = nil
        cellCache.removeAll()
        refocusOnMount = false
        defer { coordinator?.tableActions?.update() }
        if movingCaret, hadKeyboard, let main = coordinator?.textView {
            main.setSelectedRange(NSRange(location: min(Self.location(after: current), (main.string as NSString).length), length: 0))
            window?.makeFirstResponder(main)
        }
        detachPresentation()
    }

    // MARK: - Presentation

    func mount(in canvas: NSView, range: NSRange, origin: NSPoint = .zero) {
        guard owns(range), let table, let geometry = geometry(for: table) else { return }
        presentationOrigin = origin
        mount(in: canvas, geometry: geometry)
        if refocusOnMount {
            // The document editor holds the keyboard while a cell entered from
            // the keyboard waits for its table to be laid out.
            let responder = editor.window?.firstResponder
            if responder == nil || responder === editor.window || responder === coordinator?.textView {
                focusEditor()
                revealFocusedCell()
            } else {
                refocusOnMount = false
            }
        }
    }

    private func mount(in canvas: NSView, geometry: MarkdownTableLayout) {
        let view = grid ?? MarkdownTableGridView(geometry: geometry, session: self)
        view.geometry = geometry
        view.frame = NSRect(origin: presentationOrigin, size: geometry.size)
        if view.superview !== canvas { canvas.addSubview(view) }
        // A wide table's scroll canvas is its last rendered image; a cell edit can
        // outgrow it until the table re-renders.
        if canvas is WideTableImageView, !NSContainsRect(canvas.bounds, view.frame) {
            canvas.setFrameSize(NSSize(width: max(canvas.frame.width, view.frame.maxX),
                                       height: max(canvas.frame.height, view.frame.maxY)))
        }
        grid = view
        placeEditor()
        view.needsDisplay = true
    }

    /// The grid may leave the viewport; the session and its input survive and
    /// take the keyboard back when the table is mounted again.
    func detachPresentation() {
        if isActive, editor.window?.firstResponder === editor { refocusOnMount = true }
        editorScroll.removeFromSuperview()
        grid?.removeFromSuperview()
        grid = nil
    }

    func focusEditor() {
        guard let window = editor.window else { return }
        refocusOnMount = false
        if window.firstResponder !== editor { window.makeFirstResponder(editor) }
    }

    private func placeEditor() {
        guard let grid, grid.geometry.cellRects.indices.contains(row),
              grid.geometry.cellRects[row].indices.contains(column) else { return }
        let cell = grid.geometry.cellRects[row][column]
        // The editor covers the cell's content box, where the raster draws its text.
        let rect = cell.insetBy(dx: MarkdownTableLayout.horizontalPadding, dy: MarkdownTableLayout.verticalPadding)
        editorScroll.frame = rect
        editor.minSize = NSSize(width: rect.width, height: rect.height)
        editor.setFrameSize(NSSize(width: rect.width, height: max(rect.height, editor.frame.height)))
        editor.sizeToFit()
        if editorScroll.superview !== grid { grid.addSubview(editorScroll) }
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    func geometry(for table: MarkdownTableSource) -> MarkdownTableLayout? {
        guard let coordinator,
              let model = MarkdownTableModel.parse((table.source as NSString).substring(with: table.range)) else { return nil }
        let configuration = coordinator.configuration
        return MarkdownTableLayout(
            table: MarkdownStyler.parsedTable(from: model), font: coordinator.baseFontAndStyle().0,
            theme: configuration.theme, codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            latex: configuration.services.latex,
            appearance: coordinator.textView?.effectiveAppearance ?? NSAppearance.currentDrawing(),
            cache: cellCache, columnWidths: coordinator.columnWidths(forTableAt: table.range)
        )
    }

    /// The document range of `editorRange` in the focused cell, when the cell
    /// has source text (a missing trailing cell has none yet).
    func sourceRange(ofEditorRange editorRange: NSRange) -> NSRange? {
        guard isActive, span.prefix.isEmpty, span.suffix.isEmpty, NSMaxRange(editorRange) <= span.range.length else { return nil }
        return NSRange(location: span.range.location + editorRange.location, length: editorRange.length)
    }

    /// The layout of the rendered table at `range`: the mounted grid's when it is this session's.
    func geometry(forTableAt range: NSRange) -> MarkdownTableLayout? {
        if owns(range), let grid { return grid.geometry }
        guard let main = coordinator?.textView, NSMaxRange(range) <= (main.string as NSString).length,
              let source = MarkdownTableSource(source: main.string, range: range) else { return nil }
        return geometry(for: source)
    }

    func remount() {
        guard let canvas = grid?.superview, let table, let geometry = geometry(for: table) else { return }
        mount(in: canvas, geometry: geometry)
    }

    // MARK: - Source transactions

    /// The main source, if this cell may write to it now.
    func admittedSource() -> NSString? {
        guard let table, let coordinator, let main = coordinator.textView, main.isEditable,
              !coordinator.isWritingToolsActive, !main.hasMarkedText(),
              documentGeneration == coordinator.documentGeneration,
              let source = main.textStorage?.mutableString else { return nil }
        if let native = main as? NativeTextView, native.isSettingMarkedText || native.isCommittingMarkedText { return nil }
        if #available(macOS 15.0, *), main.isWritingToolsActive { return nil }
        if NSMaxRange(table.range) <= source.length, source.substring(with: table.range) == tableText { return source }
        return relocate(in: source) ? source : nil
    }

    /// An edit the session did not see (such as native Undo of typing elsewhere)
    /// moved or changed the table. Follow the nearest unchanged copy, else fail.
    private func relocate(in source: NSString) -> Bool {
        guard let table, let coordinator, let main = coordinator.textView else { return false }
        let copies = coordinator.parsedDocument(for: main.string).tokens.filter {
            $0.kind == .table && $0.range.length == table.range.length && source.substring(with: $0.range) == tableText
        }
        guard let nearest = copies.min(by: {
                  abs($0.range.location - table.range.location) < abs($1.range.location - table.range.location)
              }),
              let moved = MarkdownTableSource(source: main.string, range: nearest.range) else { return false }
        span.range.location += nearest.range.location - table.range.location
        adopt(moved)
        return true
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if refreshing { return true }
        if admittedSource() != nil {
            pendingEditRange = range
            return true
        }
        // The table changed underneath this cell. Ending the session is the safe outcome.
        let refused = epoch
        DispatchQueue.main.async { [weak self] in
            if let self, self.epoch == refused { self.retire() }
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard !refreshing, !isComposing else { return }
        commitInput()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        coordinator?.selectionBar?.setNeedsUpdate()
    }

    /// Write the cell buffer to source. Marked text stays provisional until it is
    /// committed. Typing joins the cell's typing run, one Undo step; a command
    /// (`coalescing: false`) is its own named step.
    @discardableResult
    func commitInput(actionName: String = "Edit Table Cell", coalescing: Bool = true) -> Bool {
        guard isActive, !refreshing, !isComposing else { return !isComposing }
        let encoded = Self.encodedCell(editor.string, selection: editor.selectedRange(), lineBreak: lineBreakSpelling())
        let committed = admittedSource()?.substring(with: span.range)
        if committed == encoded.text {
            pendingEditRange = nil
            return true
        }
        guard committed != nil, let table, let coordinator, let main = coordinator.textView else {
            retire()
            return false
        }
        // A missing cell is materialized by its first text; clearing it again is a no-op.
        var replacement = span.prefix.isEmpty || encoded.text.isEmpty
            ? encoded.text : span.prefix + encoded.text + span.suffix
        // A trailing backslash must not escape the cell's closing pipe: pad it.
        if let source = admittedSource(), NSMaxRange(span.range) < source.length,
           source.character(at: NSMaxRange(span.range)) == 0x7C,
           replacement.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
            replacement += " "
        }
        let run = coalescing ? typingRun(for: span.range, actionName: actionName) : nil
        if !coalescing { endTypingRun() }
        applyingSource = true
        let deferred = coordinator.replaceHiddenTableSource(
            span.range, with: replacement, actionName: actionName, registersUndo: run == nil
        )
        // The encoded cell never contains a line break, so the paragraph chain is unchanged.
        let accepted = deferred ?? coordinator.replaceSourceRanges(
            [span.range], with: replacement, expectedSource: main.string, actionName: actionName,
            reflowsParagraphChain: false, registersUndo: run == nil
        )
        applyingSource = false
        guard accepted else { retire(); return false }
        let delta = (replacement as NSString).length - span.range.length
        let shown = Self.decodedCell(encoded.text, selection: encoded.selection)
        run?.length += delta
        run?.caret = shown.selection.location
        let sizeBefore = grid?.geometry.size
        span = CellSpan(range: NSRange(location: span.range.location + (span.prefix.isEmpty ? 0 : (span.prefix as NSString).length),
                                       length: (encoded.text as NSString).length))
        guard let refreshed = MarkdownTableSource(
            source: main.string, range: NSRange(location: table.range.location, length: table.range.length + delta)
        ) else { retire(); return false }
        adopt(refreshed)
        if row == 0, widthKey != nil { followWidths() }
        if deferred != nil { scheduleTableRender() }
        refreshing = true
        if editor.string != shown.text {
            editor.string = shown.text
            applyCellStyle(coordinator: coordinator, table: refreshed)
        }
        editor.setSelectedRange(shown.selection)
        refreshing = false
        remount()
        // A shorter/narrower grid exposes stale raster borders; a taller row
        // overlaps the text below. Width growth remains deferred: the live
        // grid already covers the old raster, so ordinary typing stays cheap.
        if deferred != nil, let sizeBefore, let sizeAfter = grid?.geometry.size,
           sizeAfter.height != sizeBefore.height || sizeAfter.width < sizeBefore.width {
            renderTimer?.invalidate()
            renderTimer = nil
            renderRange = nil
            coordinator.restyleTableNow(refreshed.range)
        }
        return true
    }

    /// How this table writes a line break: its first existing tag, else `<br>`.
    func lineBreakSpelling() -> String {
        guard let table else { return "<br>" }
        let text = (table.source as NSString).substring(with: table.range)
        guard let match = MarkdownStyler.lineBreakTag.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return "<br>"
        }
        return (text as NSString).substring(with: match.range)
    }

    // MARK: - Typing runs

    /// The run this keystroke joins. A new run registers its one Undo step before
    /// its first keystroke; the keystrokes themselves register none.
    private func typingRun(for range: NSRange, actionName: String) -> TypingRun? {
        let edit = pendingEditRange
        pendingEditRange = nil
        if let run = typingRun {
            let adjacent = edit.map { $0.location <= run.caret && run.caret <= NSMaxRange($0) } ?? false
            let inside = range.location >= run.location && NSMaxRange(range) <= run.location + run.length
            if adjacent && inside {
                restartIdleTimer(of: run)
                return run
            }
            endTypingRun()
        }
        guard let coordinator, let undo = coordinator.textView?.undoManager,
              let source = admittedSource() else { return nil }
        let run = TypingRun(location: range.location, length: range.length,
                            original: source.substring(with: range), caret: 0)
        let ownsGroup = undo.groupingLevel == 0
        if ownsGroup { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: coordinator) { [weak self] coordinator in
            Self.undo(run, actionName: actionName, coordinator: coordinator)
            self?.endTypingRun()
        }
        undo.setActionName(actionName)
        if ownsGroup { undo.endUndoGrouping() }
        typingRun = run
        restartIdleTimer(of: run)
        return run
    }

    /// Restore the run's region in one span edit, which registers the Redo of the whole run.
    private static func undo(_ run: TypingRun, actionName: String, coordinator: NativeTextViewCoordinator) {
        guard let main = coordinator.textView else { return }
        let source = main.string
        let range = NSRange(location: run.location, length: run.length)
        guard NSMaxRange(range) <= (source as NSString).length else { return }
        _ = coordinator.replaceSourceRanges([range], with: run.original, expectedSource: source,
                                            actionName: actionName, reflowsParagraphChain: false)
    }

    private func restartIdleTimer(of run: TypingRun) {
        run.idleTimer?.invalidate()
        // the reference editor closes a typing group after 500 ms without input.
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self, weak run] _ in
            MainActor.assumeIsolated {
                guard let self, let run, self.typingRun === run else { return }
                self.endTypingRun()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        run.idleTimer = timer
    }

    /// The next keystroke starts a new Undo step.
    func endTypingRun() {
        typingRun?.idleTimer?.invalidate()
        typingRun = nil
    }

    /// Commit any provisional or pending cell input. Never blocks the caller.
    /// A save, hide or document switch also seals the typing run.
    func finishInput() {
        guard isActive else { return }
        defer { endTypingRun() }
        if editor.hasMarkedText() { editor.unmarkText() }
        commitInput()
        editor.breakUndoCoalescing()
    }

    func finishDeferredInputWork() {
        guard !isComposing, let coordinator, let main = coordinator.textView as? NativeTextView else { return }
        coordinator.finishComposition(in: main)
    }

    /// After a source change the session neither made nor followed: keep editing
    /// while the table is intact (possibly moved), otherwise end.
    func sourceMayHaveChanged() {
        guard isActive, !applyingSource, !isComposing, admittedSource() == nil else { return }
        retire()
    }

    /// Follow a source edit made outside the session (Undo, Redo, Replace All).
    func sourceDidChange(map: (Int) -> Int) {
        guard !applyingSource else { return }
        endTypingRun()
        guard let old = table, let coordinator, let main = coordinator.textView else { return }
        let start = map(old.range.location)
        guard let token = coordinator.parsedDocument(for: main.string).tokens.first(where: {
                  $0.kind == .table && $0.range.location == start
              }),
              let refreshed = MarkdownTableSource(source: main.string, range: token.range) else { retire(); return }
        adopt(refreshed)
        // Undo can remove cells still covered by a range. Keep its snapshot so
        // changed content still refuses destructive commands until reselection.
        cellSelection = cellSelection?.clamped(to: refreshed)
        row = min(row, refreshed.rowCount - 1)
        column = min(column, refreshed.columnCount - 1)
        guard let span = Self.cellSpan(in: refreshed, row: row, column: column) else { retire(); return }
        self.span = span
        showCommittedCell()
        followWidths()
        remount()
    }

    private func scheduleTableRender() {
        renderTimer?.invalidate()
        renderRange = table?.range
        // A run-loop timer, like the coordinator's deferred restyle: tests pump the run loop.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderTableNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    /// Queue the table's restyle now if a deferred cell edit left its image stale.
    private func renderTableNow() {
        guard let timer = renderTimer else { return }
        timer.invalidate()
        renderTimer = nil
        if let range = renderRange { coordinator?.enqueueDeferredRestyle([range]) }
        renderRange = nil
    }

    /// After a whole-table rewrite: the focused cell's span and editor text
    /// from the new source, so no later commit writes stale text back.
    func resyncFocusedCell() {
        guard let table else { return }
        row = min(row, table.rowCount - 1)
        column = min(column, table.columnCount - 1)
        guard let span = Self.cellSpan(in: table, row: row, column: column) else { return }
        self.span = span
        showCommittedCell()
    }

    /// The transparent editor supplies the focused cell's text; the grid
    /// retains its existing fill. A cell range hides it (it keeps the
    /// keyboard) so the range's tint shows over the anchor cell too.
    func setEditorShown(_ shown: Bool) {
        editorScroll.alphaValue = shown ? 1 : 0
    }

    /// Where a whole-table rewrite leaves the document's selection: a caret
    /// at the table's start. Selecting the rewritten table (the default) made
    /// TextKit grey that selection around the table while the cell editor has
    /// the keyboard; the document's own selection stays a caret in the table,
    /// as on entry.
    static func documentCaret(in table: MarkdownTableSource) -> NSRange {
        NSRange(location: table.range.location, length: 0)
    }

    func adopt(_ source: MarkdownTableSource) {
        table = source
        tableText = (source.source as NSString).substring(with: source.range)
    }

    func showCommittedCell() {
        guard let coordinator, let table else { return }
        refreshing = true
        editor.string = Self.decodedCell((table.source as NSString).substring(with: span.range)).text
        applyCellStyle(coordinator: coordinator, table: table)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setAccessibilityLabel(row == 0 ? "Table header, column \(column + 1)" : "Table row \(row), column \(column + 1)")
        refreshing = false
    }

    /// The raster's look for the cell's text: cell font, header or body color,
    /// column alignment and the 1.45 line, so the editor wraps where the raster does.
    private func applyCellStyle(coordinator: NativeTextViewCoordinator, table: MarkdownTableSource) {
        let font = MarkdownTableLayout.cellFont(for: coordinator.baseFontAndStyle().0)
        let lineHeight = font.pointSize * MarkdownTableLayout.lineHeightMultiple
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        if let alignments = MarkdownTableScanner.alignments(in: (table.source as NSString).substring(with: table.rows[1].contentRange)),
           alignments.indices.contains(column) {
            switch alignments[column] {
            case .left: paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .right: paragraph.alignment = .right
            }
        }
        let theme = coordinator.configuration.theme
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: row == 0 ? theme.tableHeaderText : theme.bodyText,
            .paragraphStyle: paragraph,
            .baselineOffset: MarkdownTableLayout.baselineOffset(for: font, lineHeight: lineHeight),
        ]
        editor.font = font
        editor.textColor = attributes[.foregroundColor] as? NSColor
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = attributes
        if let storage = editor.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    // MARK: - Commands

    /// Toggle inline formatting on the cell's selection, or the word at its caret.
    @discardableResult
    func format(_ style: MarkdownInlineStyle) -> Bool {
        if isRangeMode {
            formatRange(style)
            return true
        }
        guard isActive, !isComposing, admittedSource() != nil, let coordinator else { return false }
        let text = editor.string as NSString
        let target = coordinator.inlineFormattingTargetRange(in: editor, text: text)
        let tokens = MarkdownInlineFormattingRuns.inlineTokens(in: text, range: NSRange(location: 0, length: text.length))
        guard let plan = MarkdownInlineFormatter.plan(text: text, targetRange: target, style: style, tokens: tokens) else { return false }
        refreshing = true
        editor.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
        editor.setSelectedRange(plan.selectionAfter)
        refreshing = false
        return commitInput(actionName: plan.actionName, coalescing: false)
    }

    /// Apply a row, column or alignment change as one source transaction.
    @discardableResult
    func perform(_ edit: MarkdownTableEdit) -> Bool {
        finishInput()
        endTypingRun()
        guard let table, admittedSource() != nil, let coordinator, let main = coordinator.textView,
              let plan = MarkdownTableEditPlan(edit, table: table, row: row, column: column) else { return false }
        let editedColumn = column
        applyingSource = true
        let accepted = coordinator.replaceSourceRanges(
            [table.range], with: plan.replacement, expectedSource: main.string, actionName: edit.actionName,
            selectionAfter: Self.documentCaret(in: table)
        )
        applyingSource = false
        guard accepted, let refreshed = MarkdownTableSource(
            source: main.string, range: NSRange(location: table.range.location, length: (plan.replacement as NSString).length)
        ) else { retire(); return false }
        adopt(refreshed)
        resyncFocusedCell()
        followWidths { widths in
            switch edit {
            case .insertColumn(let right):
                let index = editedColumn + (right ? 1 : 0)
                if index <= widths.count { widths.insert(nil, at: index) }
            case .deleteColumn:
                if editedColumn < widths.count { widths.remove(at: editedColumn) }
            default:
                break
            }
        }
        select(row: plan.row, column: plan.column)
        remount()
        return true
    }

    /// Show this table's Markdown source until the caret leaves it.
    @objc func editTableSource(_ sender: Any?) {
        guard let table, let coordinator else { return }
        revealSource(of: table.range)
        end(selecting: span.range.location)
        // The caret was already in the table, so no selection change restyles it.
        coordinator.enqueueDeferredRestyle([table.range])
    }

    /// Remove the table and its blank separator line as one Undo step. The caret
    /// goes to the start of the following paragraph, else the end of the preceding one.
    @discardableResult
    func deleteTable() -> Bool {
        finishInput()
        endTypingRun()
        guard let table, admittedSource() != nil, let coordinator, let main = coordinator.textView else { return false }
        let text = table.source as NSString
        var range = NSRange(location: table.range.location,
                            length: Self.location(after: table) - table.range.location)
        func isBlankLine(at location: Int) -> Bool {
            var end = 0
            text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: location, length: 0))
            return text.substring(with: NSRange(location: location, length: end - location))
                .allSatisfy { $0 == " " || $0 == "\t" }
        }
        if NSMaxRange(range) < text.length, isBlankLine(at: NSMaxRange(range)) {
            range.length = NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))) - range.location
        } else if NSMaxRange(range) >= text.length, range.location > 0 {
            // Nothing follows: take the line break that ends the preceding text.
            let before = Self.location(before: table)
            range = NSRange(location: before, length: text.length - before)
        }
        applyingSource = true
        let accepted = coordinator.replaceSourceRanges([range], with: "", expectedSource: main.string,
                                                       actionName: "Delete Table")
        applyingSource = false
        guard accepted else { return false }
        let remaining = main.string as NSString
        var caret = min(range.location, remaining.length)
        if caret >= remaining.length || (caret > 0 && remaining.character(at: caret) == 0x0A
                                         && remaining.character(at: caret - 1) == 0x0A) {
            var end = 0
            remaining.getLineStart(nil, end: nil, contentsEnd: &end,
                                   for: NSRange(location: max(0, min(caret, remaining.length) - 1), length: 0))
            caret = caret >= remaining.length && remaining.length > 0 ? end : caret
        }
        retire()
        main.setSelectedRange(NSRange(location: caret, length: 0))
        main.window?.makeFirstResponder(main)
        main.scrollRangeToVisible(main.selectedRange())
        return true
    }

    // MARK: - Keyboard

    /// ⌘Z in a cell undoes in the document's history.
    func undoManager(for view: NSTextView) -> UndoManager? {
        guard let coordinator, let main = coordinator.textView else { return nil }
        return coordinator.undoManager(for: main)
    }

    /// the reference editor's cell keys: Tab selects the next cell's text, arrows cross
    /// cells in document order and land at the start of the cell above or
    /// below, and Escape never leaves the table.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let table else { return false }
        if isRangeMode { return handleRangeCommand(selector) }
        if extendFromTextEdge(selector) { return true }
        let selection = editor.selectedRange()
        let length = (editor.string as NSString).length
        let caret = selection.length == 0 ? selection.location : nil
        let wholeCell = length > 0 && selection == NSRange(location: 0, length: length)
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            return step(forward: true)
        case #selector(NSResponder.insertBacktab(_:)):
            return step(forward: false)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertParagraphSeparator(_:)):
            // the reference editor: Return, Shift-Return and ⌘Return add a line in the cell.
            insertLineBreak()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥Return opens the link at the caret; elsewhere it is a line break.
            if !openLinkAtCaret() { insertLineBreak() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape closes menus and the selection bar; with none open it does nothing.
            _ = coordinator?.selectionBar?.suppressForEscape()
            return true
        case #selector(NSResponder.moveUp(_:)) where caret != nil && isOnEdgeLine(top: true):
            return moveVertically(down: false, appending: false)
        case #selector(NSResponder.moveDown(_:)) where caret != nil && isOnEdgeLine(top: false):
            return moveVertically(down: true, appending: false)
        case #selector(NSResponder.moveLeft(_:)) where caret == 0:
            return moveHorizontally(forward: false, in: table)
        case #selector(NSResponder.moveRight(_:)) where caret == length || wholeCell:
            return moveHorizontally(forward: true, in: table)
        default:
            return false
        }
    }

    /// Tab order: across, then down. Tab past the last cell adds a row and puts
    /// the caret at the start of its first cell; Shift-Tab in the first cell does nothing.
    func step(forward: Bool) -> Bool {
        guard let table else { return false }
        let index = row * table.columnCount + column + (forward ? 1 : -1)
        if index < 0 { return true }
        if index >= table.rowCount * table.columnCount {
            perform(.insertRow(below: true))
            select(row: row, column: 0)
            moveCaretToStart()
            return true
        }
        select(row: index / table.columnCount, column: index % table.columnCount)
        selectAll()
        return true
    }

    /// ← at a cell's start and → at its end move to the neighbouring cell in
    /// document order, wrapping rows, and leave the table after its last cell.
    private func moveHorizontally(forward: Bool, in table: MarkdownTableSource) -> Bool {
        let index = row * table.columnCount + column + (forward ? 1 : -1)
        guard index >= 0, index < table.rowCount * table.columnCount else {
            leave(table, downward: forward)
            return true
        }
        select(row: index / table.columnCount, column: index % table.columnCount)
        if forward { moveCaretToStart() } else { moveCaretToEnd() }
        return true
    }

    /// ↑ and ↓ land at the start of the same column's cell; they leave the
    /// table at its top and bottom rows. Return moves down, adding a row below the last.
    private func moveVertically(down: Bool, appending: Bool) -> Bool {
        guard let table else { return false }
        let target = row + (down ? 1 : -1)
        if table.rows.indices.contains(target + 1), target >= 0 {
            select(row: target, column: column)
            if !appending { moveCaretToStart() }
            return true
        }
        if down, appending {
            perform(.insertRow(below: true))
            return true
        }
        if appending { return true }
        leave(table, downward: down)
        return true
    }

    /// Hand the caret to the text before or after the table. A table that
    /// starts or ends the document has no text on that side: the cell keeps the caret.
    private func leave(_ table: MarkdownTableSource, downward: Bool) {
        let location = downward ? Self.location(after: table) : Self.location(before: table)
        let outside = downward ? location > Self.lastLineEnd(of: table) : location < table.range.location
        guard outside else {
            if downward, let coordinator, let main = coordinator.textView {
                // The table ends the note: the caret waits in the gap after it.
                finishInput()
                retire(movingCaret: false)
                coordinator.tableGapCaret = table.range.location
                main.setSelectedRange(NSRange(location: (main.string as NSString).length, length: 0))
                main.window?.makeFirstResponder(main)
                (main as? NativeTextView)?.applyBlockImageCaretPolicy()
            }
            return
        }
        end(selecting: location)
    }

    /// A line break in the cell, written to source as `<br>` (or the table's spelling).
    func insertLineBreak() {
        guard isActive else { return }
        editor.insertText("\n", replacementRange: editor.selectedRange())
    }

    /// Whether the caret is on the cell's first (`top`) or last visual line.
    private func isOnEdgeLine(top: Bool) -> Bool {
        let length = (editor.string as NSString).length
        guard length > 0 else { return true }
        let caret = editor.selectedRange().location
        let here = editor.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let edge = editor.firstRect(forCharacterRange: NSRange(location: top ? 0 : length, length: 0), actualRange: nil)
        return abs(here.midY - edge.midY) < 1
    }

    /// Opens a link that covers the caret in the cell's source.
    private func openLinkAtCaret() -> Bool {
        let text = editor.string as NSString
        let caret = editor.selectedRange().location
        var opened = false
        for node in InlineParser.parse(editor.string) {
            guard case .link(let range, _, let url, _, _) = node, caret >= range.location, caret <= NSMaxRange(range) else { continue }
            var destination = InlineParser.decodedLinkDestination(in: text, range: url)
            if destination.lowercased().hasPrefix("www.") { destination = "https://" + destination }
            if let link = URL(string: destination), let main = coordinator?.textView {
                opened = main.delegate?.textView?(main, clickedOnLink: link, at: main.selectedRange().location) ?? false
                if !opened, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(link)
                    opened = true
                }
            }
            break
        }
        return opened
    }

    /// A double-click selects the word under the pointer in the focused cell; a triple-click its whole text.
    func selectText(at windowPoint: NSPoint, clickCount: Int) {
        guard isActive else { return }
        if clickCount >= 3 { selectAll(); return }
        let index = editor.characterIndexForInsertion(at: editor.convert(windowPoint, from: nil))
        let length = (editor.string as NSString).length
        guard length > 0 else { return }
        let proposed = NSRange(location: min(max(0, index), length - 1), length: 0)
        editor.setSelectedRange(editor.selectionRange(forProposedRange: proposed, granularity: .selectByWord))
    }

    private func selectAll() { editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)) }
    private func moveCaretToStart() { editor.setSelectedRange(NSRange(location: 0, length: 0)) }
    private func moveCaretToEnd() { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }

    /// The end of the line before the table (before its line break, CRLF included).
    private static func location(before table: MarkdownTableSource) -> Int {
        guard table.range.location > 0 else { return 0 }
        var contentsEnd = 0
        (table.source as NSString).getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                                                for: NSRange(location: table.range.location - 1, length: 0))
        return contentsEnd
    }

    /// The end of the table's last line, before its line break.
    private static func lastLineEnd(of table: MarkdownTableSource) -> Int {
        table.rows.last.map { NSMaxRange($0.contentRange) } ?? NSMaxRange(table.range)
    }

    /// The first location after the table's last line, whether or not the table's
    /// range includes that line's terminator.
    private static func location(after table: MarkdownTableSource) -> Int {
        let last = max(table.range.location, NSMaxRange(table.range) - 1)
        return NSMaxRange((table.source as NSString).lineRange(for: NSRange(location: last, length: 0)))
    }

    // MARK: - Cell source

    private static func cellSpan(in table: MarkdownTableSource, row: Int, column: Int) -> CellSpan? {
        guard row >= 0, row < table.rowCount, column >= 0, column < table.columnCount else { return nil }
        let cells = table.rows[row == 0 ? 0 : row + 1].cells
        guard column < cells.count else {
            let end = NSMaxRange(cells[cells.count - 1].rawRange)
            return CellSpan(range: NSRange(location: end, length: 0),
                            prefix: String(repeating: "|  ", count: column - cells.count) + "| ", suffix: " ")
        }
        let cell = cells[column]
        guard cell.contentRange.length == 0 else { return CellSpan(range: cell.contentRange) }
        // Text typed into an empty cell starts after one space of padding: `|  |` becomes `| x |`.
        return CellSpan(range: NSRange(location: cell.rawRange.location + min(1, cell.rawRange.length), length: 0))
    }

    /// The cell's source as its editor shows it: each unescaped `<br>` tag is a
    /// line break; everything else, escapes included, is shown raw. Maps a
    /// source selection into the shown text.
    static func decodedCell(_ source: String, selection: NSRange = NSRange(location: 0, length: 0)) -> (text: String, selection: NSRange) {
        let input = source as NSString
        guard source.contains("<") else { return (source, selection) }
        var output: [UInt16] = []
        var offsets = Array(repeating: 0, count: input.length + 1)
        var index = 0
        var slashes = 0
        let tags = MarkdownStyler.lineBreakTag.matches(in: source, range: NSRange(location: 0, length: input.length))
        var nextTag = 0
        while index < input.length {
            offsets[index] = output.count
            while nextTag < tags.count, tags[nextTag].range.location < index { nextTag += 1 }
            if nextTag < tags.count, tags[nextTag].range.location == index, slashes % 2 == 0 {
                let tag = tags[nextTag].range
                for inner in index..<NSMaxRange(tag) { offsets[inner] = output.count }
                output.append(10)
                index = NSMaxRange(tag)
                slashes = 0
                continue
            }
            let unit = input.character(at: index)
            output.append(unit)
            slashes = unit == 92 ? slashes + 1 : 0
            index += 1
        }
        offsets[input.length] = output.count
        let start = offsets[min(selection.location, input.length)]
        let end = offsets[min(NSMaxRange(selection), input.length)]
        return (String(decoding: output, as: UTF16.self), NSRange(location: start, length: max(0, end - start)))
    }

    /// Encode only the edited cell, retaining existing escapes. Map the native
    /// UTF-16 selection through inserted escaping and inline line breaks. A
    /// typed `<br>` tag is escaped (`\<br>`) so it stays text.
    static func encodedCell(_ text: String, selection: NSRange, lineBreak: String = "<br>") -> (text: String, selection: NSRange) {
        let input = Array(text.utf16)
        let typedTags = Set(MarkdownStyler.lineBreakTag.matches(in: text, range: NSRange(location: 0, length: input.count))
            .map(\.range.location))
        var output: [UInt16] = []
        var offsets = Array(repeating: 0, count: input.count + 1)
        var slashes = 0
        var index = 0
        while index < input.count {
            offsets[index] = output.count
            let unit = input[index]
            if unit == 13 || unit == 10 {
                output.append(contentsOf: Array(lineBreak.utf16))
                if unit == 13, index + 1 < input.count, input[index + 1] == 10 {
                    index += 1
                    offsets[index] = output.count
                }
            } else {
                if unit == 124 && slashes % 2 == 0 { output.append(92) }
                if unit == 60 && slashes % 2 == 0 && typedTags.contains(index) { output.append(92) }
                output.append(unit)
            }
            slashes = unit == 92 ? slashes + 1 : 0
            index += 1
        }
        offsets[input.count] = output.count
        let start = offsets[min(selection.location, input.count)]
        let end = offsets[min(NSMaxRange(selection), input.count)]
        return (String(decoding: output, as: UTF16.self), NSRange(location: start, length: max(0, end - start)))
    }
}
