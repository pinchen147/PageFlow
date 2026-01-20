//
//  ColorWellView.swift
//  PageFlow
//
//  NSColorWell wrapper for SwiftUI that opens NSColorPanel with hex input
//

import SwiftUI
import AppKit

struct ColorWellView: NSViewRepresentable {
    @Binding var color: NSColor

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = color
        well.supportsAlpha = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))

        // Install hex input accessory view on first use
        HexAccessoryManager.shared.install()

        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        well.color = color
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    class Coordinator: NSObject {
        @Binding var color: NSColor

        init(color: Binding<NSColor>) {
            _color = color
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            color = sender.color
        }
    }
}

// MARK: - Hex Accessory Manager

/// Singleton that manages the hex input accessory view for NSColorPanel
final class HexAccessoryManager {
    static let shared = HexAccessoryManager()

    private var isInstalled = false
    private var accessoryView: HexAccessoryView?

    private init() {}

    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let accessory = HexAccessoryView()
        accessoryView = accessory

        let panel = NSColorPanel.shared
        panel.accessoryView = accessory
        panel.showsAlpha = true
    }
}

// MARK: - Hex Accessory View

/// Custom accessory view with hex input field for NSColorPanel
final class HexAccessoryView: NSView, NSTextFieldDelegate {
    private let hexField: NSTextField
    private let label: NSTextField
    private var isUpdatingFromPanel = false
    private var escapeMonitor: Any?

    override init(frame: NSRect) {
        // Create label
        label = NSTextField(labelWithString: "Hex:")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        // Create hex input field
        hexField = NSTextField()
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.placeholderString = "#RRGGBB"
        hexField.alignment = .center
        hexField.bezelStyle = .roundedBezel

        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))

        hexField.delegate = self

        // Layout
        addSubview(label)
        addSubview(hexField)

        label.translatesAutoresizingMaskIntoConstraints = false
        hexField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            hexField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            hexField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hexField.centerYAnchor.constraint(equalTo: centerYAnchor),
            hexField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])

        // Observe color panel changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(colorPanelColorChanged),
            name: NSColorPanel.colorDidChangeNotification,
            object: NSColorPanel.shared
        )

        // Monitor Escape key to close color panel
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // 53 = Escape
            guard NSColorPanel.shared.isVisible else { return event }
            NSColorPanel.shared.close()
            return nil
        }

        // Initialize with current color
        updateHexField(from: NSColorPanel.shared.color)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    @objc private func colorPanelColorChanged(_ notification: Notification) {
        guard !isUpdatingFromPanel else { return }
        updateHexField(from: NSColorPanel.shared.color)
    }

    private func updateHexField(from color: NSColor) {
        isUpdatingFromPanel = true
        hexField.stringValue = colorToHex(color)
        isUpdatingFromPanel = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        applyHexColor()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            applyHexColor()
            return true
        }
        return false
    }

    private func applyHexColor() {
        let hex = hexField.stringValue
        if let color = hexToColor(hex) {
            isUpdatingFromPanel = true
            NSColorPanel.shared.color = color
            isUpdatingFromPanel = false
        } else {
            // Revert to current color if invalid
            updateHexField(from: NSColorPanel.shared.color)
        }
    }

    // MARK: - Hex Conversion

    private func colorToHex(_ nsColor: NSColor) -> String {
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        let a = Int(rgbColor.alphaComponent * 255)
        if a == 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    private func hexToColor(_ hex: String) -> NSColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgba: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgba) else { return nil }

        if hexSanitized.count == 6 {
            return NSColor(
                red: CGFloat((rgba & 0xFF0000) >> 16) / 255.0,
                green: CGFloat((rgba & 0x00FF00) >> 8) / 255.0,
                blue: CGFloat(rgba & 0x0000FF) / 255.0,
                alpha: 1.0
            )
        } else if hexSanitized.count == 8 {
            return NSColor(
                red: CGFloat((rgba & 0xFF000000) >> 24) / 255.0,
                green: CGFloat((rgba & 0x00FF0000) >> 16) / 255.0,
                blue: CGFloat((rgba & 0x0000FF00) >> 8) / 255.0,
                alpha: CGFloat(rgba & 0x000000FF) / 255.0
            )
        }
        return nil
    }
}
