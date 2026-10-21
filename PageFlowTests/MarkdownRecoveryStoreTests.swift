import Foundation
import Testing
@testable import PageFlow

struct MarkdownRecoveryStoreTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func obsoleteCheckpointsDoNotPileUpBehindABusyWriter() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("journal-is-a-file")
        try Data("block journal writes".utf8).write(to: blocked)
        let store = MarkdownRecoveryStore(directory: blocked)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let failures = DispatchSemaphore(value: 0)
        store.checkpoint(.init(id: UUID(), title: "First", source: "first", updatedAt: Date())) { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 3) == .success)
        let id = UUID()
        for index in 0..<20 {
            store.checkpoint(.init(id: id, title: "Typing", source: "draft \(index)", updatedAt: Date())) { _ in
                failures.signal()
            }
        }
        release.signal()
        store.flush()
        var attempts = 0
        while failures.wait(timeout: .now()) == .success { attempts += 1 }
        #expect(attempts == 1, "only the latest pending draft should attempt disk I/O")
    }

    @Test
    func anUnwritableJournalReportsFailureAndLeavesExistingFilesAlone() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("journal-is-a-file")
        try Data("keep existing bytes".utf8).write(to: blocked)
        let reported = DispatchSemaphore(value: 0)
        let store = MarkdownRecoveryStore(directory: blocked)
        store.checkpoint(.init(id: UUID(), title: "Untitled", source: "unsaved", updatedAt: Date())) { _ in
            reported.signal()
        }
        store.flush()
        #expect(reported.wait(timeout: .now()) == .success)
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "keep existing bytes")
    }

    @Test
    func aNewStoreRecoversExactMarkdownWithoutWritingTheOriginal() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.md")
        try Data("saved original".utf8).write(to: original)
        let directory = root.appendingPathComponent("journal")
        let source = "# e\u{301} 😀\r\n\r\n| A | B |\r\n| --- | --- |\r\n| **one** | 二 |\r\n<!-- comments stay here -->"
        let record = MarkdownRecoveryStore.Record(id: UUID(), title: "Original", originalURL: original,
                                                   source: source, updatedAt: Date())
        let writer = MarkdownRecoveryStore(directory: directory)
        writer.checkpoint(record)
        writer.flush()
        let recovered = await MarkdownRecoveryStore(directory: directory).load()
        try #require(recovered.count == 1)
        #expect(recovered[0].id == record.id)
        #expect(recovered[0].originalURL == original)
        #expect(Array(recovered[0].source.utf8) == Array(source.utf8))
        #expect(try String(contentsOf: original, encoding: .utf8) == "saved original")
    }

    @Test
    func removalAfterQueuedWritesCannotResurrectADiscardedDraft() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownRecoveryStore(directory: root)
        let id = UUID()
        store.checkpoint(.init(id: id, title: "Untitled", source: "first", updatedAt: Date()))
        store.checkpoint(.init(id: id, title: "Untitled", source: "last", updatedAt: Date()))
        store.remove(id)
        store.flush()
        #expect(await MarkdownRecoveryStore(directory: root).load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".json").path))
    }

    @Test
    func latestLiteralUnicodeEditWinsEvenWhenStringsAreCanonicallyEqual() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownRecoveryStore(directory: root)
        let id = UUID()
        store.checkpoint(.init(id: id, title: "Untitled", source: "é", updatedAt: Date()))
        store.checkpoint(.init(id: id, title: "Untitled", source: "e\u{301}", updatedAt: Date()))
        store.flush()
        let records = await MarkdownRecoveryStore(directory: root).load()
        try #require(records.count == 1)
        #expect(Array(records[0].source.utf8) == [0x65, 0xCC, 0x81])
    }

    @Test
    func aCommentOnlyUnicodeEditReplacesTheDurableRecoveryRecord() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownRecoveryStore(directory: root)
        let id = UUID()
        store.checkpoint(.init(id: id, title: "Untitled", source: "unchanged body", commentBlock: "é", updatedAt: Date()))
        store.flush()
        store.checkpoint(.init(id: id, title: "Untitled", source: "unchanged body", commentBlock: "e\u{301}", updatedAt: Date()))
        store.flush()
        let records = await MarkdownRecoveryStore(directory: root).load()
        try #require(records.count == 1)
        #expect(records[0].source == "unchanged body")
        #expect(records[0].commentBlock?.utf8.elementsEqual([0x65, 0xCC, 0x81]) == true)
    }

    @Test
    func oneCorruptRecordDoesNotHideOtherRecoveredNotes() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken JSON".utf8).write(to: root.appendingPathComponent(UUID().uuidString + ".json"))
        let store = MarkdownRecoveryStore(directory: root)
        let id = UUID()
        store.checkpoint(.init(id: id, title: "Untitled", source: "keep this", updatedAt: Date()))
        store.flush()
        let records = await MarkdownRecoveryStore(directory: root).load()
        #expect(records.map(\.id) == [id])
        #expect(records.first?.source == "keep this")
    }
}
