import AppKit

extension NativeTextViewCoordinator {
    func receiveZoomIntent(isWidthFitted fitted: Bool, request: MarkdownZoomRequest?,
                           documentId: String, range: ClosedRange<CGFloat>?,
                           onFitted: ((CGFloat) -> Void)?, scrollView: ClampedScrollView) {
        guard self.documentId == documentId, let range else { return }
        if zoomIntentDocumentId != documentId {
            zoomIntentDocumentId = documentId
            pendingZoomRequest = nil
            lastReceivedWidthFitted = nil
            lastWidthFitGeometry = nil
        }
        if zoomIntentGeneration != documentGeneration {
            zoomIntentGeneration = documentGeneration
            consumedZoomRequestTokens.removeAll()
            pendingZoomRequest = nil
        }
        zoomIntentRange = range
        fittedMagnificationCallback = onFitted
        // A removed request plus manual intent retires protected-input debt,
        // including same-value commands. A newer request suppresses the older
        // user-end receipt before the host could send this cancellation signal.
        if !fitted, request == nil { supersedePendingZoom() }
        if let request, !consumedZoomRequestTokens.contains(request.token) {
            pendingZoomRequest = request
        }
        // Only a changed host intent can reactivate Fit after a user event.
        // An unchanged true prop during a pinch is an outgoing render echo.
        if lastReceivedWidthFitted != fitted {
            lastReceivedWidthFitted = fitted
            if fitted { isWidthFitted = true; lastWidthFitGeometry = nil }
            else if pendingZoomRequest == nil { leaveWidthFit(scrollView: scrollView) }
        }
        scrollView.onUserMagnificationBegan = { [weak self, weak scrollView] anchor in
            guard let self, let scrollView else { return false }
            let leftFit = self.isWidthFitted
            // A new gesture supersedes older queued commands; continuation
            // frames do not enter this callback and preserve newer requests.
            self.supersedePendingZoom()
            self.leaveWidthFit(scrollView: scrollView, anchor: anchor)
            return leftFit
        }
        scheduleWidthFit()
    }

    func supersedePendingZoom() {
        if let pendingZoomRequest { consumedZoomRequestTokens.insert(pendingZoomRequest.token) }
        pendingZoomRequest = nil
    }

    func leaveWidthFit(scrollView: ClampedScrollView, anchor: NSPoint? = nil) {
        guard isWidthFitted else { return }
        isWidthFitted = false
        lastWidthFitGeometry = nil
        guard let range = zoomIntentRange else { return }
        // A fitted scale may lie below the ordinary manual range. Re-enter it
        // through native anchored magnification before accepting manual input.
        if scrollView.magnification < range.lowerBound {
            let clip = scrollView.contentView
            scrollView.setMagnification(range.lowerBound, centeredAt: anchor ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY))
        }
        scrollView.minMagnification = range.lowerBound
    }

    /// Coalesce real frame/configuration changes after their existing owners run.
    /// Hidden, protected-input and live-gesture debt resumes through those same
    /// lifecycle owners; no per-frame layout or polling is introduced.
    func scheduleWidthFit() {
        guard isWidthFitted || pendingZoomRequest != nil, widthFitWorkItem == nil,
              let text = textView as? NativeTextView,
              text.enclosingScrollView?.isHidden == false else { return }
        let generation = documentGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.widthFitWorkItem = nil
            guard generation == self.documentGeneration else { return }
            self.applyPendingZoom()
        }
        widthFitWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyPendingZoom() {
        guard !isApplyingWidthFit, didInitialFormatting,
              let text = textView as? NativeTextView,
              let scroll = text.enclosingScrollView as? ClampedScrollView,
              scroll.window != nil, !scroll.isHidden, scroll.contentView.frame.height > 1,
              !isComposing(in: text), !isWritingToolsActive, !scroll.isZoomInProgress,
              zoomIntentDocumentId == documentId,
              let range = zoomIntentRange else { return }
        // Protected-input completion can replace source and advance the
        // generation without another representable update before this retry.
        if zoomIntentGeneration != documentGeneration {
            zoomIntentGeneration = documentGeneration
            consumedZoomRequestTokens.removeAll()
        }
        let request = pendingZoomRequest
        let fitting = request.map { $0.action == .fitWidth } ?? isWidthFitted
        guard fitting || request?.action == .actualSize else { return }
        let width = scroll.contentView.frame.width
        guard let row = text.unscaledReadingRowWidth, width.isFinite, width > 0 else { return }
        let geometry = CGSize(width: width, height: row)
        if fitting, request == nil, lastWidthFitGeometry == geometry { return }
        let target = fitting ? min(width / row, range.upperBound) : 1
        guard target.isFinite, target > 0 else { return }
        isApplyingWidthFit = true
        defer { isApplyingWidthFit = false }
        pendingZoomRequest = nil
        if let request {
            consumedZoomRequestTokens.insert(request.token)
        }
        isWidthFitted = fitting
        let witness = text.readingPosition()
        let clip = scroll.contentView
        scroll.minMagnification = min(range.lowerBound, target)
        scroll.maxMagnification = range.upperBound
        scroll.noteMagnificationChanged()
        scroll.setMagnification(target, centeredAt: NSPoint(x: clip.bounds.midX, y: clip.bounds.midY))
        scroll.settleClipScale()
        if fitting {
            // Placement uses the actual row frame after the native outer
            // transaction finalized column and parent extent. AppKit constrains
            // the requested interval for short notes and document boundaries.
            let rowRect = text.convert(CGRect(x: text.bounds.minX, y: 0, width: row, height: 1), to: clip)
            var legal = clip.bounds
            legal.origin.x = min(max(legal.minX, rowRect.maxX - legal.width), rowRect.minX)
            legal = clip.constrainBoundsRect(legal)
            clip.scroll(to: legal.origin)
            scroll.reflectScrolledClipView(clip)
        }
        lastWidthFitGeometry = fitting ? geometry : nil
        if pendingReadingPositionRequest != nil {
            applyPendingReadingPosition(scrollView: scroll, textView: text)
        } else if let witness {
            text.restore(witness)
        }
        // The source witness can request an impossible Y near the document end
        // after zoom-out enlarges the viewport. Native legal bounds win there.
        let constrained = clip.constrainBoundsRect(clip.bounds)
        if abs(constrained.minX - clip.bounds.minX) > 0.001
            || abs(constrained.minY - clip.bounds.minY) > 0.001 {
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
        }
        text.magnificationDidSettle()
        lastReadingPosition = text.readingPosition() ?? witness ?? lastReadingPosition
        // This work already runs outside representable updates. Adopt before
        // notifying the host so its measured scalar cannot echo a stale target.
        lastHostMagnification = scroll.magnification
        if fitting { fittedMagnificationCallback?(scroll.magnification) }
    }
}
