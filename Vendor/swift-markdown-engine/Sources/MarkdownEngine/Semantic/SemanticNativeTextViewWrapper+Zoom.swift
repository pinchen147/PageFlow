import AppKit

extension SemanticNativeTextViewWrapper {
    func projectZoom(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard !coordinator.isProjectingZoom, let range = options.magnificationRange else { return }
        coordinator.isProjectingZoom = true
        defer { coordinator.isProjectingZoom = false }
        scroll.allowsMagnification = true
        scroll.maxMagnification = range.upperBound
        (scroll as? ClampedScrollView)?.onUserMagnificationBegan = { [weak coordinator, weak scroll] _ in
            coordinator?.userLeftWidthFit = true
            scroll?.minMagnification = range.lowerBound
            return true
        }
        (scroll as? ClampedScrollView)?.onMagnificationChanged = { [weak coordinator] value in
            coordinator?.lastHostMagnification = value
            coordinator?.userLeftWidthFit = true
            options.onMagnificationChanged?(value)
        }
        let request = options.zoomRequest
        let freshRequest = request.map { $0.token != coordinator.appliedZoomToken } ?? false
        if freshRequest { coordinator.userLeftWidthFit = false }
        let fit = (freshRequest ? request?.action == .fitWidth : options.isWidthFitted)
            && !coordinator.userLeftWidthFit
        if fit {
            guard scroll.contentView.frame.width > 0 else { return }
            let measure = options.configuration.readingWidth ?? max(1, scroll.contentView.frame.width - options.configuration.horizontalLayoutInset * 2)
            let lane = coordinator.owner?.textView.comments_commentLaneReserve ?? 0
            let row = measure + options.configuration.horizontalLayoutInset * 2 + lane
            let scale = min(range.upperBound, max(0.01, scroll.contentView.frame.width / max(1, row)))
            if freshRequest || coordinator.lastFittedMagnification != scale {
                let position = coordinator.host?.readingPosition()
                scroll.minMagnification = min(range.lowerBound, scale)
                if abs(scroll.magnification - scale) > 0.001 {
                    scroll.setMagnification(scale, centeredAt: NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.minY))
                    if let position { _ = coordinator.host?.restore(position) }
                }
            }
            if freshRequest { coordinator.appliedZoomToken = request?.token }
            if freshRequest || coordinator.lastFittedMagnification != scale {
                coordinator.lastFittedMagnification = scale
                coordinator.lastHostMagnification = scale
                options.onFittedMagnificationChanged?(scale)
            }
        } else {
            scroll.minMagnification = range.lowerBound
            let requested = freshRequest && request?.action == .actualSize ? 1 : options.magnification
            if let requested {
                let scale = min(range.upperBound, max(range.lowerBound, requested))
                if freshRequest || coordinator.lastHostMagnification != scale {
                    coordinator.lastHostMagnification = scale
                    if abs(scroll.magnification - scale) > 0.001 {
                        scroll.setMagnification(scale, centeredAt: NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
                    }
                }
            }
            if freshRequest {
                coordinator.appliedZoomToken = request?.token
                options.onMagnificationChanged?(scroll.magnification)
            }
        }
    }
}
