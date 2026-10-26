//
//  MarkdownDocumentManagerTests.swift
//  PageFlowTests
//
//  The text-document IO layer: byte-faithful load/save on disk, dirty tracking,
//  untitled/Save-As lifecycle, the metadata-preserving write primitive, and the
//  external-change seam (ADR-0008, ADR-0012).
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct MarkdownDocumentManagerTests {

    // MARK: - Temp-file helpers

    /// A unique temp file seeded with `bytes`; removed when `body` returns.
    private func withTempFile(
        ext: String = "md", bytes: Data, _ body: (URL) async throws -> Void
    ) async rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try? bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    private func rawBytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    @Test
    func anEmptyRecoveredDraftNeedsSavingUntilItsOwnSaveAsCompletes() async throws {
        let manager = MarkdownDocumentManager()
        manager.recoverUnsavedSource("", title: "Deleted contents")
        #expect(manager.isDirty)
        #expect(manager.documentURL == nil)
        #expect(manager.documentTitle == "Recovered — Deleted contents")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(manager.saveAsSync(to: url))
        #expect(!manager.isDirty)
        #expect(manager.documentURL == url)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test
    func recoveredSourceStaysUnsavedAndCannotReplaceAnOpenOriginal() async throws {
        try await withTempFile(bytes: Data("original".utf8)) { url in
            let source = "# e\u{301} 😀\n\n| A | B |\n| --- | --- |\n| **one** | 二 |\n"
            let draft = MarkdownDocumentManager()
            draft.recoverUnsavedSource(source, title: "Original")
            #expect(draft.source.hasSameSource(as: source))
            #expect(draft.isDirty)
            #expect(draft.documentURL == nil)
            #expect(try String(contentsOf: url, encoding: .utf8) == "original")
            try draft.load(from: url)
            #expect(!draft.isDirty)
            #expect(draft.documentTitle == url.deletingPathExtension().lastPathComponent)
            draft.recoverUnsavedSource("must not replace", title: "Other")
            #expect(draft.source == "original")
        }
    }

    @Test
    func largeNoteStatisticsDoNotBlockPublishingTheDocumentText() async throws {
        let manager = MarkdownDocumentManager()
        let source = "# Large\n\n" + String(repeating: "word 😀 ", count: 20_000)
        manager.text = source
        #expect(manager.source.hasSameSource(as: source))
        #expect(manager.wordCount.words == 0, "large-note statistics must not run synchronously on the UI actor")
        let deadline = ContinuousClock.now + .seconds(3)
        while manager.wordCount.words == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.wordCount.words == 40_002)
        #expect(manager.outline.map(\.title) == ["Large"])
        #expect(manager.source.hasSameSource(as: source))
    }

    @Test
    func supersededStatisticsStopDuringLongParagraphs() {
        let paragraph = String(repeating: "word 😀 ", count: 20_000)
        var outlinePolls = 0
        let outline = MarkdownOutline.parse(paragraph) {
            outlinePolls += 1
            return outlinePolls >= 2
        }
        #expect(outline == nil, "a canceled scan must not deliver a partial outline")
        var wordPolls = 0
        let words = WordCount.count(paragraph) {
            wordPolls += 1
            return wordPolls >= 2
        }
        #expect(words == nil, "a canceled scan must not deliver a partial count")
    }

    // MARK: - Load

    @Test
    func loadReadsNormalizesAndIsClean() async throws {
        try await withTempFile(bytes: Data("a\r\nb\r\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)

            #expect(manager.text == "a\nb\n")            // normalized in memory
            #expect(manager.savedText == "a\nb\n")
            #expect(!manager.isDirty)
            #expect(manager.documentURL == url)
            #expect(manager.fidelity.lineEnding == .crlf)
            #expect(manager.contentModificationDate != nil)
        }
    }

    // MARK: - Dirty + save round-trip

    @Test
    func editingMakesDirtyAndSaveSyncClearsIt() async throws {
        try await withTempFile(bytes: Data("hello\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)

            manager.text = "hello world\n"
            #expect(manager.isDirty)

            #expect(manager.saveSync())
            #expect(!manager.isDirty)
            #expect(manager.savedText == "hello world\n")
            #expect(rawBytes(url) == Data("hello world\n".utf8))
        }
    }

    @Test(arguments: [false, true])
    func canonicallyEquivalentEditsRemainDirtyUntilExactBytesAreSaved(fromDecomposed: Bool) async throws {
        let composed = Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A])
        let decomposed = Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81, 0x0A])
        let original = fromDecomposed ? decomposed : composed
        let edited = fromDecomposed ? composed : decomposed
        try await withTempFile(bytes: original) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            #expect(!manager.isDirty)
            #expect(Data(manager.text.utf8) == original)

            manager.text = String(decoding: edited, as: UTF8.self)
            #expect(manager.isDirty, "Changing the source's Unicode representation must enable Save and close protection")
            #expect(rawBytes(url) == original)
            #expect(manager.saveSync())
            #expect(rawBytes(url) == edited)
            #expect(Data(manager.savedText.utf8) == edited)
            #expect(!manager.isDirty)
        }
    }

    @Test
    func asyncSavePreservesCRLFOnDisk() async throws {
        try await withTempFile(bytes: Data("a\r\nb\r\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            manager.text = "a\nb\nc\n"   // edited in normalized form

            #expect(await manager.save())
            // Saved back with the file's original CRLF endings, not LF.
            #expect(rawBytes(url) == Data("a\r\nb\r\nc\r\n".utf8))
            #expect(!manager.isDirty)
        }
    }

    @Test
    func reSavingWithoutEditsIsIdempotentAndByteStable() async throws {
        let original = Data("x\r\ny\r\n".utf8)
        try await withTempFile(bytes: original) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            #expect(manager.saveSync())
            #expect(rawBytes(url) == original)   // no silent normalization
        }
    }

    // MARK: - Untitled + Save-As (ADR-0012 D4/D6)

    @Test
    func untitledManagerIsCleanAndSaveIsANoOpWithoutURL() async {
        let manager = MarkdownDocumentManager()
        #expect(!manager.isDirty)                 // empty untitled is not dirty (D6)
        #expect(manager.documentTitle == "Untitled")
        #expect(!manager.hasDocumentURL)

        manager.text = "draft\n"
        #expect(manager.isDirty)
        #expect(await manager.save() == false)    // no URL → caller routes to Save-As
        #expect(!manager.saveSync())
    }

    @Test
    func saveAsRehomesIdentityAndWritesBytes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Notes.md")

        let manager = MarkdownDocumentManager()
        manager.text = "fresh content\n"

        #expect(await manager.saveAs(to: target))
        #expect(manager.documentURL == target)
        #expect(manager.documentTitle == "Notes")
        #expect(!manager.isDirty)
        #expect(rawBytes(target) == Data("fresh content\n".utf8))
    }

    // MARK: - Metadata-preserving write (the locked primitive's payoff)

    @Test
    func savePreservesPOSIXPermissionsAndExtendedAttributes() async throws {
        try await withTempFile(bytes: Data("keep my metadata\n".utf8)) { url in
            // Seed a non-default permission and a Finder-style extended attribute.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640], ofItemAtPath: url.path)
            setXattr(url, name: "com.pageflow.test.tag", value: "important")

            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            manager.text = "edited, metadata must survive\n"
            #expect(manager.saveSync())

            // A bare atomic write would have reset both; replaceItemAt keeps them.
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(perms == 0o640)
            #expect(getXattr(url, name: "com.pageflow.test.tag") == "important")
            #expect(rawBytes(url) == Data("edited, metadata must survive\n".utf8))
        }
    }

    // MARK: - Encoding downgrade note (ADR-0008)

    @Test
    func utf16SourceIsReadAndFlaggedThenSavedAsUTF8() async throws {
        let text = "héllo\nworld\n"
        let bytes = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        try await withTempFile(bytes: bytes) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)

            #expect(manager.text == text)
            #expect(manager.encodingWasDowngraded)   // surfaced as a one-time note

            #expect(manager.saveSync())
            #expect(rawBytes(url) == Data(text.utf8))  // now plain UTF-8, no BOM
        }
    }

    /// Once a save downgrades an 8-bit file to UTF-8 (the text outgrew the
    /// encoding), it must STAY UTF-8 — removing the offending character and saving
    /// again must not silently flip the file back to the original encoding.
    @Test
    func eightBitToUTF8DowngradeIsStickyAcrossSaves() async throws {
        // 'h', 'é' (0xE9), LF in CP1252 — invalid UTF-8, so it loads as CP1252.
        try await withTempFile(bytes: Data([0x68, 0xE9, 0x0A])) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            #expect(manager.fidelity.encoding == .windowsCP1252)

            manager.text = "h😀é\n"   // emoji overflows CP1252 → downgrade to UTF-8
            #expect(manager.saveSync())
            #expect(manager.encodingWasDowngraded)

            // 'é' alone IS representable in CP1252 (0xE9). Without sticky downgrade
            // this save would flip back to CP1252; it must stay UTF-8 (0xC3 0xA9).
            manager.text = "hé\n"
            #expect(manager.saveSync())
            #expect(rawBytes(url) == Data("hé\n".utf8))
        }
    }

    // MARK: - External-change seam (ADR-0012 D5)

    @Test
    func diskWasModifiedExternallyTracksTheModificationDate() async throws {
        try await withTempFile(bytes: Data("v1\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            #expect(!manager.diskWasModifiedExternally())

            // Simulate an external edit with a strictly newer modification date.
            let future = Date().addingTimeInterval(5)
            try Data("v2 external\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

            #expect(manager.diskWasModifiedExternally())
        }
    }

    /// A newer modification date over the SAME bytes (a sync client re-writing
    /// the file, a touch) is not an external edit: no prompt, and the baseline
    /// adopts the new date so the check stays cheap afterwards.
    @Test
    func sameBytesWithANewerDateAreNotAnExternalChange() async throws {
        try await withTempFile(bytes: Data("v1\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let future = Date().addingTimeInterval(5)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

            #expect(!manager.diskWasModifiedExternally())
            #expect(manager.contentModificationDate == future)
        }
    }

    enum ExternalRewriteDate: String, CaseIterable, Sendable {
        case same, older, newer

        func value(relativeTo baseline: Date) -> Date {
            switch self {
            case .same: baseline
            case .older: baseline.addingTimeInterval(-600)
            case .newer: baseline.addingTimeInterval(600)
            }
        }
    }

    /// Replace the real file, then restore the requested timestamp. This models
    /// sync/checkout tools that install another inode while preserving file dates.
    private func replaceExternally(_ bytes: Data, at url: URL, modificationDate: Date) throws {
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let oldInode = try #require(before[.systemFileNumber] as? NSNumber)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        let newInode = try #require(after[.systemFileNumber] as? NSNumber)
        try #require(newInode != oldInode,
                     "the fixture must install a real replacement file")
        try #require(after[.modificationDate] as? Date == modificationDate,
                     "the fixture must establish the intended timestamp relation")
        try #require(Data(contentsOf: url) == bytes)
    }

    @Test(arguments: [false, true])
    func externalCanonicalUnicodeChangeIsDifferentSource(fromDecomposed: Bool) async throws {
        let composed = Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A])
        let decomposed = Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81, 0x0A])
        let original = fromDecomposed ? decomposed : composed
        let external = fromDecomposed ? composed : decomposed
        try await withTempFile(bytes: original) { url in
            // Whole seconds survive Foundation ↔ filesystem conversion exactly,
            // so each timestamp relation below is a qualified control.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let baseline = try #require(manager.contentModificationDate)
            try #require(original != external)
            try #require(String(decoding: original, as: UTF8.self) == String(decoding: external, as: UTF8.self),
                         "this control must isolate canonically equivalent but byte-distinct source")
            try replaceExternally(external, at: url, modificationDate: baseline.addingTimeInterval(600))

            #expect(manager.diskWasModifiedExternally(), "an external source edit must require a Reload/Keep decision")
            #expect(manager.diskWasModifiedExternally(), "checking must not acknowledge an unresolved external edit")
            #expect(manager.contentModificationDate == baseline)
            #expect(Data(manager.text.utf8) == original)
            #expect(Data(manager.savedText.utf8) == original)
            #expect(!manager.isDirty, "detection must leave the clean local source untouched")
            #expect(rawBytes(url) == external)
        }
    }

    @Test(arguments: [ExternalRewriteDate.same, .older], [false, true])
    func externalReplacementWithPreservedOrOlderDateRequiresDecision(
        timestamp: ExternalRewriteDate, initiallyDirty: Bool
    ) async throws {
        let original = Data("base-1\r\n".utf8)
        let external = Data("base-2\r\n".utf8)
        try await withTempFile(bytes: original) { url in
            // Whole seconds survive Foundation ↔ filesystem conversion exactly,
            // so each timestamp relation below is a qualified control.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let baseline = try #require(manager.contentModificationDate)
            let local = initiallyDirty ? "local draft\n" : "base-1\n"
            if initiallyDirty { manager.text = local }
            try #require(original.count == external.count, "file size must not reveal the source change")
            try replaceExternally(external, at: url, modificationDate: timestamp.value(relativeTo: baseline))

            #expect(manager.diskWasModifiedExternally(), "file dates do not authorize discarding a different disk source")
            #expect(manager.diskWasModifiedExternally(), "an unresolved conflict must remain detectable")
            #expect(manager.text.utf8.elementsEqual(local.utf8))
            #expect(manager.savedText.utf8.elementsEqual("base-1\n".utf8))
            #expect(manager.isDirty == initiallyDirty)
            #expect(manager.fidelity.lineEnding == .crlf)
            #expect(rawBytes(url) == external)
        }
    }

    @Test(arguments: ExternalRewriteDate.allCases, [false, true])
    func identicalExternalReplacementDoesNotConflictWithLocalDraft(
        timestamp: ExternalRewriteDate, initiallyDirty: Bool
    ) async throws {
        let original = Data("unchanged cafe\u{301}\r\n".utf8)
        try await withTempFile(bytes: original) { url in
            // Whole seconds survive Foundation ↔ filesystem conversion exactly,
            // so each timestamp relation below is a qualified control.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let baseline = try #require(manager.contentModificationDate)
            let local = initiallyDirty ? "unsaved local draft\n" : manager.text
            if initiallyDirty { manager.text = local }
            try replaceExternally(original, at: url, modificationDate: timestamp.value(relativeTo: baseline))

            #expect(!manager.diskWasModifiedExternally(), "an identical saved source must not prompt, even with a local draft")
            #expect(!manager.diskWasModifiedExternally())
            #expect(manager.text.utf8.elementsEqual(local.utf8))
            #expect(manager.savedText.utf8.elementsEqual("unchanged cafe\u{301}\n".utf8))
            #expect(manager.isDirty == initiallyDirty)
            #expect(manager.fidelity.lineEnding == .crlf)
            #expect(rawBytes(url) == original)
        }
    }

    @Test(arguments: [false, true])
    func keepAcknowledgesOnlyTheObservedDiskSource(initiallyDirty: Bool) async throws {
        try await withTempFile(bytes: Data("base-1\r\n".utf8)) { url in
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let baseline = try #require(manager.contentModificationDate)
            let externalDate = baseline.addingTimeInterval(-600)
            let local = initiallyDirty ? "unsaved local draft\n" : manager.text
            if initiallyDirty { manager.text = local }
            try replaceExternally(Data("base-2\r\n".utf8), at: url, modificationDate: externalDate)
            try #require(manager.diskWasModifiedExternally())

            manager.keepLocalVersionIgnoringDisk()
            #expect(!manager.diskWasModifiedExternally(), "Keep must acknowledge the actual external source")
            #expect(!manager.diskWasModifiedExternally(), "the unchanged acknowledged version must not re-prompt")
            #expect(manager.text.utf8.elementsEqual(local.utf8))
            #expect(manager.savedText.utf8.elementsEqual("base-1\n".utf8))
            #expect(manager.isDirty, "Keep still requires writing the local version")
            #expect(rawBytes(url) == Data("base-2\r\n".utf8))

            // Another same-size version has the exact acknowledged timestamp.
            // Keep authorized the preceding source, not every future write.
            try replaceExternally(Data("base-3\r\n".utf8), at: url, modificationDate: externalDate)
            #expect(manager.diskWasModifiedExternally())
            #expect(manager.diskWasModifiedExternally())
            #expect(manager.text.utf8.elementsEqual(local.utf8))
            #expect(manager.isDirty)
            #expect(rawBytes(url) == Data("base-3\r\n".utf8))

            try manager.reload()
            #expect(manager.text.utf8.elementsEqual("base-3\n".utf8))
            #expect(manager.savedText.utf8.elementsEqual("base-3\n".utf8))
            #expect(!manager.isDirty)
            #expect(!manager.diskWasModifiedExternally())
        }
    }

    @Test
    func backgroundReloadPreservesEncodingAndReplacesTheDirtyBaseline() async throws {
        try await withTempFile(bytes: Data("Original\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            manager.text = "Local edit"
            try Data("# Changed e\u{301} 😀\r\n".utf8).write(to: url)
            #expect(try await manager.reloadWithCompletion())
            #expect(manager.text.hasSameSource(as: "# Changed e\u{301} 😀\n"))
            #expect(manager.fidelity.lineEnding == .crlf)
            #expect(!manager.isDirty)
            #expect(manager.saveSync())
            #expect(try Data(contentsOf: url) == Data("# Changed e\u{301} 😀\r\n".utf8))
        }
    }

    @Test(arguments: [false, true])
    func anUnreadableBackgroundReloadLeavesTheDraftAndBaselineIntact(binary: Bool) async throws {
        try await withTempFile(bytes: Data("Original\r\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            manager.text = "Local draft"
            if binary { try Data([0, 0, 0, 0, 0]).write(to: url) }
            else { try FileManager.default.removeItem(at: url) }
            var rebuilt = false
            var failed = false
            do { _ = try await manager.reloadWithCompletion(willApply: { rebuilt = true }) }
            catch { failed = true }
            #expect(failed && !rebuilt)
            #expect(manager.text == "Local draft")
            #expect(manager.savedText == "Original\n")
            #expect(manager.documentURL == url)
            #expect(manager.fidelity.lineEnding == .crlf)
            #expect(manager.isDirty)
        }
    }

    @Test
    func keepingAnObservedVersionDoesNotAcknowledgeALaterUnseenWrite() async throws {
        try await withTempFile(bytes: Data("Original\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            manager.text = "Local edit"
            let probe = try #require(manager.diskProbe())
            try Data("Observed\n".utf8).write(to: url)
            let observation = MarkdownDocumentManager.observe(probe)
            try Data("Unseen update\n".utf8).write(to: url)
            #expect(manager.keepLocalVersionIgnoringDisk(observation, for: probe))
            #expect(manager.text == "Local edit")
            #expect(manager.isDirty)
            #expect(manager.diskWasModifiedExternally())
            manager.close()
            #expect(!manager.keepLocalVersionIgnoringDisk(observation, for: probe))
        }
    }

    // MARK: - Reload vs Keep (ADR-0012 D5, S9)

    /// Reload re-reads the on-disk bytes, re-detects the line ending, drops the local
    /// draft (clean again), and advances the baseline so the tab stops re-prompting.
    @Test(arguments: [false, true])
    func reloadRereadsChangedBytesReDetectsEOLAndClearsDirty(keepLocalVersionFirst: Bool) async throws {
        try await withTempFile(bytes: Data("a\nb\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            #expect(manager.fidelity.lineEnding == .lf)

            if !keepLocalVersionFirst {
                manager.text = "local draft\n"
                #expect(manager.isDirty)
            }

            // External rewrite: different bytes, CRLF endings, newer mod date.
            let future = Date().addingTimeInterval(5)
            try Data("x\r\ny\r\nz\r\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
            #expect(manager.diskWasModifiedExternally())

            if keepLocalVersionFirst {
                manager.keepLocalVersionIgnoringDisk()
                #expect(manager.isDirty)
            }
            try manager.reload()
            #expect(manager.text == "x\ny\nz\n")          // re-read + normalized to \n
            #expect(manager.savedText == "x\ny\nz\n")
            #expect(!manager.isDirty)                      // draft discarded, clean baseline
            #expect(manager.fidelity.lineEnding == .crlf)  // EOL re-detected on reload
            #expect(!manager.diskWasModifiedExternally())  // baseline advanced
        }
    }

    @Test(arguments: [false, true], [false, true])
    func keepLocalVersionRequiresSavingUntilTheLocalBytesReachDisk(
        initiallyDirty: Bool, saveAsynchronously: Bool
    ) async throws {
        try await withTempFile(bytes: Data("v1\r\n".utf8)) { url in
            let manager = MarkdownDocumentManager()
            try manager.load(from: url)
            let localText = initiallyDirty ? "my local edit\n" : "v1\n"
            let localBytes = Data((initiallyDirty ? "my local edit\r\n" : "v1\r\n").utf8)
            if initiallyDirty { manager.text = localText }
            #expect(manager.isDirty == initiallyDirty)

            let future = Date().addingTimeInterval(5)
            try Data("v2 external\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
            #expect(manager.diskWasModifiedExternally())

            manager.keepLocalVersionIgnoringDisk()
            #expect(!manager.diskWasModifiedExternally())
            #expect(manager.text == localText)
            #expect(manager.savedText == "v1\n")
            #expect(manager.isDirty)

            let saved: Bool
            if saveAsynchronously {
                saved = await manager.save()
            } else {
                saved = manager.saveSync()
            }
            #expect(saved)
            #expect(rawBytes(url) == localBytes)
            #expect(manager.savedText == localText)
            #expect(!manager.isDirty)
        }
    }

    @Test(arguments: [false, true])
    func failedSavePreservesTheKeptLocalVersion(saveAsynchronously: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.md")
        try Data("v1\r\n".utf8).write(to: url)
        let manager = MarkdownDocumentManager()
        try manager.load(from: url)
        #expect(!manager.isDirty)

        try Data("v2 external\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(manager.diskWasModifiedExternally())
        manager.keepLocalVersionIgnoringDisk()
        #expect(manager.isDirty)

        // A file in place of the parent directory makes either real write path fail.
        try FileManager.default.removeItem(at: directory)
        try Data("blocked parent".utf8).write(to: directory)
        let saved: Bool
        if saveAsynchronously {
            saved = await manager.save()
        } else {
            saved = manager.saveSync()
        }
        #expect(!saved)
        #expect(manager.text == "v1\n")
        #expect(manager.savedText == "v1\n")
        #expect(manager.fidelity.lineEnding == .crlf)
        #expect(manager.isDirty)
    }
}

// MARK: - Extended-attribute test helpers

private func setXattr(_ url: URL, name: String, value: String) {
    let data = Data(value.utf8)
    _ = data.withUnsafeBytes { raw in
        setxattr(url.path, name, raw.baseAddress, data.count, 0, 0)
    }
}

private func getXattr(_ url: URL, name: String) -> String? {
    let length = getxattr(url.path, name, nil, 0, 0, 0)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let read = data.withUnsafeMutableBytes { raw in
        getxattr(url.path, name, raw.baseAddress, length, 0, 0)
    }
    guard read >= 0 else { return nil }
    return String(data: data, encoding: .utf8)
}
