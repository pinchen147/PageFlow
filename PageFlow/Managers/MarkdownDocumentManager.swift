//
//  MarkdownDocumentManager.swift
//  PageFlow
//
//  The text-document analogue of PDFManager: load/save a `.md` on disk with
//  byte-faithful fidelity (ADR-0008), metadata-preserving atomic save-back,
//  security-scoped access, and dirty tracking. Model only — no view, no engine.
//
//  Source-of-truth contract (ADR-0012 D2): `text` is the durable, normalized
//  (`\n`) form and the sole source of truth when the editor is unmounted; while
//  mounted, the fork's live NSTextStorage is authoritative and is reconciled into
//  `text` at every save/close/quit boundary (patch P1, `MarkdownContent.reconcileLiveText`).
//  Dirty compares the normalized text with what disk will hold once queued writes
//  land, plus a pending external-overwrite decision or a vanished backing file —
//  never a diff against raw on-disk bytes (which would make a CRLF file
//  perpetually dirty, ADR-0008). The note's comments (doc 25) are a hidden block
//  at the end of the file: `text` is the file without it, `commentBlock` the
//  block, and the file is their join (`source`).
//

import Foundation
import MarkdownEngine
import os.log

@Observable
@MainActor
final class MarkdownDocumentManager {

    /// The durable, normalized (`\n`) text — the binding the editor edits and the
    /// source of truth when unmounted. Public `var`: the view layer reads/writes it.
    var text: String = "" {
        didSet { refreshDerivedText() }
    }

    /// The heading outline and word count of `text`, recomputed when the text
    /// changes — a commit after a typing pause, a load, a reload — instead of on
    /// every SwiftUI body evaluation, which re-scanned the whole note per frame
    /// (27 ms per body on a 500 KB note, per zoom tick and slider frame).
    private(set) var outline: [MarkdownOutlineItem] = []
    private(set) var wordCount = WordCount(words: 0, characters: 0)

    private func refreshDerivedText() {
        outline = MarkdownOutline.parse(text)
        wordCount = WordCount.count(text)
    }

    /// The note's comments (doc 25): the hidden block at the end of the file,
    /// split off at load so the editor never sees it; empty when it has none.
    private(set) var commentBlock: String = ""

    /// A comment changed: the note is unsaved until the block is written.
    func setCommentBlock(_ block: String) {
        guard block != commentBlock else { return }
        commentBlock = block
    }

    /// What the file holds: the text, then the comment block.
    var source: String { MarkdownCommentBlock.join(body: text, block: commentBlock) }

    /// Normalized snapshot of the whole file (comment block included) from the
    /// last successful load or save; the dirty-diff base. Updated only when
    /// bytes actually reach disk.
    private(set) var savedText: String = ""

    /// Exact normalized source last read, written or acknowledged on disk.
    /// Separate from savedText: Keep My Version accepts the external source
    /// without replacing the local draft or clearing its overwrite decision.
    @ObservationIgnored private var acknowledgedDiskSource: String?

    /// Keep My Version requires a write even if the buffer still equals savedText.
    private var hasPendingExternalOverwrite = false
    @ObservationIgnored private var externalOverwriteGeneration: UInt64 = 0
    @ObservationIgnored private var pendingOverwriteURL: URL?
    @ObservationIgnored private var documentEpoch: UInt64 = 0
    @ObservationIgnored private var lastAppliedWrite: UInt64 = 0
    @ObservationIgnored private var pendingWrites = 0
    @ObservationIgnored private var pendingSaveAsWrites = 0
    private(set) var isClosed = false

    /// True for local edits or a retained version that still needs saving. An empty,
    /// never-edited untitled document is therefore *not* dirty (ADR-0012 D6).
    // Markdown is source text: canonically equivalent Unicode can still change
    // the bytes that Save must preserve.
    // Dirty compares against what disk will hold once queued writes land, so
    // undoing back to the old saved text mid-save still reads as unsaved.
    var isDirty: Bool {
        hasPendingExternalOverwrite || isBackingFileMissing
            || !source.hasSameSource(as: queuedWrite?.text ?? savedText)
    }

    /// The backing file was deleted or moved away and the tab stayed open: it is
    /// unsaved until a save writes the file back.
    private(set) var isBackingFileMissing = false

    /// The newest admitted write that has not resolved yet.
    private var queuedWrite: (sequence: UInt64, text: String)?

    /// The save target + persistence/dedup key. `nil` for an untitled document
    /// (decoupled from tab identity, ADR-0012 D4).
    private(set) var documentURL: URL?

    /// Encoding + line-ending + BOM needed to reproduce the file on save.
    private(set) var fidelity: TextFileFidelity = .utf8LF

    /// The file had damaged UTF-8 bytes, shown as U+FFFD; the next save
    /// replaces them, so the host asks first.
    var hasInvalidUTF8: Bool { fidelity.replacedInvalidUTF8 }

    /// The file's modification date at the last load, save or matching disk check.
    /// The external-change check (ADR-0012 D5) compares decoded source; the date
    /// decides only for a file that exists but can't be read.
    private(set) var contentModificationDate: Date?

    /// Set once when bytes were saved in a different encoding than they were read
    /// (a UTF-16/32 source written as UTF-8, or a character that overflowed an
    /// 8-bit encoding). Surfaced to the user as a one-time note — never silent.
    private(set) var encodingWasDowngraded = false

    /// Shared with accepted writes so a re-home or close cannot release access
    /// while physical I/O still needs it.
    @ObservationIgnored private var fileAccess: MarkdownFileAccess?

    /// Save-latency signposts (subsystem com.pageflow / category Saving) — free
    /// with no profiler attached; Instruments shows exactly where a slow ⌘S goes.
    /// `nonisolated`: `writeData` reads it off the main actor (OSSignposter is Sendable).
    nonisolated private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.pageflow", category: "Saving")
    )

    /// A security-scoped bookmark for the currently open document when it is held
    /// under a security scope (sandboxed open), or `nil` otherwise — the canonical
    /// primitive shared with `PDFManager.securityScopedBookmark`, consumed by
    /// session restore (S8). A pure read of the held scope: session capture reads it
    /// while the scope is still held, so a `.withSecurityScope` bookmark can be
    /// minted. Non-scoped (Finder-opened / non-sandbox) documents return `nil`.
    var securityScopedBookmark: Data? {
        fileAccess?.securityScopedBookmark
    }
    private let logger = Logger(subsystem: "com.pageflow", category: "MarkdownDocumentManager")

    typealias FileWriter = MarkdownFileSession.Writer
    typealias WriteScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private let fileSession: MarkdownFileSession
    @ObservationIgnored private let scheduleWrite: WriteScheduler

    init(
        fileWriter: @escaping FileWriter = { data, url, scratch in
            try MarkdownDocumentManager.writeData(data, to: url, reusingScratchDir: scratch)
        },
        scheduleWrite: @escaping WriteScheduler = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    ) {
        self.fileSession = MarkdownFileSession(writer: fileWriter)
        self.scheduleWrite = scheduleWrite
    }

    /// Display title for menus/dialogs (e.g. the unsaved-changes prompt).
    var documentTitle: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var hasDocumentURL: Bool { documentURL != nil }
    var hasSaveDestination: Bool { documentURL != nil || pendingSaveAsWrites > 0 }
    var hasPendingWrites: Bool { pendingWrites > 0 }
    var usesSecurityScopedAccess: Bool { fileAccess?.requestedSecurityScope == true }

    // MARK: - Load

    enum LoadError: LocalizedError {
        /// The file holds binary data under a Markdown extension.
        case notText

        var errorDescription: String? { "It isn't a text file." }
    }

    /// Reads `url`, detecting and storing its encoding/EOL/BOM, and normalizes the
    /// in-memory buffer to `\n`. Holds the security scope for the document's
    /// lifetime (released by `close()`/deinit), mirroring PDFManager.
    func load(from url: URL, isSecurityScoped: Bool = false) throws {
        let access = MarkdownFileAccess(url: url, requestSecurityScope: isSecurityScoped)
        finishPendingWrites()
        do {
            PerfTrace.stamp("load.start")
            let data = try Data(contentsOf: url)
            guard !TextFileCodec.looksBinary(data) else { throw LoadError.notText }
            let decoded = TextFileCodec.decode(data)
            PerfTrace.stamp("load.decoded")

            documentEpoch &+= 1
            queuedWrite = nil
            isBackingFileMissing = false
            isClosed = false
            fileAccess = access
            fileSession.reset(access: access, fidelity: decoded.fidelity)
            let parts = MarkdownCommentBlock.split(decoded.text)
            text = parts.body
            commentBlock = parts.block
            savedText = decoded.text
            acknowledgedDiskSource = decoded.text
            fidelity = decoded.fidelity
            documentURL = url
            encodingWasDowngraded = decoded.fidelity.savedAsDowngradedUTF8
            contentModificationDate = modificationDate(of: url)
            hasPendingExternalOverwrite = false
            pendingOverwriteURL = nil
        } catch {
            logger.error("Markdown load failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Save

    struct SaveCompletion {
        let didWrite: Bool
        /// False after a newer save or a document lifecycle change superseded it.
        let isCurrent: Bool
        /// Why the write failed, when it did.
        var failureReason: String? = nil
    }

    /// Async save to the current URL, resolved after earlier accepted Save-As work.
    func save() async -> Bool { await saveWithCompletion().didWrite }

    func saveWithCompletion() async -> SaveCompletion {
        guard hasSaveDestination, !isClosed else { return SaveCompletion(didWrite: false, isCurrent: !isClosed) }
        return await performAsyncWrite(target: .current)
    }

    /// Modal save fences older writes before writing the current live snapshot.
    func saveSync() -> Bool {
        guard hasSaveDestination, !isClosed else { return false }
        return performSyncWrite(target: .current)
    }

    func saveAs(to url: URL, isSecurityScoped: Bool = false) async -> Bool {
        await saveAsWithCompletion(to: url, isSecurityScoped: isSecurityScoped).didWrite
    }

    func saveAsWithCompletion(to url: URL, isSecurityScoped: Bool = false) async -> SaveCompletion {
        guard !isClosed else { return SaveCompletion(didWrite: false, isCurrent: false) }
        let access = MarkdownFileAccess(url: url, requestSecurityScope: isSecurityScoped)
        return await performAsyncWrite(target: .saveAs(access))
    }

    func saveAsSync(to url: URL, isSecurityScoped: Bool = false) -> Bool {
        guard !isClosed else { return false }
        let access = MarkdownFileAccess(url: url, requestSecurityScope: isSecurityScoped)
        return performSyncWrite(target: .saveAs(access))
    }

    /// Seeds a brand-new UNTITLED document with starter content (the Obsidian
    /// new-note pattern: `# Untitled`). The seed is PRISTINE — `savedText` is
    /// set to the same string, so the document is not dirty until the user
    /// actually edits it (an untouched new tab must close/quit without a save
    /// prompt, the spirit of ADR-0012 D6). No-op on a file-backed or already-
    /// typed-in document.
    func seedUntitled(_ seed: String) {
        guard documentURL == nil, text.isEmpty, commentBlock.isEmpty else { return }
        text = seed
        savedText = seed
    }

    /// Releases the security scope. Call from the owning session's teardown.
    func close() {
        finishPendingWrites()
        documentEpoch &+= 1
        queuedWrite = nil
        isBackingFileMissing = false
        isClosed = true
        acknowledgedDiskSource = nil
        fileAccess = nil
        fileSession.reset(access: nil, fidelity: .utf8LF)
    }

    // MARK: - External change (ADR-0012 D5)

    /// What happened to the backing file since this document last read, wrote
    /// or acknowledged it.
    enum DiskChange: Equatable, Sendable {
        case unchanged
        case modified
        /// Deleted or moved away: there is nothing to reload.
        case missing
    }

    /// The state a disk check compares against, captured on the main actor so
    /// the read itself can run on any thread.
    struct DiskProbe: Sendable {
        fileprivate let url: URL
        fileprivate let baseline: String
        fileprivate let baselineDate: Date?
        fileprivate let epoch: UInt64
    }

    /// One read of the backing file.
    struct DiskObservation: Sendable {
        fileprivate let change: DiskChange
        fileprivate let modificationDate: Date?
    }

    /// A probe for an open, file-backed document.
    func diskProbe() -> DiskProbe? {
        guard !isClosed, let url = documentURL else { return nil }
        return DiskProbe(url: url, baseline: acknowledgedDiskSource ?? savedText,
                         baselineDate: contentModificationDate, epoch: documentEpoch)
    }

    /// Compares exact normalized source. Dates cannot establish equality:
    /// external replacements can preserve or move them back, and canonically
    /// equivalent Unicode still changes the Markdown source. Blocking I/O (an
    /// evicted iCloud file downloads here), so focus checks run it off main.
    nonisolated static func observe(_ probe: DiskProbe) -> DiskObservation {
        let path = probe.url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return DiskObservation(change: .missing, modificationDate: nil)
        }
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: probe.url) else {
            // Present but unreadable: only a newer known version can prompt.
            let newer = date.flatMap { current in probe.baselineDate.map { current > $0 } } ?? false
            return DiskObservation(change: newer ? .modified : .unchanged, modificationDate: nil)
        }
        let same = TextFileCodec.decode(data).text.hasSameSource(as: probe.baseline)
        return DiskObservation(change: same ? .unchanged : .modified, modificationDate: date)
    }

    /// Applies an observation on the main actor and returns what still needs
    /// the user. A stale probe, an identical rewrite (its date is adopted) and a
    /// missing file the tab already kept need nothing.
    func resolve(_ observation: DiskObservation, for probe: DiskProbe) -> DiskChange {
        guard let current = diskProbe(), current.epoch == probe.epoch, current.url == probe.url,
              current.baseline.hasSameSource(as: probe.baseline) else { return .unchanged }
        switch observation.change {
        case .missing:
            return isBackingFileMissing ? .unchanged : .missing
        case .unchanged:
            isBackingFileMissing = false
            if let date = observation.modificationDate { contentModificationDate = date }
            return .unchanged
        case .modified:
            isBackingFileMissing = false
            return .modified
        }
    }

    /// The synchronous check for save, close and quit boundaries.
    func diskChange() -> DiskChange {
        guard let probe = diskProbe() else { return .unchanged }
        return resolve(Self.observe(probe), for: probe)
    }

    func diskWasModifiedExternally() -> Bool { diskChange() == .modified }

    /// Keeps the tab after its file vanished; Save writes it back.
    func keepAfterMissingFile() {
        guard !isClosed, documentURL != nil else { return }
        isBackingFileMissing = true
    }

    /// Close and quit boundaries: a vanished file makes a clean tab unsaved, so
    /// the close prompt still offers to write it back instead of dropping it.
    func noteMissingBackingFile() {
        guard !isClosed, let url = documentURL, !FileManager.default.fileExists(atPath: url.path) else { return }
        isBackingFileMissing = true
    }

    /// Re-reads the file from disk, re-detecting encoding/EOL/BOM and refreshing the
    /// dirty baseline — the "Reload" half of the external-change prompt (ADR-0012 D5).
    /// After this the buffer is clean (`text == savedText == on-disk`); the caller
    /// resets the editor's undo stack, since ⌘Z cannot span an external rewrite. Reads
    /// within the security scope `load()` already holds. A no-op (returns) for an
    /// untitled document; throws (leaving the current buffer intact) if the file
    /// can't be read. Mirrors `load`'s state updates minus the scope acquisition.
    func reload() throws {
        guard !isClosed else { return }
        finishPendingWrites()
        guard let url = documentURL else { return }
        let data = try Data(contentsOf: url)
        let decoded = TextFileCodec.decode(data)
        documentEpoch &+= 1
        queuedWrite = nil
        fileSession.reset(access: fileAccess, fidelity: decoded.fidelity)
        let parts = MarkdownCommentBlock.split(decoded.text)
        text = parts.body
        commentBlock = parts.block
        savedText = decoded.text
        acknowledgedDiskSource = decoded.text
        fidelity = decoded.fidelity
        encodingWasDowngraded = decoded.fidelity.savedAsDowngradedUTF8
        contentModificationDate = modificationDate(of: url)
        hasPendingExternalOverwrite = false
        pendingOverwriteURL = nil
        isBackingFileMissing = false
    }

    /// Acknowledges this external change while retaining the local source. The
    /// overwrite decision stays dirty until a successful save or deliberate reload.
    func keepLocalVersionIgnoringDisk() {
        guard !isClosed, let url = documentURL else { return }
        if let data = try? Data(contentsOf: url) {
            acknowledgedDiskSource = TextFileCodec.decode(data).text
        }
        contentModificationDate = modificationDate(of: url)
        externalOverwriteGeneration &+= 1
        pendingOverwriteURL = url
        hasPendingExternalOverwrite = true
    }

    // MARK: - Private

    private func performAsyncWrite(target: MarkdownFileSession.Target) async -> SaveCompletion {
        let interval = Self.signposter.beginInterval("markdown.save")
        defer { Self.signposter.endInterval("markdown.save", interval) }
        pendingWrites += 1
        let isSaveAs: Bool
        if case .saveAs = target { isSaveAs = true } else { isSaveAs = false }
        if isSaveAs { pendingSaveAsWrites += 1 }
        defer {
            pendingWrites -= 1
            if isSaveAs { pendingSaveAsWrites -= 1 }
        }
        let epoch = documentEpoch
        let source = source
        let ticket = fileSession.admit(text: source, target: target, epoch: epoch,
                                       overwriteGeneration: externalOverwriteGeneration)
        queuedWrite = (ticket.sequence, source)
        let session = fileSession
        scheduleWrite { _ = session.drain(through: ticket.sequence) }
        let outcome = await ticket.value()
        applySaved(outcome.saved)
        resolveQueuedWrite(through: ticket.sequence)
        return SaveCompletion(didWrite: outcome.didWrite,
                              isCurrent: !isClosed && documentEpoch == epoch && ticket.sequence >= lastAppliedWrite,
                              failureReason: outcome.failureReason)
    }

    private func performSyncWrite(target: MarkdownFileSession.Target) -> Bool {
        let ticket = fileSession.admit(text: source, target: target, epoch: documentEpoch,
                                       overwriteGeneration: externalOverwriteGeneration)
        applySaved(fileSession.drain(through: ticket.sequence))
        resolveQueuedWrite(through: ticket.sequence)
        return ticket.completed?.didWrite == true
    }

    /// Lands every queued write (quit and close call this before judging dirty).
    func finishPendingWrites() {
        applySaved(fileSession.drain())
        queuedWrite = nil
    }

    /// A resolved write no longer predicts disk: success moved `savedText`, and a
    /// failure leaves disk at the last saved source.
    private func resolveQueuedWrite(through sequence: UInt64) {
        if let queued = queuedWrite, queued.sequence <= sequence { queuedWrite = nil }
    }

    private func applySaved(_ saved: MarkdownFileSession.Saved?) {
        guard let saved, !isClosed, saved.epoch == documentEpoch,
              saved.sequence > lastAppliedWrite else { return }
        lastAppliedWrite = saved.sequence
        savedText = saved.text
        let hasNewerKeep = pendingOverwriteURL == saved.access.url &&
            saved.overwriteGeneration != externalOverwriteGeneration
        if !hasNewerKeep {
            acknowledgedDiskSource = saved.text
        } else if let data = try? Data(contentsOf: saved.access.url),
                  TextFileCodec.decode(data).text.hasSameSource(as: saved.text) {
            // Keep may run before or after this write physically finishes.
            // Adopt our own installed source, but retain a later acknowledgment.
            acknowledgedDiskSource = saved.text
        }
        documentURL = saved.access.url
        fileAccess = saved.access
        isBackingFileMissing = false
        fidelity = saved.fidelity
        contentModificationDate = saved.modificationDate
        if pendingOverwriteURL != saved.access.url || saved.overwriteGeneration == externalOverwriteGeneration {
            hasPendingExternalOverwrite = false
            pendingOverwriteURL = nil
        }
        if saved.fidelity.savedAsDowngradedUTF8 { encodingWasDowngraded = true }
    }

    private func modificationDate(of url: URL) -> Date? {
        // Stat the path fresh via FileManager — `URL.resourceValues` caches values
        // on the (long-lived) URL instance, so it would return the mod-date read at
        // load and never detect a later external change.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Metadata-preserving atomic save-back (the locked write primitive): write to
    /// a same-volume temp, then `replaceItemAt` inside an `NSFileCoordinator`,
    /// which keeps the destination's inode metadata, POSIX permissions, Finder
    /// tags, and extended attributes — none of which a bare atomic write keeps.
    /// `nonisolated` so it runs off the main actor for the async `save()` path.
    ///
    /// `reusingScratchDir`: a previously returned same-volume scratch directory,
    /// validated and reused (creating one is a sandbox IPC round-trip — the
    /// dominant fixed cost of a small save). The temp file gets a unique name
    /// (concurrent async + quit-sync saves can't collide) and is CONSUMED by the
    /// replace on success, removed on failure; the directory itself lives in the
    /// system's TemporaryItems and is reclaimed by the OS, so a crash can never
    /// strand a temp file in the user's document folder.
    nonisolated static func writeData(
        _ data: Data,
        to url: URL,
        reusingScratchDir: URL?
    ) throws -> (modDate: Date, scratchDir: URL) {
        let signpostState = signposter.beginInterval("markdown.write")
        defer { signposter.endInterval("markdown.write", signpostState) }
        let fileManager = FileManager.default
        let scratchDir: URL
        if let reusingScratchDir, fileManager.fileExists(atPath: reusingScratchDir.path) {
            scratchDir = reusingScratchDir
        } else {
            scratchDir = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        }
        let tempURL = scratchDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        // Plain (non-atomic) temp write: atomicity comes from `replaceItemAt`;
        // an atomic write HERE would be a redundant second write+rename.
        try data.write(to: tempURL)

        var coordinatorError: NSError?
        var ioError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { destination in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
                } else {
                    // Save-As to a fresh path: no existing inode to preserve.
                    try fileManager.moveItem(at: tempURL, to: destination)
                }
            } catch {
                ioError = error
            }
        }

        if coordinatorError != nil || ioError != nil {
            try? fileManager.removeItem(at: tempURL)
        }
        if let coordinatorError { throw coordinatorError }
        if let ioError { throw ioError }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return ((attributes?[.modificationDate] as? Date) ?? Date(), scratchDir)
    }
}
