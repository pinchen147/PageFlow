import Foundation
import os.log

/// A balanced file-access grant retained by accepted writes until they finish.
final class PDFFileAccess: @unchecked Sendable {
    let url: URL
    let isSecurityScoped: Bool
    /// Minted once per held access (an XPC round trip read on every tab change).
    private(set) lazy var bookmark: Data? = url.pageFlowSecurityScopedBookmark

    init(url: URL, requestSecurityScope: Bool = false) {
        self.url = url
        isSecurityScoped = requestSecurityScope && url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }
}

/// Owns only immutable PDF bytes and file destinations. PDFKit serialization
/// stays on MainActor. Any worker may drain the admitted FIFO; modal saves can
/// finish it synchronously without waiting for a MainActor completion callback.
final class PDFFileSession: @unchecked Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    enum Target: Sendable {
        case current
        case saveAs(PDFFileAccess)
    }
    struct Saved: Sendable {
        let sequence: UInt64
        let epoch: UInt64
        let revision: UInt64
        let access: PDFFileAccess
    }
    struct Outcome: Sendable {
        let didWrite: Bool
        let saved: Saved?
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
        var tickets: [Ticket]
        var data: Data
        let target: Target
        let epoch: UInt64
        var revision: UInt64
    }
    private let admissionLock = NSLock()
    private let executionLock = NSLock()
    private var pending: [Request] = []
    private var nextSequence: UInt64 = 0
    // File identity and receipts are protected by executionLock.
    private var access: PDFFileAccess?
    private var lastSaved: Saved?
    private let writer: Writer
    private let logger = Logger(subsystem: "com.pageflow", category: "PDFManager")

    init(writer: @escaping Writer) { self.writer = writer }

    func admit(data: Data, target: Target, epoch: UInt64, revision: UInt64) -> Ticket {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        nextSequence += 1
        let ticket = Ticket(sequence: nextSequence)
        // Only redundant queued Save commands merge. Save As remains an explicit
        // destination boundary, including the current-file identity it establishes.
        if case .current = target, let last = pending.indices.last,
           case .current = pending[last].target, pending[last].epoch == epoch {
            pending[last].tickets.append(ticket)
            pending[last].data = data
            pending[last].revision = revision
        } else {
            pending.append(Request(tickets: [ticket], data: data, target: target, epoch: epoch, revision: revision))
        }
        return ticket
    }
    private func takeNext(through sequence: UInt64) -> Request? {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard let first = pending.first, first.tickets[0].sequence <= sequence else { return nil }
        return pending.removeFirst()
    }
    func drain(through sequence: UInt64 = .max) -> Saved? {
        executionLock.lock()
        defer { executionLock.unlock() }
        while let request = takeNext(through: sequence) {
            let outcome = write(request)
            request.tickets.forEach { $0.finish(outcome) }
        }
        return lastSaved
    }
    /// The caller has fenced the previous identity before replacing it.
    func reset(access: PDFFileAccess?) {
        executionLock.lock()
        defer { executionLock.unlock() }
        self.access = access
        lastSaved = nil
    }
    private func write(_ request: Request) -> Outcome {
        let destination: PDFFileAccess?
        switch request.target {
        case .current: destination = access
        case .saveAs(let chosen): destination = chosen
        }
        guard let destination else { return Outcome(didWrite: false, saved: lastSaved) }
        do {
            try writer(request.data, destination.url)
            access = destination
            let saved = Saved(sequence: request.tickets.last!.sequence, epoch: request.epoch,
                              revision: request.revision, access: destination)
            lastSaved = saved
            return Outcome(didWrite: true, saved: saved)
        } catch {
            logger.error("PDF save failed: \(error.localizedDescription)")
            return Outcome(didWrite: false, saved: lastSaved)
        }
    }
}
