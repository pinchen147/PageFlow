import AppKit

/// the reference editor's chrome colors (doc 24 §6.13), light and dark.
enum ChromePalette {
    private static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let surface = dynamic(light: color(0xFFFFFF), dark: color(0x20201F))
    static let border = dynamic(light: color(0x0B0B0B, 0.10), dark: color(0xFFFFFF, 0.10))
    static let text = dynamic(light: color(0x0B0B0B), dark: color(0xF0EFEC))
    static let secondaryText = dynamic(light: color(0x52514E), dark: color(0xC3C2B7))
    static let hover = dynamic(light: color(0x0B0B0B, 0.05), dark: color(0xFFFFFF, 0.075))
    static let current = dynamic(light: color(0x0B0B0B, 0.10), dark: color(0xFFFFFF, 0.15))
    static let pressedFill = dynamic(light: color(0xCDE2FB), dark: color(0x032042))
    static let pressedIcon = dynamic(light: color(0x184F95), dark: color(0x6DA7EC))
    static let tooltipFill = dynamic(light: color(0x0B0B0B), dark: color(0x20201F))
    static let tooltipText = dynamic(light: color(0xFFFFFF), dark: color(0xF0EFEC))
    static let accent = color(0x2A78D6)
    static let selectionBackground = pressedFill
    static let selectionText = pressedIcon
    /// The text selection while the bar has keyboard focus: accent at 28 %.
    static let focusedBarSelection = dynamic(light: color(0xC3D9F4), dark: color(0x142A44))
    /// the reference editor's highlight mark: #fab219 at 33 % over the page.
    static let highlight = dynamic(light: color(0xFDE6B3), dark: color(0x5A4210))

    /// Shadow of the bar and its menus: 0 4 8 ink .08 and 0 12 28 −2 black .24 (dark) / ink .08 (light).
    static func applyBarShadow(to layer: CALayer, dark: Bool) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.24 : 0.08
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -12)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
