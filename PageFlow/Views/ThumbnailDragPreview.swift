import AppKit
import Observation

/// Owns the custom drag image and its asynchronous cold-cache load.
@MainActor
@Observable
final class ThumbnailDragPreview {
    private(set) var image: NSImage?
    @ObservationIgnored private var pending: Task<Void, Never>?

    deinit {
        pending?.cancel()
    }

    func show(cached: NSImage?, render: @escaping @MainActor () async -> NSImage?) {
        clear()
        if let cached {
            image = cached
            return
        }
        pending = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let rendered = await render()
            // A previous drag can finish after its replacement, even when
            // the rasterizer cannot stop midway through drawing the page.
            guard !Task.isCancelled else { return }
            self?.image = rendered
            self?.pending = nil
        }
    }

    func clear() {
        pending?.cancel()
        pending = nil
        image = nil
    }
}
