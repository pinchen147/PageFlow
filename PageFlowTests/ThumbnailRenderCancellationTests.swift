import PDFKit
import Testing
@testable import PageFlow

@MainActor
@Suite("Thumbnail render cancellation")
struct ThumbnailRenderCancellationTests {
    @Test("canceling a queued render releases its page before another render finishes")
    func cancellationReleasesQueuedPage() async throws {
        let gate = AsyncSemaphore(value: 0)
        weak var queuedPage: PDFPage?
        var started = false
        var finished = false
        let request: Task<Void, Never> = {
            let page = PDFPage()
            queuedPage = page
            return Task { [page] in
                _ = await gate.waitConfirmingQueued { started = true }
                withExtendedLifetime(page) { finished = true }
            }
        }()
        let startDeadline = ContinuousClock.now + .seconds(1)
        while !started, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
        #expect(queuedPage != nil)
        request.cancel()
        let cancellationDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished, "canceled work must retire without waiting for an active rasterizer")
        #expect(queuedPage == nil, "the canceled request still retains its PDF page")
        // Release the gate even on the old implementation so a failure cannot
        // leave an unresumed continuation in the test process.
        await gate.signal()
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished)
    }

    @Test("cancellation racing with a permit leaves the concurrency limit intact")
    func cancellationPreservesPermits() async throws {
        let gate = AsyncSemaphore(value: 2)
        var active = 0
        var maximumActive = 0
        var completed = 0
        var finished = 0
        var successfulIDs: Set<Int> = []
        var canceledIDs: Set<Int> = []
        var requests: [Task<Void, Never>] = []
        for _ in 0..<20 {
            for index in 0..<40 {
                let id = requests.count
                let request = Task {
                    defer { finished += 1 }
                    guard await gate.wait() else { return }
                    active += 1
                    maximumActive = max(maximumActive, active)
                    await Task.yield()
                    active -= 1
                    await gate.signal()
                    completed += 1
                    successfulIDs.insert(id)
                }
                requests.append(request)
                if index.isMultiple(of: 2) {
                    canceledIDs.insert(id)
                    request.cancel()
                }
            }
            // Allow requests to both acquire and queue before cancellation.
            await Task.yield()
            for (index, request) in requests.enumerated() where index.isMultiple(of: 3) {
                canceledIDs.insert(index)
                request.cancel()
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while finished < requests.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished == requests.count, "a permit was lost or a canceled waiter never resumed")
        let expected = Set(requests.indices).subtracting(canceledIDs)
        #expect(expected.isSubset(of: successfulIDs), "uncanceled requests must acquire a render slot")
        // Bounded cleanup also retires tasks if a future regression loses a slot.
        for request in requests { request.cancel() }
        for _ in requests { await gate.signal() }
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while finished < requests.count, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished == requests.count)
        #expect(completed > 0)
        #expect(active == 0)
        #expect(maximumActive <= 2)
    }

    @Test("live thumbnail requests retain pixels and make progress through canceled work")
    func renderingSurvivesCancellation() async throws {
        let source = NSImage(size: NSSize(width: 120, height: 160))
        source.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 160).fill()
        source.unlockFocus()
        let page = try #require(PDFPage(image: source))
        let document = PDFDocument()
        document.insert(page, at: 0)
        defer { withExtendedLifetime(document) {} }
        var completed = 0
        var images: [Int: NSImage] = [:]
        let requests = (0..<40).map { index in
            let task = Task {
                defer { completed += 1 }
                images[index] = await ThumbnailRenderer.shared.render(
                    page: page, size: CGSize(width: 60, height: 80), box: .mediaBox)
            }
            if index.isMultiple(of: 2) { task.cancel() }
            return task
        }
        defer { for task in requests { task.cancel() } }
        let deadline = ContinuousClock.now + .seconds(3)
        while completed < requests.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(completed == requests.count, "the renderer lost a slot after cancellation")
        for index in stride(from: 1, to: requests.count, by: 2) {
            let image = try #require(images[index])
            #expect(image.size == NSSize(width: 60, height: 80))
            let data = try #require(image.tiffRepresentation)
            let pixels = try #require(NSBitmapImageRep(data: data))
            let center = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            // PDFKit color-manages device RGB into sRGB; channel values need
            // not equal the source triplet. The red field must remain red,
            // rather than turning blank/transparent or losing its content.
            #expect(center.redComponent > 0.8 && center.greenComponent < 0.4 && center.blueComponent < 0.4)
            #expect(center.alphaComponent > 0.99)
        }
    }

    @Test("ending a cold drag releases its queued page without waiting for a rasterizer")
    func dragEndCancelsQueuedRender() async throws {
        let preview = ThumbnailDragPreview()
        let gate = AsyncSemaphore(value: 0)
        weak var queuedPage: PDFPage?
        var started = false
        var finished = false
        do {
            let page = PDFPage()
            queuedPage = page
            preview.show(cached: nil) { [page] in
                defer { finished = true }
                guard await gate.waitConfirmingQueued({ started = true }) else { return nil }
                return withExtendedLifetime(page) { NSImage(size: NSSize(width: 20, height: 20)) }
            }
        }
        let startDeadline = ContinuousClock.now + .seconds(1)
        while !started, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
        #expect(queuedPage != nil)
        preview.clear()
        let endDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < endDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished, "ending the drag must cancel the queued request")
        #expect(queuedPage == nil, "the ended drag must not retain its PDF page")
        await gate.signal()
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished)
    }

    enum NextDrag: CaseIterable {
        case ended, cached, cold, canceledCold
    }

    @Test("a late cold result cannot resurrect or replace a drag preview", arguments: NextDrag.allCases)
    func lateDragResultCannotPublish(next: NextDrag) async throws {
        let preview = ThumbnailDragPreview()
        let oldImage = NSImage(size: NSSize(width: 20, height: 20))
        let newImage = NSImage(size: NSSize(width: 30, height: 30))
        var oldCompletion: CheckedContinuation<NSImage?, Never>?
        var newCompletion: CheckedContinuation<NSImage?, Never>?
        var oldFinished = false
        var newFinished = false
        defer {
            oldCompletion?.resume(returning: nil)
            newCompletion?.resume(returning: nil)
            preview.clear()
        }
        preview.show(cached: nil) {
            defer { oldFinished = true }
            return await withCheckedContinuation { oldCompletion = $0 }
        }
        let startDeadline = ContinuousClock.now + .seconds(1)
        while oldCompletion == nil, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let oldPending = try #require(oldCompletion)
        switch next {
        case .ended:
            preview.clear()
        case .cached:
            preview.show(cached: newImage) { Issue.record("a cached preview must not render"); return nil }
        case .cold, .canceledCold:
            preview.show(cached: nil) {
                defer { newFinished = true }
                return await withCheckedContinuation { newCompletion = $0 }
            }
            let newStartDeadline = ContinuousClock.now + .seconds(1)
            while newCompletion == nil, ContinuousClock.now < newStartDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(newCompletion != nil)
        }
        #expect(preview.image === (next == .cached ? newImage : nil), "cached pickup stays synchronous")
        // Finish even after cancellation, like an in-flight rasterizer. This
        // obsolete completion must also leave the newer request cancelable.
        oldCompletion = nil
        oldPending.resume(returning: oldImage)
        let oldEndDeadline = ContinuousClock.now + .seconds(1)
        while !oldFinished, ContinuousClock.now < oldEndDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(oldFinished)
        #expect(preview.image === (next == .cached ? newImage : nil))
        if next == .cold || next == .canceledCold {
            if next == .canceledCold { preview.clear() }
            let pending = try #require(newCompletion)
            newCompletion = nil
            pending.resume(returning: newImage)
            let newEndDeadline = ContinuousClock.now + .seconds(1)
            while !newFinished, ContinuousClock.now < newEndDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(newFinished)
            #expect(preview.image === (next == .cold ? newImage : nil), "live cold results publish; canceled ones do not")
        }
    }

    @Test("releasing a drag preview cancels its pending load")
    func releasingDragPreviewRetiresWork() async throws {
        var preview: ThumbnailDragPreview? = ThumbnailDragPreview()
        weak var weakPreview = preview
        let gate = AsyncSemaphore(value: 0)
        var started = false
        var finished = false
        preview?.show(cached: nil) {
            defer { finished = true }
            _ = await gate.waitConfirmingQueued { started = true }
            return nil
        }
        let startDeadline = ContinuousClock.now + .seconds(1)
        while !started, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
        preview = nil
        let endDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < endDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(weakPreview == nil)
        #expect(finished, "a retired view must not keep a cold render queued")
        await gate.signal()
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while !finished, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished)
    }

}


private extension AsyncSemaphore {
    /// With no available permits, wait() has no suspension before registering
    /// its continuation. This witness needs the same actor executor, so it can
    /// announce only after the request has entered the queue and suspended.
    func waitConfirmingQueued(_ onQueued: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        Task { self.announceQueued(onQueued) }
        return await wait()
    }

    func announceQueued(_ onQueued: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in onQueued() }
    }
}
