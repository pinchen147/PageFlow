//
//  PageIndexMath.swift
//  PageFlow
//
//  Pure arithmetic for where the current page lands after a structural edit.
//

import Foundation

/// Where the current page index lands after a structural page edit
/// (delete / duplicate / move). These off-by-one shifts are the bug-prone part
/// of PDFManager's page operations, so they are isolated here as pure functions
/// that every branch can be unit-tested against without a document.
///
/// The effectful orchestration (the PDFKit mutation, undo registration, dirty /
/// version bumps, and the page-mutation fan-out) stays in PDFManager — see
/// ADR-0003. Each function returns the new current index; the caller applies it
/// and recomputes `currentPage`.
enum PageIndexMath {
    /// Current index after the page at `deletedIndex` is removed.
    ///
    /// `newPageCount` is the page count *after* removal (so it is `>= 1`, which
    /// the callers guarantee by refusing to delete the last remaining page).
    static func afterDeletion(current: Int, deletedIndex: Int, newPageCount: Int) -> Int {
        if current > deletedIndex {
            return current - 1
        } else if current >= newPageCount {
            return newPageCount - 1
        } else {
            return current
        }
    }

    /// Current index after a page is inserted at `insertedIndex` (e.g. duplicate).
    /// A page inserted at or before the current page shifts it down by one.
    static func afterInsertion(current: Int, insertedIndex: Int) -> Int {
        current >= insertedIndex ? current + 1 : current
    }

    /// Current index after the page at `from` is moved to `to`.
    static func afterMove(current: Int, from: Int, to: Int) -> Int {
        if current == from {
            return to
        } else if from < current && to >= current {
            return current - 1
        } else if from > current && to <= current {
            return current + 1
        } else {
            return current
        }
    }
}
