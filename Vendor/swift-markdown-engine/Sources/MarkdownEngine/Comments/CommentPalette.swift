import AppKit

/// the reference editor's comment tokens (doc 25 §8), light and dark.
enum CommentPalette {
    private static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// The highlight gold, #fab219; at rest 20 %, lit 45 % (the same in dark).
    static let gold = color(0xFAB219)
    static let restAlpha: CGFloat = 0.20
    static let activeAlpha: CGFloat = 0.45
    /// The open thread's 2 pt underline.
    static let openLine = dynamic(light: color(0xA66A00), dark: color(0xFAB219))
    /// The table being commented on, while the composer is open.
    static let composingTarget = color(0xA66A00)
    /// A commented table's 2 pt outline.
    static let tableOutline = dynamic(light: color(0xB77700), dark: color(0xDB9300))
    /// Resolved threads, when the list shows them: #7b7974 at 18 % (lit 32 %).
    static let resolved = color(0x7B7974)
    static let resolvedRestAlpha: CGFloat = 0.18
    static let resolvedActiveAlpha: CGFloat = 0.32

    /// Cards and the composer (`surface-2`), the list panel, popovers.
    static let card = dynamic(light: color(0xFFFFFF), dark: color(0x1A1A19))
    static let popover = dynamic(light: color(0xFFFFFF), dark: color(0x20201F))
    static let text = dynamic(light: color(0x0B0B0B), dark: color(0xF0EFEC))
    static let secondaryText = dynamic(light: color(0x52514E), dark: color(0xC3C2B7))
    static let mutedText = color(0x898781)
    static let alpha1 = dynamic(light: color(0x0B0B0B, 0.05), dark: color(0xFFFFFF, 0.05))
    static let alpha2 = dynamic(light: color(0x0B0B0B, 0.10), dark: color(0xFFFFFF, 0.10))
    static let alpha3 = dynamic(light: color(0x0B0B0B, 0.20), dark: color(0xFFFFFF, 0.20))
    static let accent = color(0x2A78D6)
    static let accentText = dynamic(light: color(0x184F95), dark: color(0x6DA7EC))
    /// My reaction pill: accent border and a 10 % accent fill.
    static let accentBorder = dynamic(light: color(0x86B6EF), dark: color(0x0D366B))
    static let accentMuted = color(0x2A78D6, 0.10)
    static let dangerFill = color(0xD03B3B)
    static let dangerText = dynamic(light: color(0x8E2626), dark: color(0xEC7E7E))
    /// The focus ring's glow.
    static let focusGlow = color(0xCDE2FB)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Motion (doc 25 §8.4)

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1)
    static let snap = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let overshoot = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1)
    static let exit = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 1)

    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || skipsMotion }
    /// Tests finish every animation at once.
    nonisolated(unsafe) static var skipsMotion = false

    // MARK: - Type (doc 25 §8.2)

    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyLineHeight: CGFloat = 19
    /// Centres 13 pt glyphs in a 19 pt line, as CSS half-leading does.
    static let bodyBaselineOffset: CGFloat = ((19 - (body.ascender - body.descender)) / 2).rounded()
    static let footnote = NSFont.systemFont(ofSize: 12)
    static let caption = NSFont.systemFont(ofSize: 11)
}
