//
//  MarkdownPerfSignpost.swift
//  MarkdownEngine
//
//  Centralized os_signpost support for the editing hot paths. The validation
//  plan (docs/md docs/08-validation-and-gaps.md) mandates os_signpost intervals
//  around the per-edit restyle and per-caret-move work so the O(edit) — not
//  O(document) — invariant from ADR-0007 can be confirmed in Instruments.
//
//  Signpost intervals are effectively free when no profiling tool is attached,
//  so this ships in release builds. To profile: Instruments → "os_signpost",
//  filtered to subsystem `com.pageflow.MarkdownEngine`.
//

import os

enum MarkdownPerfSignpost {
    static let log = OSLog(subsystem: "com.pageflow.MarkdownEngine", category: "Editing")
    static let signposter = OSSignposter(logHandle: log)
}
