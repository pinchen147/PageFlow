import AppKit
@preconcurrency import PDFKit

/// Renders PDF page thumbnails off the main thread so sidebar scrolling never
/// blocks on CoreGraphics rasterization.
///
/// PDFKit's page rendering is thread-safe for read-only thumbnailing — the main
/// `PDFView` and thumbnails can rasterize on different cores simultaneously
/// (WWDC17, "Introducing PDFKit"). Structural document edits bump the page's
/// revision, which cancels and re-issues the affected render via SwiftUI's
/// `.task(id:)`, so a stale render is discarded rather than displayed.
///
/// Concurrency is capped so a fast flick through a long document never spawns
/// more simultaneous rasterizations than the machine can absorb, and cells that
/// scroll away before acquiring a slot skip rendering entirely (cooperative
/// cancellation), eliminating wasted work on fast scrolls.
final class ThumbnailRenderer {
    static let shared = ThumbnailRenderer()

    private let gate: AsyncSemaphore
    private let queue = DispatchQueue(
        label: "com.pageflow.thumbnail-render",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        gate = AsyncSemaphore(value: max(2, min(4, cores - 2)))
    }

    /// Rasterizes `page` at `size` on a background queue. Returns `nil` if the
    /// calling task is cancelled while waiting for or rendering the image.
    func render(page: PDFPage, size: CGSize, box: PDFDisplayBox) async -> NSImage? {
        guard await gate.wait() else { return nil }

        // The cell scrolled away (or its page changed) while we waited for a
        // slot — skip the work entirely.
        if Task.isCancelled {
            await gate.signal()
            return nil
        }

        // PDFPage isn't Sendable; we only read it off-main for a thumbnail
        // (thread-safe per WWDC17 "Introducing PDFKit"), so carry it across the
        // render-queue boundary in an unchecked box.
        let request = ThumbnailRequest(page: page, size: size, box: box)
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            queue.async {
                continuation.resume(returning: request.page.thumbnail(of: request.size, for: request.box))
            }
        }
        await gate.signal()
        return Task.isCancelled ? nil : image
    }
}

/// Carries a non-Sendable `PDFPage` across the render-queue boundary. Safe
/// because the page is only read for off-main thumbnailing and is invalidated
/// via its revision if the underlying document mutates.
private struct ThumbnailRequest: @unchecked Sendable {
    let page: PDFPage
    let size: CGSize
    let box: PDFDisplayBox
}

/// A small async-aware counting semaphore. Unlike `DispatchSemaphore`, waiting
/// suspends the calling task instead of blocking a thread, so capping rendering
/// concurrency never causes thread explosion.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(value: Int) {
        available = max(0, value)
    }

    /// Returns true only when the caller owns a permit. Cancellation removes
    /// queued work immediately, releasing its captured page even if all active
    /// rasterizations are slow. A canceled waiter must not signal a permit.
    func wait() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
