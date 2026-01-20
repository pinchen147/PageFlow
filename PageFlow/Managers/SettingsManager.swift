//
//  SettingsManager.swift
//  PageFlow
//
//  Centralized settings state with UserDefaults persistence
//

import Foundation
import AppKit
import Observation
import os.log

@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()
    private let logger = Logger(subsystem: "com.pageflow", category: "SettingsManager")

    // MARK: - Color Preset Model

    struct ColorPreset: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var hex: String

        init(id: UUID = UUID(), name: String, hex: String) {
            self.id = id
            self.name = name
            self.hex = hex
        }

        var color: NSColor {
            get { Self.hexToColor(hex) ?? .black }
            set { hex = Self.colorToHex(newValue) }
        }

        private static func hexToColor(_ hex: String) -> NSColor? {
            var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

            var rgba: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgba)

            // Support both #RRGGBB (6 chars) and #RRGGBBAA (8 chars)
            // Use sRGB color space for consistency with DesignTokens
            if hexSanitized.count == 6 {
                return NSColor(
                    srgbRed: CGFloat((rgba & 0xFF0000) >> 16) / 255.0,
                    green: CGFloat((rgba & 0x00FF00) >> 8) / 255.0,
                    blue: CGFloat(rgba & 0x0000FF) / 255.0,
                    alpha: 1.0
                )
            } else if hexSanitized.count == 8 {
                return NSColor(
                    srgbRed: CGFloat((rgba & 0xFF000000) >> 24) / 255.0,
                    green: CGFloat((rgba & 0x00FF0000) >> 16) / 255.0,
                    blue: CGFloat((rgba & 0x0000FF00) >> 8) / 255.0,
                    alpha: CGFloat(rgba & 0x000000FF) / 255.0
                )
            }
            return nil
        }

        private static func colorToHex(_ color: NSColor) -> String {
            guard let rgbColor = color.usingColorSpace(.sRGB) else {
                return "#000000FF"
            }
            let r = Int(rgbColor.redComponent * 255)
            let g = Int(rgbColor.greenComponent * 255)
            let b = Int(rgbColor.blueComponent * 255)
            let a = Int(rgbColor.alphaComponent * 255)
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let highlightPresets = "settings.highlightPresets"
        static let underlinePresets = "settings.underlinePresets"
        static let commentPresets = "settings.commentPresets"
        static let customShortcuts = "settings.customShortcuts"
    }

    // MARK: - Default Presets

    static let defaultHighlightPresets: [ColorPreset] = [
        ColorPreset(name: "Yellow", hex: "#FFFF00"),
        ColorPreset(name: "Green", hex: "#00B342"),
        ColorPreset(name: "Red", hex: "#D20000"),
        ColorPreset(name: "Blue", hex: "#0072C6")
    ]

    static let defaultUnderlinePresets: [ColorPreset] = [
        ColorPreset(name: "Black", hex: "#000000"),
        ColorPreset(name: "Yellow", hex: "#FFFF00"),
        ColorPreset(name: "Green", hex: "#00B342"),
        ColorPreset(name: "Red", hex: "#D20000"),
        ColorPreset(name: "Blue", hex: "#0072C6")
    ]

    static let defaultCommentPresets: [ColorPreset] = [
        ColorPreset(name: "Gray", hex: "#80808099")  // 99 hex = 153 = 0.6 alpha
    ]

    // MARK: - Properties

    private let defaults = UserDefaults.standard
    private var isLoading = false

    var highlightPresets: [ColorPreset] = defaultHighlightPresets {
        didSet { if !isLoading { savePresets(highlightPresets, forKey: Keys.highlightPresets) } }
    }

    var underlinePresets: [ColorPreset] = defaultUnderlinePresets {
        didSet { if !isLoading { savePresets(underlinePresets, forKey: Keys.underlinePresets) } }
    }

    var commentPresets: [ColorPreset] = defaultCommentPresets {
        didSet { if !isLoading { savePresets(commentPresets, forKey: Keys.commentPresets) } }
    }

    var customShortcuts: [String: ShortcutModel] = [:] {
        didSet { if !isLoading { saveShortcuts() } }
    }

    // MARK: - Init

    private init() {
        isLoading = true
        loadSettings()
        isLoading = false
    }

    // MARK: - Add/Remove Presets

    func addHighlightPreset() {
        highlightPresets.append(ColorPreset(name: "New", hex: "#FFFF00"))
    }

    func removeHighlightPreset(at index: Int) {
        guard highlightPresets.count > 1, highlightPresets.indices.contains(index) else { return }
        highlightPresets.remove(at: index)
    }

    func addUnderlinePreset() {
        underlinePresets.append(ColorPreset(name: "New", hex: "#000000"))
    }

    func removeUnderlinePreset(at index: Int) {
        guard underlinePresets.count > 1, underlinePresets.indices.contains(index) else { return }
        underlinePresets.remove(at: index)
    }

    func addCommentPreset() {
        commentPresets.append(ColorPreset(name: "New", hex: "#80808099"))
    }

    func removeCommentPreset(at index: Int) {
        guard commentPresets.count > 1, commentPresets.indices.contains(index) else { return }
        commentPresets.remove(at: index)
    }

    // MARK: - Reset

    func resetColors() {
        highlightPresets = Self.defaultHighlightPresets
        underlinePresets = Self.defaultUnderlinePresets
        commentPresets = Self.defaultCommentPresets
    }

    func resetShortcuts() {
        customShortcuts = [:]
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let data = defaults.data(forKey: Keys.highlightPresets) {
            do {
                highlightPresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode highlight presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.underlinePresets) {
            do {
                underlinePresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode underline presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.commentPresets) {
            do {
                commentPresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode comment presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.customShortcuts) {
            do {
                customShortcuts = try JSONDecoder().decode([String: ShortcutModel].self, from: data)
            } catch {
                logger.error("Failed to decode custom shortcuts: \(error.localizedDescription)")
            }
        }
    }

    private func savePresets(_ presets: [ColorPreset], forKey key: String) {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode presets for \(key): \(error.localizedDescription)")
        }
    }

    private func saveShortcuts() {
        do {
            let data = try JSONEncoder().encode(customShortcuts)
            defaults.set(data, forKey: Keys.customShortcuts)
        } catch {
            logger.error("Failed to encode shortcuts: \(error.localizedDescription)")
        }
    }
}
