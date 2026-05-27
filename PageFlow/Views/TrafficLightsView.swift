//
//  TrafficLightsView.swift
//  PageFlow
//
//  Custom AppKit traffic-light controls inside PageFlow's shared glass capsule.
//

import SwiftUI
import AppKit

struct TrafficLightsView: View {
    var body: some View {
        TrafficLightsRepresentable()
            .frame(
                width: TrafficLightsAppKitView.intrinsicWidth,
                height: TrafficLightsAppKitView.intrinsicHeight
            )
            .pageFlowLiquidGlassPanel(
                cornerRadius: TrafficLightsAppKitView.cornerRadius,
                tint: .light,
                tintOpacity: TrafficLightsAppKitView.glassTintOpacity,
                variant: .clear,
                strokeOpacity: TrafficLightsAppKitView.glassStrokeOpacity,
                shadowRadius: 4,
                shadowY: -2
            )
    }
}

private struct TrafficLightsRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TrafficLightsAppKitView {
        let view = TrafficLightsAppKitView()
        view.onClose = { [weak view] in view?.window?.performClose(nil) }
        view.onMinimize = { [weak view] in view?.window?.performMiniaturize(nil) }
        view.onZoom = { [weak view] in view?.window?.toggleFullScreen(nil) }
        return view
    }

    func updateNSView(_ nsView: TrafficLightsAppKitView, context: Context) {}
}

// MARK: - AppKit implementation

/// Three custom NSControl circles inside the shared chrome glass capsule.
final class TrafficLightsAppKitView: NSView {

    // MARK: Layout constants (mirror md-preview)

    static let buttonDiameter: CGFloat = DesignTokens.trafficLightSize          // 12
    static let buttonSpacing: CGFloat = DesignTokens.trafficLightSpacing        // 8
    static let containerPadding: CGFloat = DesignTokens.trafficLightContainerPadding // 8
    static let cornerRadius: CGFloat = DesignTokens.floatingToolbarCornerRadius // 14
    static let glassTintOpacity: CGFloat = 0.14
    static let glassStrokeOpacity: CGFloat = 0.22

    static var intrinsicWidth: CGFloat {
        // 3 buttons + 2 spacers + 2 paddings
        buttonDiameter * 3 + buttonSpacing * 2 + containerPadding * 2
    }

    static var intrinsicHeight: CGFloat {
        buttonDiameter + containerPadding * 2
    }

    // MARK: Callbacks

    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.intrinsicWidth, height: Self.intrinsicHeight)
    }

    // Only the explicit drag strip moves the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Buttons

    private func buildButtons() {
        let close = TrafficLightButton(color: .systemRed) { [weak self] in self?.onClose?() }
        let mini = TrafficLightButton(color: .systemYellow) { [weak self] in self?.onMinimize?() }
        let zoom = TrafficLightButton(color: .systemGreen) { [weak self] in self?.onZoom?() }

        let stack = NSStackView(views: [close, mini, zoom])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = Self.buttonSpacing
        stack.alignment = .centerY
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.containerPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.containerPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.containerPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.containerPadding)
        ])
    }
}

// MARK: - TrafficLightButton

private final class TrafficLightButton: NSControl {
    private let onClick: () -> Void

    init(color: NSColor, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = TrafficLightsAppKitView.buttonDiameter / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TrafficLightsAppKitView.buttonDiameter),
            heightAnchor.constraint(equalToConstant: TrafficLightsAppKitView.buttonDiameter)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Fire on mouseDown (md-preview pattern): the 12pt circle is small enough
    // that requiring mouseUp inside causes spurious misses if the cursor drifts.
    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
