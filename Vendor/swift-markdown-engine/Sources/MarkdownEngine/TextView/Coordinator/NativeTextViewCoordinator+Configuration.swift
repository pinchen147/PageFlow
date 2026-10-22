import AppKit

extension NativeTextViewCoordinator {
    func applyPendingEditability(to textView: NSTextView) {
        guard !isComposing(in: textView), !isWritingToolsActive,
              let editable = pendingIsEditable else { return }
        pendingIsEditable = nil
        textView.isEditable = editable
        textView.isSelectable = true
        textView.insertionPointColor = editable ? configuration.theme.bodyText : .clear
    }

    func applyLayoutConfiguration(to textView: NativeTextView) {
        guard !isComposing(in: textView), !isWritingToolsActive,
              let scrollView = textView.enclosingScrollView,
              let container = textView.textContainer else { return }
        let old = textView.configuration
        let readingWidthChanged = old.readingWidth != configuration.readingWidth
        let insetsChanged = old.textInsets != configuration.textInsets
            || old.horizontalLayoutInset != configuration.horizontalLayoutInset
        let centeringChanged = old.centersZoomedOutColumn != configuration.centersZoomedOutColumn
        textView.configuration = configuration
        textView.baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let desiredAppearance = forcedAppearanceName.flatMap { NSAppearance(named: $0) }
        if scrollView.appearance?.name != desiredAppearance?.name { scrollView.appearance = desiredAppearance }
        let scrollers = configuration.scrollers
        if scrollView.hasVerticalScroller != scrollers.hasVerticalScroller { scrollView.hasVerticalScroller = scrollers.hasVerticalScroller }
        if scrollView.hasHorizontalScroller != scrollers.hasHorizontalScroller { scrollView.hasHorizontalScroller = scrollers.hasHorizontalScroller }
        if scrollView.autohidesScrollers != scrollers.autohidesScrollers { scrollView.autohidesScrollers = scrollers.autohidesScrollers }
        let insets = configuration.safeAreaInsets
        let desiredInsets = NSEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        if scrollView.contentInsets.top != desiredInsets.top || scrollView.contentInsets.left != desiredInsets.left
            || scrollView.contentInsets.bottom != desiredInsets.bottom || scrollView.contentInsets.right != desiredInsets.right {
            scrollView.contentInsets = desiredInsets
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
        let desiredTextInset = NSSize(width: textView.zoomAdjustedInsetWidth(base: configuration.horizontalLayoutInset),
                                     height: configuration.textInsets.vertical)
        if textView.textContainerInset != desiredTextInset { textView.textContainerInset = desiredTextInset }
        if readingWidthChanged {
            if let width = configuration.readingWidth {
                container.widthTracksTextView = false
                container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            } else {
                container.widthTracksTextView = true
                textView.setFrameOrigin(NSPoint(x: 0, y: textView.frame.origin.y))
            }
            textView.applyManagedFrameSize(width: scrollView.contentView.bounds.width)
            textView.centerReadingColumn(forClipWidth: scrollView.contentView.bounds.width)
        }
        if insetsChanged || readingWidthChanged {
            textView.applyZoomWrapPinning()
            let generation = documentGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, generation == self.documentGeneration,
                      !self.isComposing(in: textView), !self.isWritingToolsActive else { return }
                textView.containerWidthDidChange()
            }
        }
        if centeringChanged {
            textView.applyZoomContainerGeometry()
            textView.updateWideTableOverlays()
        }
    }
}
