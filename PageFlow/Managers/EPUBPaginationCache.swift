//
//  EPUBPaginationCache.swift
//  PageFlow
//
//  Whole-book page breaks saved per book and text settings, so a reopened
//  book has its exact page count at once instead of re-paginating in view.
//

import CryptoKit
import Foundation

nonisolated enum EPUBPaginationCache {
    /// Bump when the paginator or the renderer moves page breaks.
    /// 4: chapters outside the reading flow are saved without pages.
    /// 5: real tables, formulas and hidden footnotes move page breaks.
    /// 6: ruby readings draw over their bases and vertical chapters lay out in columns.
    /// 7: a fixed-layout chapter is one page.
    /// 8: the text after a table clears its border.
    /// 9: only a letter's shape and size in text takes the line's height; a size in ems stays on the page.
    private static let version = 9
    /// Saved books kept; the least recently written go first.
    private static let fileLimit = 300

    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EPUBPagination", isDirectory: true)

    /// Everything a page break depends on: the file, the settings that move
    /// text, the page size, and the app and OS that laid it out.
    static func key(for url: URL, typography: EPUBTypography, geometry: EPUBPageGeometry) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let text = geometry.textSize
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let parts: [String] = [
            "\(version)", url.standardizedFileURL.path, size.stringValue, "\(modified.timeIntervalSince1970)",
            typography.layoutSignature, "\(text.width)x\(text.height)", build,
            ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The saved breaks for this book laid out with `typography`, if any.
    static func load(for url: URL, typography: EPUBTypography, geometry: EPUBPageGeometry, chapterCount: Int,
                     in directory: URL = directory) -> [[NSRange]]? {
        guard let key = key(for: url, typography: typography, geometry: geometry),
              let data = try? Data(contentsOf: fileURL(key, in: directory)),
              let flat = try? PropertyListDecoder().decode([[Int]].self, from: data),
              flat.count == chapterCount else { return nil }
        let pages = flat.map { pairs in
            stride(from: 0, to: pairs.count - 1, by: 2).map { NSRange(location: pairs[$0], length: pairs[$0 + 1]) }
        }
        // Empty for a chapter outside the reading flow; ``EPUBPagination``
        // paginates again any chapter in the flow saved that way.
        return pages
    }

    static func save(_ pages: [[NSRange]], for url: URL, typography: EPUBTypography, geometry: EPUBPageGeometry,
                     in directory: URL = directory) {
        guard let key = key(for: url, typography: typography, geometry: geometry),
              let data = try? PropertyListEncoder().encode(pages.map { $0.flatMap { [$0.location, $0.length] } })
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key, in: directory), options: .atomic)
        prune(directory)
    }

    /// Forgets breaks that turned out not to fit the book's text.
    static func remove(for url: URL, typography: EPUBTypography, geometry: EPUBPageGeometry,
                       in directory: URL = directory) {
        guard let key = key(for: url, typography: typography, geometry: geometry) else { return }
        try? FileManager.default.removeItem(at: fileURL(key, in: directory))
    }

    private static func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)), files.count > fileLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - fileLimit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileURL(_ key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("plist")
    }
}
