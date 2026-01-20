//
//  ThumbnailGridView.swift
//  PageFlow
//
//  Optimized drag-and-drop: visual reordering during drag, commit only on drop.
//  Includes edge-hover autoscroll with distance-based speed ramping, dwell time, and hysteresis.

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Visibility Tracking via PreferenceKey

/// PreferenceKey that collects visible cell indices.
/// This survives SwiftUI view recreation during drag because PreferenceKey
/// values are computed during layout, not during view lifecycle callbacks.
private struct VisibleIndicesPreferenceKey: PreferenceKey {
    static var defaultValue: Set<Int> = []

    static func reduce(value: inout Set<Int>, nextValue: () -> Set<Int>) {
        value.formUnion(nextValue())
    }
}

/// Reports a cell's visibility by writing its index to VisibleIndicesPreferenceKey
/// when the cell's frame intersects the viewport bounds.
private struct VisibilityReporter: View {
    let index: Int
    let viewportHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("thumbnailScrollView"))
            let isVisible = frame.maxY > 0 && frame.minY < viewportHeight

            Color.clear
                .preference(
                    key: VisibleIndicesPreferenceKey.self,
                    value: isVisible ? [index] : []
                )
        }
    }
}

// MARK: - Autoscroll Manager

/// Manages edge-hover autoscroll during thumbnail drag-and-drop.
/// Distance-based speed control with dwell delay and hysteresis.
@MainActor
private final class AutoScrollManager {
    enum EdgeZone { case none, top, bottom }

    // External state
    var viewportHeight: CGFloat = 0
    var pageCount: Int = 0
    var visibleIndices: Set<Int> = []

    // Internal state
    private var activeZone: EdgeZone = .none
    private var cursorY: CGFloat = 0
    private var dwellTimer: Timer?
    private var scrollTimer: Timer?
    private var scrollAction: ((Int, UnitPoint) -> Void)?

    func updateCursor(y: CGFloat, action: @escaping (Int, UnitPoint) -> Void) {
        scrollAction = action
        cursorY = y

        let zone = DesignTokens.autoscrollEdgeZone
        let hysteresis = DesignTokens.autoscrollHysteresis

        // Detect zone
        let detected: EdgeZone
        if y < zone {
            detected = .top
        } else if y > viewportHeight - zone {
            detected = .bottom
        } else {
            detected = .none
        }

        // Apply hysteresis when scrolling
        if scrollTimer != nil && detected == .none {
            let stillNearTop = y < zone + hysteresis && activeZone == .top
            let stillNearBottom = y > viewportHeight - zone - hysteresis && activeZone == .bottom
            if stillNearTop || stillNearBottom { return }
        }

        // Handle zone change
        if detected != activeZone {
            stopScrolling()
            activeZone = detected
            guard detected != .none else { return }

            dwellTimer = Timer(timeInterval: DesignTokens.autoscrollDwellTime, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.startScrolling()
                }
            }
            RunLoop.main.add(dwellTimer!, forMode: .common)
        }
    }

    func stopAll() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopScrolling()
        activeZone = .none
    }

    // MARK: - Private

    private func startScrolling() {
        tick()
        scheduleNextTick()
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func scheduleNextTick() {
        guard activeZone != .none else { return }

        let interval = calculateInterval()
        scrollTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
                self.scheduleNextTick()
            }
        }
        RunLoop.main.add(scrollTimer!, forMode: .common)
    }

    private func calculateInterval() -> TimeInterval {
        guard activeZone != .none else { return DesignTokens.autoscrollMaxInterval }

        // Distance from edge (0 = at edge, edgeZone = at boundary)
        let distance: CGFloat = activeZone == .top ? cursorY : viewportHeight - cursorY

        // Normalize to 0-1 (0 = fastest, 1 = slowest)
        let t = min(max(distance / DesignTokens.autoscrollEdgeZone, 0), 1)

        // Linear interpolation
        return DesignTokens.autoscrollMinInterval + Double(t) * (DesignTokens.autoscrollMaxInterval - DesignTokens.autoscrollMinInterval)
    }

    private func tick() {
        guard let action = scrollAction else { return }

        switch activeZone {
        case .top:
            guard let top = visibleIndices.min(), top > 0 else {
                stopAll()
                return
            }
            action(top - 1, .top)

        case .bottom:
            guard let bottom = visibleIndices.max(), bottom < pageCount - 1 else {
                stopAll()
                return
            }
            action(bottom + 1, .bottom)

        case .none:
            break
        }
    }
}

// MARK: - Thumbnail Grid View

struct ThumbnailGridView: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var bookmarkManager: BookmarkManager
    let isEditing: Bool

    // Drag state - visual only, no PDFDocument changes until drop
    @State private var dragFromIndex: Int?
    @State private var dragToIndex: Int?

    // Custom drag preview (system preview is invisible, we draw our own)
    @State private var dragPreviewImage: NSImage?
    @State private var dragPreviewPosition: CGPoint = .zero

    // Autoscroll
    @State private var autoScrollManager = AutoScrollManager()

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: DesignTokens.spacingSM) {
                        ForEach(Array(0..<pdfManager.pageCount), id: \.self) { index in
                            let displayIndex = visualIndex(for: index)

                            ThumbnailCellView(
                                pdfManager: pdfManager,
                                bookmarkManager: bookmarkManager,
                                pageIndex: displayIndex,
                                displayNumber: index + 1,
                                isEditing: isEditing,
                                isDragging: index == dragToIndex && dragFromIndex != nil
                            )
                            .id("page-\(index)")
                            .background(
                                // PreferenceKey-based visibility tracking survives SwiftUI view recreation
                                VisibilityReporter(index: index, viewportHeight: geo.size.height)
                            )
                            .modifier(DragDropModifier(
                                index: index,
                                isEditing: isEditing,
                                dragFromIndex: $dragFromIndex,
                                dragToIndex: $dragToIndex,
                                onDragStart: { captureDragPreview(pageIndex: index) },
                                onDrop: { commitReorder() },
                                onDragUpdate: { updateDragState(proxy: proxy, geo: geo) },
                                onDragEnd: { clearDragPreview() }
                            ))
                        }
                    }
                    .padding(DesignTokens.thumbnailGridPadding)
                    // NOTE: Removed .animation(.easeInOut(duration: 0.15), value: dragToIndex)
                    // Animation on LazyVStack causes SwiftUI to rebuild view hierarchy when dragToIndex changes,
                    // triggering onDisappear on ALL cells and emptying visibleIndices during drag.
                    // Visual reordering still works via visualIndex(for:) without animation.
                }
                .coordinateSpace(name: "thumbnailScrollView")
                .onPreferenceChange(VisibleIndicesPreferenceKey.self) { indices in
                    autoScrollManager.visibleIndices = indices
                }
                .onAppear {
                    autoScrollManager.viewportHeight = geo.size.height
                    autoScrollManager.pageCount = pdfManager.pageCount
                }
                .onChange(of: geo.size) { _, newSize in
                    autoScrollManager.viewportHeight = newSize.height
                }
            }
            .onChange(of: pdfManager.currentPageIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo("page-\(newIndex)", anchor: .center)
                }
            }
            .onChange(of: pdfManager.pageCount) { _, newCount in
                autoScrollManager.pageCount = newCount
            }
            .onAppear {
                resetDragState()
                proxy.scrollTo("page-\(pdfManager.currentPageIndex)", anchor: .center)
            }
            .onChange(of: isEditing) { _, editing in
                if !editing {
                    resetDragState()
                    clearDragPreview()
                }
            }
            .onChange(of: dragFromIndex) { _, newValue in
                // Clear preview when drag ends (including cancellation)
                if newValue == nil {
                    clearDragPreview()
                }
            }
            // Custom drag preview overlay - disappears instantly on drop
            .overlay {
                if let image = dragPreviewImage {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: DesignTokens.thumbnailWidth, height: DesignTokens.thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.thumbnailCornerRadius))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .position(dragPreviewPosition)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Drag Preview

    private func captureDragPreview(pageIndex: Int) {
        guard let page = pdfManager.page(at: pageIndex) else { return }
        dragPreviewImage = page.thumbnail(
            of: CGSize(width: DesignTokens.thumbnailRenderWidth, height: DesignTokens.thumbnailRenderHeight),
            for: .mediaBox
        )
    }

    private func clearDragPreview() {
        dragPreviewImage = nil
        autoScrollManager.stopAll()
    }

    // MARK: - Drag State Update (preview position + autoscroll)

    private func updateDragState(proxy: ScrollViewProxy, geo: GeometryProxy) {
        guard isEditing, dragFromIndex != nil else {
            autoScrollManager.stopAll()
            return
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }

        let frame = geo.frame(in: .global)
        guard frame.height > 0 else { return }

        // Convert mouse from AppKit (Y up) to SwiftUI (Y down) coordinates
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let cursorY = (window.frame.height - mouseInWindow.y) - frame.minY
        let cursorX = mouseInWindow.x - frame.minX

        // Update custom drag preview position
        dragPreviewPosition = CGPoint(x: cursorX, y: cursorY)

        autoScrollManager.viewportHeight = frame.height
        autoScrollManager.updateCursor(y: cursorY) { targetIndex, anchor in
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                proxy.scrollTo("page-\(targetIndex)", anchor: anchor)
            }
        }
    }

    // MARK: - Visual Reordering (no PDFDocument changes)

    /// Returns the page index to display at position `position` during drag
    private func visualIndex(for position: Int) -> Int {
        guard let from = dragFromIndex, let to = dragToIndex, from != to else {
            return position
        }

        // Dragged item appears at target position
        if position == to {
            return from
        }

        if from < to {
            // Dragging down: positions [from, to) show next page (shift up to fill gap)
            if position >= from && position < to {
                return position + 1
            }
        } else {
            // Dragging up: positions (to, from] show previous page (shift down to fill gap)
            if position > to && position <= from {
                return position - 1
            }
        }

        return position
    }

    /// Commits the reorder to PDFDocument (called only on drop)
    private func commitReorder() {
        guard let from = dragFromIndex, let to = dragToIndex, from != to else {
            resetDragState()
            return
        }

        pdfManager.movePage(from: from, to: to)
        resetDragState()
    }

    private func resetDragState() {
        dragFromIndex = nil
        dragToIndex = nil
    }
}

// MARK: - Drag Drop Modifier

private struct DragDropModifier: ViewModifier {
    let index: Int
    let isEditing: Bool
    @Binding var dragFromIndex: Int?
    @Binding var dragToIndex: Int?
    let onDragStart: () -> Void
    let onDrop: () -> Void
    let onDragUpdate: () -> Void
    let onDragEnd: () -> Void

    func body(content: Content) -> some View {
        if isEditing {
            content
                .onDrag {
                    dragFromIndex = index
                    dragToIndex = index
                    onDragStart()
                    return NSItemProvider(object: String(index) as NSString)
                } preview: {
                    // Invisible system preview - we use our own overlay
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(
                    index: index,
                    dragFromIndex: $dragFromIndex,
                    dragToIndex: $dragToIndex,
                    onDrop: onDrop,
                    onDragUpdate: onDragUpdate,
                    onDragEnd: onDragEnd
                ))
        } else {
            content
        }
    }
}

// MARK: - Drop Delegate

private struct ReorderDropDelegate: DropDelegate {
    let index: Int
    @Binding var dragFromIndex: Int?
    @Binding var dragToIndex: Int?
    let onDrop: () -> Void
    let onDragUpdate: () -> Void
    let onDragEnd: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragFromIndex != nil
    }

    func dropEntered(info: DropInfo) {
        guard dragFromIndex != nil, dragToIndex != index else { return }
        dragToIndex = index
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragFromIndex != nil else { return DropProposal(operation: .cancel) }
        onDragUpdate()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragFromIndex != nil else { return false }
        onDragEnd()
        onDrop()
        return true
    }
}

// MARK: - Thumbnail Cell View

private struct ThumbnailCellView: View {
    let pdfManager: PDFManager
    let bookmarkManager: BookmarkManager
    let pageIndex: Int      // Actual page in PDFDocument
    let displayNumber: Int  // Number shown to user (1-based position)
    let isEditing: Bool
    let isDragging: Bool

    @State private var thumbnailImage: NSImage?
    @State private var refreshID = UUID()

    private var isSelected: Bool { pageIndex == pdfManager.currentPageIndex }
    private var isBookmarked: Bool { bookmarkManager.isBookmarked(pageIndex) }

    var body: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if isBookmarked {
                    bookmarkBadge
                }
                if isEditing {
                    dragHandle
                }
            }
            Text("\(displayNumber)")
                .font(.caption2)
                .foregroundStyle(.white)
        }
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            pdfManager.pushNavigationState()
            pdfManager.goToPage(pageIndex)
        }
        .contextMenu { contextMenu }
        .onAppear { loadThumbnail() }
        .onChange(of: pageIndex) { _, _ in loadThumbnail() }
        .onChange(of: pdfManager.pageVersion) { _, _ in loadThumbnail() }
        .id(refreshID)
    }

    // MARK: - Thumbnail with Caching

    private var thumbnail: some View {
        Group {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.gray.opacity(0.1)
            }
        }
        .frame(width: DesignTokens.thumbnailWidth, height: DesignTokens.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.thumbnailCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.thumbnailCornerRadius)
                .strokeBorder(isSelected ? Color(white: 0.3) : .clear, lineWidth: DesignTokens.thumbnailBorderWidth)
        )
    }

    private func loadThumbnail() {
        guard let page = pdfManager.page(at: pageIndex) else {
            thumbnailImage = nil
            return
        }
        thumbnailImage = page.thumbnail(
            of: CGSize(width: DesignTokens.thumbnailRenderWidth, height: DesignTokens.thumbnailRenderHeight),
            for: .mediaBox
        )
    }

    private var bookmarkBadge: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: DesignTokens.thumbnailBadgeFontSize))
            .foregroundStyle(.black)
            .padding(DesignTokens.spacingXS)
    }

    private var dragHandle: some View {
        VStack {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
            Spacer()
        }
        .padding(4)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        if isEditing {
            Button { pdfManager.copyPage(at: pageIndex) } label: {
                Label("Copy Page", systemImage: "doc.on.doc")
            }
            Button { _ = pdfManager.pastePage(after: pageIndex) } label: {
                Label("Paste Page", systemImage: "doc.on.clipboard")
            }
            .disabled(!pdfManager.canPaste)
            Divider()
            Button { rotatePage(clockwise: true) } label: {
                Label("Rotate Clockwise", systemImage: "rotate.right")
            }
            Button { rotatePage(clockwise: false) } label: {
                Label("Rotate Counter-Clockwise", systemImage: "rotate.left")
            }
            Divider()
            Button { pdfManager.duplicatePage(at: pageIndex) } label: {
                Label("Duplicate Page", systemImage: "doc.badge.plus")
            }
            Divider()
            Button(role: .destructive) { pdfManager.deletePage(at: pageIndex) } label: {
                Label("Delete Page", systemImage: "trash")
            }
            .disabled(pdfManager.pageCount <= 1)
            Divider()
        }

        Button { copyPageAsMarkdown() } label: {
            Label("Copy Page as Markdown", systemImage: "doc.text")
        }
        Divider()
        Button { bookmarkManager.toggleBookmark(at: pageIndex) } label: {
            Label(isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                  systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
        }
    }

    private func rotatePage(clockwise: Bool) {
        pdfManager.rotatePage(at: pageIndex, clockwise: clockwise)
    }

    private func copyPageAsMarkdown() {
        guard let document = pdfManager.document else { return }
        let markdown = MarkdownExporter.export(scope: .currentPage(pageIndex), document: document)
        MarkdownExporter.copyToClipboard(markdown)
    }
}
