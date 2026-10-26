import Foundation
import os.log

/// One balanced grant shared by the document and any accepted file operations.
final class MarkdownFileAccess: @unchecked Sendable {
    let url: URL
    let isSecurityScoped: Bool
    let requestedSecurityScope: Bool
    /// Minted once per held access: session saves read it on every tab change,
    /// and minting is an XPC round trip.
    private(set) lazy var securityScopedBookmark: Data? = isSecurityScoped ? url.pageFlowSecurityScopedBookmark : nil

    init(url: URL, requestSecurityScope: Bool) {
        self.url = url
        self.requestedSecurityScope = requestSecurityScope
        self.isSecurityScoped = requestSecurityScope && url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }
}

/// Orders physical writes independently of when their background jobs wake up.
/// Admission holds only a short state lock. A synchronous boundary can execute
/// admitted work itself; it never waits for a MainActor continuation to run.
final class MarkdownFileSession: @unchecked Sendable {
    typealias Writer = @Sendable (Data, URL, URL?) throws -> (modDate: Date, scratchDir: URL)

    enum Target: Sendable {
        case current
        case saveAs(MarkdownFileAccess)
    }

    struct Saved: Sendable {
        let sequence: UInt64
        let epoch: UInt64
        let overwriteGeneration: UInt64
        let access: MarkdownFileAccess
        let text: String
        let fidelity: TextFileFidelity
        let modificationDate: Date
    }

    struct Outcome: Sendable {
        let didWrite: Bool
        let saved: Saved?
        /// Why a write failed, for the user.
        var failureReason: String? = nil
    }

    final class Ticket: @unchecked Sendable {
        let sequence: UInt64
        private let lock = NSLock()
        private var outcome: Outcome?
        private var waiter: CheckedContinuation<Outcome, Never>?

        init(sequence: UInt64) { self.sequence = sequence }

        func value() async -> Outcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        var completed: Outcome? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }

        fileprivate func finish(_ value: Outcome) {
            lock.lock()
            outcome = value
            let continuation = waiter
            waiter = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private struct Request {
        let ticket: Ticket
        let epoch: UInt64
        let overwriteGeneration: UInt64
        let text: String
        let target: Target
    }

    private let admissionLock = NSLock()
    private let executionLock = NSLock()
    private var pending: [Request] = []
    private var nextSequence: UInt64 = 0
    // These fields are read/written only while holding executionLock.
    private var access: MarkdownFileAccess?
    private var fidelity: TextFileFidelity = .utf8LF
    private var scratchDirectory: URL?
    private var lastSaved: Saved?
    private let writer: Writer
    private let logger = Logger(subsystem: "com.pageflow", category: "MarkdownDocumentManager")

    init(writer: @escaping Writer) { self.writer = writer }

    func admit(text: String, target: Target, epoch: UInt64, overwriteGeneration: UInt64) -> Ticket {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        nextSequence += 1
        let ticket = Ticket(sequence: nextSequence)
        pending.append(Request(ticket: ticket, epoch: epoch, overwriteGeneration: overwriteGeneration,
                               text: text, target: target))
        return ticket
    }

    private func takeNext(through sequence: UInt64) -> Request? {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard let first = pending.first, first.ticket.sequence <= sequence else { return nil }
        return pending.removeFirst()
    }

    func drain(through sequence: UInt64 = .max) -> Saved? {
        executionLock.lock()
        defer { executionLock.unlock() }
        while let request = takeNext(through: sequence) {
            let outcome = write(request)
            request.ticket.finish(outcome)
        }
        return lastSaved
    }

    /// Call only at a fenced MainActor lifecycle boundary, after a successful read.
    func reset(access: MarkdownFileAccess?, fidelity: TextFileFidelity) {
        executionLock.lock()
        defer { executionLock.unlock() }
        self.access = access
        self.fidelity = fidelity
        scratchDirectory = nil
        lastSaved = nil
    }

    private func write(_ request: Request) -> Outcome {
        let destination: MarkdownFileAccess?
        switch request.target {
        case .current: destination = access
        case .saveAs(let chosen): destination = chosen
        }
        guard let destination else { return Outcome(didWrite: false, saved: lastSaved) }
        let encoded = TextFileCodec.encode(request.text, fidelity: fidelity)
        let scratch = destination.url == access?.url ? scratchDirectory : nil
        do {
            let result = try writer(encoded.data, destination.url, scratch)
            if encoded.downgradedToUTF8 { fidelity.savedAsDowngradedUTF8 = true }
            fidelity.replacedInvalidUTF8 = false   // the written bytes are valid UTF-8
            access = destination
            scratchDirectory = result.scratchDir
            let saved = Saved(sequence: request.ticket.sequence, epoch: request.epoch,
                              overwriteGeneration: request.overwriteGeneration, access: destination,
                              text: request.text, fidelity: fidelity, modificationDate: result.modDate)
            lastSaved = saved
            return Outcome(didWrite: true, saved: saved)
        } catch {
            logger.error("Markdown save failed: \(error.localizedDescription)")
            return Outcome(didWrite: false, saved: lastSaved, failureReason: error.localizedDescription)
        }
    }
}
