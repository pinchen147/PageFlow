//
//  EPUBAnnotationStore.swift
//  PageFlow
//
//  What the reader placed in a book — highlights, notes and bookmarks —
//  kept apart from `DocumentStateStore`, which remembers where and how a
//  file was read and forgets the oldest past 500 documents. Annotations are
//  the reader's own writing, so they are never pruned: one JSON file per
//  book under Application Support, filed under the publication's identity
//  (its package's unique identifier) so renaming or moving the file keeps
//  them. A book whose package names no identifier is filed under its path.
//

import CryptoKit
import Foundation
import os.log

/// A book's highlights (with their notes) and bookmarks.
struct EPUBAnnotations: Codable, Equatable, Sendable {
    var highlights: [EPUBHighlight] = []
    var bookmarks: [EPUBBookmark] = []

    var isEmpty: Bool { highlights.isEmpty && bookmarks.isEmpty }
}

@MainActor
final class EPUBAnnotationStore {
    static let shared = EPUBAnnotationStore(directory: TestEnvironment.isRunningTests
        ? FileManager.default.temporaryDirectory.appendingPathComponent("PageFlow-EPUB-Annotations-\(UUID().uuidString)")
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageFlow/EPUB Annotations", isDirectory: true))

    /// Which book a file belongs to: its identifier when it has one, else
    /// the canonical path of the file it was read from.
    struct Key: Equatable {
        let identifier: String?
        let path: String

        init(identifier: String?, url: URL) {
            self.identifier = identifier
            path = url.pageFlowCanonicalDocumentURL.path
        }

        fileprivate var fileName: String { Self.fileName(identifier.map { "id:\($0)" } ?? "path:\(path)") }

        /// The path-keyed file a book with an identifier may have been filed under.
        fileprivate var pathFileName: String { Self.fileName("path:\(path)") }

        private static func fileName(_ identity: String) -> String {
            SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        }
    }

    /// One book's file: its annotations and, for a person reading it, which book it is.
    private struct Record: Codable {
        var identifier: String?
        var path: String
        var highlights: [EPUBHighlight]
        var bookmarks: [EPUBBookmark]
        var updatedAt: Date
    }

    let directory: URL
    private let logger = Logger(subsystem: "com.pageflow", category: "EPUBAnnotationStore")

    init(directory: URL) {
        self.directory = directory
    }

    /// The book's annotations, or nil when none were ever saved for it.
    func annotations(for key: Key) -> EPUBAnnotations? {
        let candidates = key.identifier == nil ? [key.fileName] : [key.fileName, key.pathFileName]
        for name in candidates {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            do {
                let record = try JSONDecoder().decode(Record.self, from: data)
                return EPUBAnnotations(highlights: record.highlights.sorted(by: EPUBHighlight.inReadingOrder),
                                       bookmarks: record.bookmarks)
            } catch {
                logger.error("Unreadable annotations \(name): \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Whether the book's annotations sit in its own file, with no path-keyed
    /// copy left to fold in.
    func isFiled(under key: Key) -> Bool {
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        return exists(key.fileName) && (key.identifier == nil || !exists(key.pathFileName))
    }

    #if DEBUG
    /// Writes made, for `CountBudgetTests`.
    private(set) var debugSaveCount = 0
    #endif

    /// Saves the book's annotations, all of them, as they are now: an empty
    /// set is kept too, so removed highlights stay removed. Returns whether
    /// they reached the disk.
    @discardableResult
    func save(_ annotations: EPUBAnnotations, for key: Key) -> Bool {
        #if DEBUG
        debugSaveCount += 1
        #endif
        let record = Record(identifier: key.identifier, path: key.path, highlights: annotations.highlights,
                            bookmarks: annotations.bookmarks, updatedAt: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
            // A path-keyed copy from before the identifier was known is folded in now.
            if key.identifier != nil {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(key.pathFileName))
            }
            return true
        } catch {
            logger.error("Failed to save annotations: \(error.localizedDescription)")
            return false
        }
    }
}
