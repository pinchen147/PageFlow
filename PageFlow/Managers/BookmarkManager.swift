//
//  BookmarkManager.swift
//  PageFlow
//
//  Manages bookmarks for PDF documents with UserDefaults persistence.
//

import AppKit
import Foundation
import Observation
import os.log

@Observable
@MainActor
final class BookmarkManager {
    private let logger = Logger(subsystem: "com.pageflow", category: "BookmarkManager")

    deinit {
        #if DEBUG
        Swift.print("[deinit] BookmarkManager")
        #endif
    }

    // MARK: - State

    private(set) var bookmarks: [BookmarkModel] = []
    var selectedBookmarkID: UUID?

    private weak var pdfManager: PDFManager?
    private var undoManagerProvider: (() -> UndoManager?)?
    private let defaults = UserDefaults.standard
    private let keyPrefix = "bookmarks:"

    // MARK: - Computed Properties

    var sortedBookmarks: [BookmarkModel] {
        bookmarks.sorted { $0.pageIndex < $1.pageIndex }
    }

    // MARK: - Configuration

    func configure(
        pdfManager: PDFManager,
        undoManagerProvider: @escaping () -> UndoManager?
    ) {
        self.pdfManager = pdfManager
        self.undoManagerProvider = undoManagerProvider
    }

    private func getUndoManager(for action: String) -> UndoManager? {
        guard let undoManager = undoManagerProvider?() else {
            assertionFailure("UndoManager unavailable for: \(action)")
            return nil
        }
        return undoManager
    }

    // MARK: - Actions

    func toggleBookmark(at pageIndex: Int) {
        if let existing = bookmarks.first(where: { $0.pageIndex == pageIndex }) {
            removeBookmark(existing.id)
        } else {
            addBookmark(at: pageIndex)
        }
    }

    func addBookmark(at pageIndex: Int) {
        guard !isBookmarked(pageIndex) else { return }

        let bookmark = BookmarkModel(pageIndex: pageIndex)
        bookmarks.append(bookmark)
        pdfManager?.isDirty = true
        save()

        registerUndoAdd(bookmark)
    }

    func removeBookmark(_ id: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }

        let bookmark = bookmarks[index]
        bookmarks.remove(at: index)

        if selectedBookmarkID == id {
            selectedBookmarkID = nil
        }

        pdfManager?.isDirty = true
        save()

        registerUndoRemove(bookmark)
    }

    func isBookmarked(_ pageIndex: Int) -> Bool {
        bookmarks.contains { $0.pageIndex == pageIndex }
    }

    func selectBookmark(_ id: UUID?) {
        selectedBookmarkID = id

        guard let id,
              let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return
        }

        pdfManager?.goToPage(bookmark.pageIndex)
    }

    func renameBookmark(_ id: UUID, to newTitle: String) {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty,
              let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            return
        }

        let oldTitle = bookmarks[index].title
        guard oldTitle != newTitle else { return }

        bookmarks[index].title = newTitle
        pdfManager?.isDirty = true
        save()

        if let undoManager = getUndoManager(for: "Rename Bookmark") {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.renameBookmark(id, to: oldTitle)
                }
            }
            undoManager.setActionName("Rename Bookmark")
        }
    }

    // MARK: - Document Loading

    func loadBookmarks(for documentURL: URL?) {
        bookmarks.removeAll()
        selectedBookmarkID = nil

        guard let url = documentURL,
              let key = storageKey(for: url),
              let data = defaults.data(forKey: key) else {
            return
        }

        do {
            let loaded = try JSONDecoder().decode([BookmarkModel].self, from: data)
            let pageCount = pdfManager?.pageCount ?? 0
            bookmarks = loaded.filter { $0.pageIndex < pageCount }
        } catch {
            logger.error("Failed to decode bookmarks: \(error.localizedDescription)")
        }
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        selectedBookmarkID = nil
    }

    // MARK: - Persistence

    private func save() {
        guard let url = pdfManager?.documentURL,
              let key = storageKey(for: url) else {
            return
        }

        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode bookmarks: \(error.localizedDescription)")
        }
    }

    private func storageKey(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        return keyPrefix + path
    }

    // MARK: - Undo/Redo

    private func registerUndoAdd(_ bookmark: BookmarkModel) {
        guard let undoManager = getUndoManager(for: "Add Bookmark") else { return }

        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.undoAdd(bookmark)
            }
        }
        undoManager.setActionName("Add Bookmark")
    }

    private func undoAdd(_ bookmark: BookmarkModel) {
        bookmarks.removeAll { $0.id == bookmark.id }
        if selectedBookmarkID == bookmark.id {
            selectedBookmarkID = nil
        }
        pdfManager?.isDirty = true
        save()

        guard let undoManager = getUndoManager(for: "Add Bookmark") else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.redoAdd(bookmark)
            }
        }
        undoManager.setActionName("Add Bookmark")
    }

    private func redoAdd(_ bookmark: BookmarkModel) {
        bookmarks.append(bookmark)
        pdfManager?.isDirty = true
        save()

        registerUndoAdd(bookmark)
    }

    private func registerUndoRemove(_ bookmark: BookmarkModel) {
        guard let undoManager = getUndoManager(for: "Remove Bookmark") else { return }

        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.undoRemove(bookmark)
            }
        }
        undoManager.setActionName("Remove Bookmark")
    }

    private func undoRemove(_ bookmark: BookmarkModel) {
        bookmarks.append(bookmark)
        pdfManager?.isDirty = true
        save()

        guard let undoManager = getUndoManager(for: "Remove Bookmark") else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.removeBookmark(bookmark.id)
            }
        }
        undoManager.setActionName("Remove Bookmark")
    }
}
