import Foundation

/// Prepared when the canonical parser publishes a snapshot, never from pointer events.
final class BlockDragIndexCache {
    struct Revision: Equatable {
        let source: Int
        let document: Int
    }

    private var ready: (revision: Revision, blocks: [Block])?
    private(set) var task: Task<Void, Never>?
    private var request = 0

    func blocks(for revision: Revision) -> [Block]? {
        ready?.revision == revision ? ready?.blocks : nil
    }

    func cancel() {
        request &+= 1
        task?.cancel()
        task = nil
        ready = nil
    }

    deinit { task?.cancel() }

    func prepare(
        snapshot: BlockParser.Snapshot,
        revision: Revision,
        isCurrent: @escaping () -> Bool,
        onReady: @escaping () -> Void
    ) {
        cancel()
        let request = request
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> [Block]? in
                guard !Task.isCancelled else { return nil }
                let source = String(decoding: snapshot.characters, as: UTF16.self)
                let blocks = BlockDragIndex.grouped(snapshot.blocks, in: source as NSString)
                guard !Task.isCancelled else { return nil }
                return blocks
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.request == request, !Task.isCancelled else { return }
            self.task = nil
            guard let blocks = result, isCurrent() else { return }
            self.ready = (revision, blocks)
            onReady()
        }
    }
}
