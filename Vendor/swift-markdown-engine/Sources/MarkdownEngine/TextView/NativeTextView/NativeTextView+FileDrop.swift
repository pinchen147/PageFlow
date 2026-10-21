import AppKit
import UniformTypeIdentifiers

/// What a drag's pasteboard holds, as the file-drop routing sees it (doc 26 §9.1).
struct FileDragContents {
    var imageFiles: [URL] = []
    var documents: [URL] = []
    var promises: [NSFilePromiseReceiver] = []
    var hasImageData = false

    var hasImages: Bool { !imageFiles.isEmpty || !promises.isEmpty || hasImageData }

    /// Pasteboard types that carry an image as data.
    static let imageDataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
    ]

    /// The drag's files, promises or image data; nil when it carries none of
    /// them (text, a web URL, rich text), which NSTextView handles as before.
    /// Files are images by their type; `opensDocument` picks the documents
    /// the host opens; any other file is dropped from the drag.
    static func read(from pasteboard: NSPasteboard, opensDocument: ((URL) -> Bool)?) -> FileDragContents? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let hasImageData = pasteboard.availableType(from: imageDataTypes) != nil
        if !urls.isEmpty {
            var contents = FileDragContents()
            for url in urls {
                if isImage(url) {
                    contents.imageFiles.append(url)
                } else if opensDocument?(url) == true {
                    contents.documents.append(url)
                }
            }
            return contents
        }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty {
            var contents = FileDragContents()
            contents.promises = receivers.filter { receiver in
                receiver.fileTypes.contains { UTType($0)?.conforms(to: .image) == true }
            }
            // A promise of anything else still drops its image data (a browser).
            contents.hasImageData = contents.promises.isEmpty && hasImageData
            return contents
        }
        return hasImageData ? FileDragContents(hasImageData: true) : nil
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true
    }
}

/// One file drag over the note, from enter to drop or exit.
final class FileDragSession {
    /// The drag's `draggingSequenceNumber`; nil contents = a text drag.
    let sequence: Int
    let contents: FileDragContents?
    /// The slots near the viewport with the y each line sits at, built at the
    /// first update and rebuilt after a scroll.
    var slots: [(offset: Int, y: CGFloat)] = []
    var slotsBuiltFor: NSRect = .null
    /// The note's fenced code and `$$` math, read once: the text holds still
    /// while the drag is over it.
    var opaqueRanges: [NSRange]?
    /// The slot the drop line marks.
    var slot: Int?
    var reportedKind: MarkdownFileDragKind??
    lazy var indicator = BlockDropIndicatorView(style: .fileDrop)

    init(sequence: Int, contents: FileDragContents?) {
        self.sequence = sequence
        self.contents = contents
    }
}

/// Dropped images being stored; the slot follows every edit made meanwhile.
final class PendingImageImport {
    var slot: Int
    let documentId: String?
    var observer: NSObjectProtocol?
    var indicator: BlockDropIndicatorView?
    var temporaryFolder: URL?
    var isFinished = false
    var completedLinks: [String]?
    var resumeScheduled = false

    init(slot: Int, documentId: String?) {
        self.slot = slot
        self.documentId = documentId
    }

    /// Maps the slot through one storage edit: before the edit it stays, after
    /// it shifts, inside removed text it lands after the replacement.
    func map(editedRange: NSRange, changeInLength: Int) {
        let location = editedRange.location
        let removedEnd = location + editedRange.length - changeInLength
        if slot <= location { return }
        slot = slot >= removedEnd ? slot + changeInLength : NSMaxRange(editedRange)
    }
}

/// The note owns every file drag over it (doc 26 §9.1, §9.6): image files,
/// image data and file promises are copied into the note's `attachments/`
/// folder by the host and land at the nearest block boundary under a drop
/// line; documents the host opens become tabs; any other file is refused.
/// AppKit's own drop (a caret under the pointer, then `readSelection`) never
/// runs for files. Text, URLs and rich text keep NSTextView's handling, and
/// the table handle's drag keeps its own (`NativeTextView+BlockDrag`).
extension NativeTextView {
    static let filePromiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// The types the file drop reads, which the container registers too.
    static let fileDropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + filePromiseTypes + FileDragContents.imageDataTypes

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for type in Self.fileDropTypes + [TableChromeController.tableMoveType] where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    // MARK: Routing

    private enum DragRoute {
        case tableMove
        case files(FileDragSession)
        case text
    }

    /// Reads the pasteboard once per drag: the session remembers the route.
    private func route(_ sender: NSDraggingInfo) -> DragRoute {
        if isTableMove(sender) { return .tableMove }
        let session: FileDragSession
        if let fileDrag, fileDrag.sequence == sender.draggingSequenceNumber {
            session = fileDrag
        } else {
            if fileDrag != nil { endFileDrag() }
            session = FileDragSession(
                sequence: sender.draggingSequenceNumber,
                contents: FileDragContents.read(from: sender.draggingPasteboard, opensDocument: opensDroppedFile)
            )
            fileDrag = session
        }
        return session.contents == nil ? .text : .files(session)
    }

    /// Whether the drag in progress is a file drag this view routes itself.
    private var isRoutingFileDrag: Bool { fileDrag?.contents != nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch route(sender) {
        case .tableMove: return tableMoveUpdated(sender, at: dragPoint(sender))
        case .files(let session): return fileDragUpdated(session, sender: sender, at: dragPoint(sender))
        case .text: return super.draggingEntered(sender)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch route(sender) {
        case .tableMove: return tableMoveUpdated(sender, at: dragPoint(sender))
        case .files(let session): return fileDragUpdated(session, sender: sender, at: dragPoint(sender))
        case .text: return super.draggingUpdated(sender)
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideTableDropIndicator()
        let routed = isRoutingFileDrag
        endFileDrag()
        if routed { return }
        if let sender, isTableMove(sender) { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTableMove(sender) || isRoutingFileDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch route(sender) {
        case .tableMove: return performTableMove(sender, at: dragPoint(sender))
        case .files(let session): return performFileDrop(session, sender: sender, at: dragPoint(sender))
        case .text: return super.performDragOperation(sender)
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        let routed = isRoutingFileDrag
        endFileDrag()
        if routed { return }
        if let sender, isTableMove(sender) { return }
        super.concludeDragOperation(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // A drag that ends without an exit or a drop (cancelled over the note).
        hideTableDropIndicator()
        endFileDrag()
        super.draggingEnded(sender)
    }

    /// The pointer in view coordinates, with x clamped into the text column so
    /// a drag forwarded from the page-look gutters reads the line beside it.
    func dragPoint(_ sender: NSDraggingInfo) -> NSPoint {
        let point = convert(sender.draggingLocation, from: nil)
        let column = textColumnXRange
        return NSPoint(x: min(max(point.x, column.lowerBound), column.upperBound), y: point.y)
    }

    /// The text column's x range in view coordinates.
    private var textColumnXRange: ClosedRange<CGFloat> {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let minX = textContainerOrigin.x + padding
        let width = max(1, (textContainer?.size.width ?? bounds.width) - 2 * padding)
        return minX...(minX + width)
    }

    // MARK: Hover

    private func fileDragUpdated(_ session: FileDragSession, sender: NSDraggingInfo, at point: NSPoint) -> NSDragOperation {
        guard let contents = session.contents else { return [] }
        let mask = sender.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.copy) ? .copy : mask.contains(.generic) ? .generic : []
        if contents.hasImages, isEditable, onImportImages != nil, !operation.isEmpty {
            report(.images, in: session)
            autoscrollForDrag(at: point)
            showFileDropLine(session, at: point)
            return operation
        }
        hideFileDropLine(session)
        if !contents.documents.isEmpty, !operation.isEmpty {
            report(.documents, in: session)
            return operation
        }
        report(nil, in: session)
        return []
    }

    /// Tells the host the drag's kind when it changes; nil is only sent
    /// after a kind was.
    private func report(_ kind: MarkdownFileDragKind?, in session: FileDragSession) {
        guard session.reportedKind != .some(kind) else { return }
        let hadKind = session.reportedKind != nil && session.reportedKind != .some(nil)
        session.reportedKind = .some(kind)
        if kind != nil || hadKind { onFileDragHover?(kind) }
    }

    private func endFileDrag() {
        guard let session = fileDrag else { return }
        fileDrag = nil
        clearFeedback(session)
    }

    /// Hides the drop line and tells the host the drag left.
    private func clearFeedback(_ session: FileDragSession) {
        hideFileDropLine(session)
        report(nil, in: session)
    }

    private func showFileDropLine(_ session: FileDragSession, at point: NSPoint) {
        if session.slots.isEmpty || session.slotsBuiltFor != visibleRect {
            if session.opaqueRanges == nil { session.opaqueRanges = dropOpaqueRanges() }
            session.slots = dropSlotsNearViewport(opaque: session.opaqueRanges)
            session.slotsBuiltFor = visibleRect
        }
        guard let nearest = session.slots.min(by: { abs($0.y - point.y) < abs($1.y - point.y) }) else {
            hideFileDropLine(session)
            return
        }
        let indicator = session.indicator
        let wasShown = indicator.superview === self && !indicator.isHidden
        if indicator.superview !== self { addSubview(indicator, positioned: .above, relativeTo: nil) }
        let column = textColumnXRange
        indicator.place(columnMinX: column.lowerBound, width: column.upperBound - column.lowerBound,
                        centerY: nearest.y, animated: wasShown && session.slot != nearest.offset)
        session.slot = nearest.offset
    }

    private func hideFileDropLine(_ session: FileDragSession) {
        session.slot = nil
        session.indicator.removeFromSuperview()
    }

    /// Within 24 pt of the visible top or bottom (below the floating chrome),
    /// the note scrolls toward the pointer, faster nearer the edge.
    func autoscrollForDrag(at point: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let zone: CGFloat = 24
        let visible = visibleRect
        let top = visible.minY + scrollView.contentInsets.top
        let distance: CGFloat
        if point.y < top + zone {
            distance = -(zone - max(0, point.y - top))
        } else if point.y > visible.maxY - zone {
            distance = zone - max(0, visible.maxY - point.y)
        } else {
            return
        }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += distance / 2
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Slots

    /// The note's fenced code and `$$` math blocks, sorted, from the
    /// coordinator's parse: the only blocks a blank line can sit inside. Nil
    /// without a coordinator (a bare text view), where the note is parsed whole.
    func dropOpaqueRanges() -> [NSRange]? {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return nil }
        let parsed = coordinator.cachedParsedDocument ?? coordinator.parsedDocument(for: string)
        let ranges = parsed.codeTokens.lazy.filter { $0.kind == .codeBlock }.map(\.range) + parsed.blockLatexTokens.map(\.range)
        func map(_ offset: Int) -> Int {
            coordinator.plainInsertionsSinceParse.reduce(offset) { value, insertion in
                value >= insertion.location ? value + insertion.length : value
            }
        }
        return ranges.map { range in
            let start = map(range.location)
            return NSRange(location: start, length: map(NSMaxRange(range)) - start)
        }.sorted { $0.location < $1.location }
    }

    /// The blocks around `window`, parsed from a fresh point before it so a
    /// long note costs the viewport (`BlockDropSlots.blocks(around:)`).
    private func dropBlocks(around window: NSRange, opaque: [NSRange]?) -> [Block] {
        guard let opaque = opaque ?? dropOpaqueRanges() else { return BlockParser.parse(string, memoizing: false) }
        return BlockDropSlots.blocks(around: window, in: string as NSString, opaqueRanges: opaque)
    }

    /// The drop slots in and next to the laid-out viewport, each with the y of
    /// its gap in view coordinates: midway between the previous block's
    /// bottom and the next block's top. Only laid-out fragments are read;
    /// a slot past the viewport sits at the visible edge on its side.
    /// `opaque` is `dropOpaqueRanges()` when the caller kept it.
    func dropSlotsNearViewport(opaque: [NSRange]? = nil) -> [(offset: Int, y: CGFloat)] {
        let text = string as NSString
        guard text.length > 0 else { return [(offset: 0, y: max(1, textContainerOrigin.y))] }
        // No viewport yet (a mount in progress): only a short note is read whole.
        guard let window = viewportCharacterRange
                ?? (prefersEstimatedLayoutChain ? nil : NSRange(location: 0, length: text.length)) else { return [] }
        let offsets = BlockDropSlots.slots(in: text, blocks: dropBlocks(around: window, opaque: opaque), window: window)
        let visible = visibleRect
        return offsets.compactMap { offset -> (offset: Int, y: CGFloat)? in
            if (delegate as? NativeTextViewCoordinator)?.foldLayout.hiddenRange(containing: offset) != nil { return nil }
            if offset < window.location { return (offset: offset, y: visible.minY + 1) }
            if offset > NSMaxRange(window) { return (offset: offset, y: visible.maxY - 1) }
            return dropSlotY(offset, in: text, window: window).map { (offset: offset, y: $0) }
        }
    }

    /// The y of the gap at `offset`, or nil when neither side is laid out.
    private func dropSlotY(_ offset: Int, in text: NSString, window: NSRange) -> CGFloat? {
        var previous = offset - 1
        while previous >= 0, Self.isBlankCharacter(text.character(at: previous)) { previous -= 1 }
        let bottom = previous >= 0 && previous >= window.location ? laidOutFragmentFrame(at: previous)?.maxY : nil
        let top = offset < text.length ? laidOutFragmentFrame(at: offset)?.minY : nil
        switch (bottom, top) {
        case let (bottom?, top?): return (bottom + top) / 2
        case let (bottom?, nil): return bottom + 4
        case let (nil, top?): return max(1, top - 2)
        case (nil, nil): return nil
        }
    }

    private static func isBlankCharacter(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    /// The frame of the laid-out fragment holding `offset`, in view coordinates.
    private func laidOutFragmentFrame(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(layout.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable else { return nil }
        return fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Drop

    private func performFileDrop(_ session: FileDragSession, sender: NSDraggingInfo, at point: NSPoint) -> Bool {
        let slot = session.slot ?? nearestDropSlot(to: point)
        // The session itself ends in `concludeDragOperation`.
        clearFeedback(session)
        // Re-read the pasteboard: the promise receivers must be this drop's.
        let pasteboard = sender.draggingPasteboard
        guard let contents = FileDragContents.read(from: pasteboard, opensDocument: opensDroppedFile) else { return false }
        var handled = false
        if !contents.documents.isEmpty, onDropDocuments?(contents.documents) == true { handled = true }
        if contents.hasImages, isEditable, onImportImages != nil, let slot {
            let data = contents.imageFiles.isEmpty && contents.promises.isEmpty
                ? PasteboardImageReader.imageData(from: pasteboard) : nil
            if !contents.imageFiles.isEmpty || !contents.promises.isEmpty || data != nil {
                window?.makeFirstResponder(self)
                importImages(MarkdownImageDrop(fileURLs: contents.imageFiles, imageData: data),
                             promises: contents.promises, at: slot)
                handled = true
            }
        }
        return handled
    }

    private func nearestDropSlot(to point: NSPoint) -> Int? {
        dropSlotsNearViewport(opaque: fileDrag?.opaqueRanges).min { abs($0.y - point.y) < abs($1.y - point.y) }?.offset
    }

    // MARK: Import

    /// Hands dropped images to the host and inserts its links at `slot` when
    /// it answers. File promises are received into a temporary folder first.
    /// This is the import entry every image drop uses (and the replays).
    func importImages(_ drop: MarkdownImageDrop, promises: [NSFilePromiseReceiver] = [], at slot: Int) {
        guard let onImportImages else { return }
        let pending = PendingImageImport(slot: slot, documentId: (delegate as? NativeTextViewCoordinator)?.documentId)
        pending.observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak pending] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let editedRange = storage.editedRange
            let change = storage.changeInLength
            MainActor.assumeIsolated { pending?.map(editedRange: editedRange, changeInLength: change) }
        }
        pendingImageImports.append(pending)
        // A slow copy shows a spinner on the drop line (I3).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak pending] in
            MainActor.assumeIsolated {
                guard let self, let pending, !pending.isFinished else { return }
                self.showImportProgress(pending)
            }
        }
        let deliver: (MarkdownImageDrop) -> Void = { [weak self, weak pending] drop in
            guard self != nil, let pending, !pending.isFinished else { return }
            onImportImages(drop) { [weak self, weak pending] links in
                let finish = {
                    MainActor.assumeIsolated {
                        guard let self, let pending else { return }
                        self.finishImageImport(pending, links: links)
                    }
                }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
            }
        }
        guard !promises.isEmpty else {
            deliver(drop)
            return
        }
        Self.receive(promises) { [weak pending] files, folder in
            MainActor.assumeIsolated {
                guard let pending, !pending.isFinished else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                pending.temporaryFolder = folder
                deliver(MarkdownImageDrop(fileURLs: drop.fileURLs + files, imageData: files.isEmpty ? drop.imageData : nil))
            }
        }
    }

    /// A source replacement or teardown retires imports before resetting the
    /// document. Ordinary typing only maps their insertion offsets.
    func cancelImageImports() {
        for pending in pendingImageImports { finishImageImport(pending, links: []) }
    }

    /// Input settlement owns retries; a completed import never polls a hidden view.
    /// Deferring also lets teardown cancel after it unmarks native input.
    func resumeCompletedImageImports() {
        for pending in pendingImageImports where pending.completedLinks != nil && !pending.resumeScheduled {
            pending.resumeScheduled = true
            DispatchQueue.main.async { [weak self, weak pending] in
                guard let self, let pending else { return }
                pending.resumeScheduled = false
                guard !pending.isFinished, let links = pending.completedLinks else { return }
                self.finishImageImport(pending, links: links)
            }
        }
    }

    private func finishImageImport(_ pending: PendingImageImport, links: [String]) {
        guard !pending.isFinished else { return }
        let coordinator = delegate as? NativeTextViewCoordinator
        let sameDocument = pending.documentId == coordinator?.documentId
        var protected = coordinator.map { $0.isComposing(in: self) || $0.isWritingToolsActive } ?? hasMarkedText()
        if #available(macOS 15.0, *) { protected = protected || isWritingToolsActive }
        if sameDocument, !links.isEmpty, protected {
            pending.completedLinks = links
            return
        }
        pending.isFinished = true
        pending.completedLinks = nil
        if let observer = pending.observer { NotificationCenter.default.removeObserver(observer) }
        pending.indicator?.removeFromSuperview()
        if let folder = pending.temporaryFolder { try? FileManager.default.removeItem(at: folder) }
        pendingImageImports.removeAll { $0 === pending }
        // The editor moved on to another note while the copy ran.
        guard sameDocument else { return }
        insertDroppedImages(links, at: pending.slot)
    }

    private func showImportProgress(_ pending: PendingImageImport) {
        let text = string as NSString
        let window = viewportCharacterRange ?? NSRange(location: 0, length: text.length)
        guard NSLocationInRange(pending.slot, window) || pending.slot == NSMaxRange(window),
              let y = dropSlotY(min(pending.slot, text.length), in: text, window: window) else { return }
        let indicator = BlockDropIndicatorView(style: .fileDrop)
        addSubview(indicator, positioned: .above, relativeTo: nil)
        let column = textColumnXRange
        indicator.place(columnMinX: column.lowerBound, width: column.upperBound - column.lowerBound, centerY: y, animated: false)
        indicator.showsSpinner = true
        pending.indicator = indicator
    }

    /// Inserts one image link per line at the slot at or after `slot`, as its
    /// own block: one Undo step ("Add Image" / "Add Images"), the caret on
    /// the line after the last image, and an announcement.
    @discardableResult
    func insertDroppedImages(_ links: [String], at slot: Int) -> Bool {
        guard isEditable, !links.isEmpty, let coordinator = delegate as? NativeTextViewCoordinator else { return false }
        let source = string
        let text = source as NSString
        let offset = min(max(0, slot), text.length)
        let around = NSRange(location: offset, length: 0)
        let slots = BlockDropSlots.slots(in: text, blocks: dropBlocks(around: around, opaque: nil), window: around)
        guard let target = BlockDropSlots.slot(atOrAfter: offset, in: slots) else { return false }
        let insertion = BlockDropSlots.insertion(of: links.joined(separator: "\n\n"), at: target, in: text)
        guard coordinator.replaceSourceRanges(
            [NSRange(location: target, length: 0)], with: insertion.text, expectedSource: source,
            actionName: links.count == 1 ? "Add Image" : "Add Images",
            selectionAfter: NSRange(location: target + insertion.caret, length: 0)
        ) else { return false }
        let message = links.count == 1 ? "Image added" : "\(links.count) images added"
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        return true
    }

    // MARK: File promises

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Receives every promised file into a new temporary folder, then calls
    /// `completion` on the main queue with the files in promise order. A
    /// promise that never arrives is given up after 30 s.
    private static func receive(_ receivers: [NSFilePromiseReceiver],
                                completion: @escaping ([URL], URL) -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageFlow Drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = NSLock()
        var received: [[URL]] = Array(repeating: [], count: receivers.count)
        var finished = false
        let group = DispatchGroup()
        for (index, receiver) in receivers.enumerated() {
            let expected = max(1, receiver.fileTypes.count)
            for _ in 0..<expected { group.enter() }
            var remaining = expected
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                lock.lock()
                if error == nil { received[index].append(url) }
                let leave = remaining > 0
                remaining -= 1
                lock.unlock()
                if leave { group.leave() }
            }
        }
        let deliver = {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let files = received.flatMap { $0 }
            lock.unlock()
            completion(files, folder)
        }
        group.notify(queue: .main, execute: deliver)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deliver)
    }
}
