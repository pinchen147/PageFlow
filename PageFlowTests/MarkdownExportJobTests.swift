import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownExportJobTests {
    private func wait(until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ready(), "export did not complete")
    }

    @Test
    func copyingManyPagesReturnsBeforeConversionAndLeavesTheUIActorAvailable() async throws {
        let document = try #require(makeTextDocument(pages: (1...24).map { "Page \($0) marker" }))
        let job = MarkdownExportJob()
        var outputs: [String] = []
        job.start(scope: .entireDocument, document: document, isCurrent: { true }) { outputs.append($0) }
        #expect(outputs.isEmpty, "the command must return before converting the PDF")
        var actorTicks = 0
        let pulse = Task { @MainActor in
            while outputs.isEmpty, !Task.isCancelled {
                actorTicks += 1
                await Task.yield()
            }
        }
        defer { pulse.cancel() }
        try await wait { !outputs.isEmpty }
        #expect(actorTicks > 1, "conversion must allow other UI actor work")
        #expect(outputs == [(1...24).map { "Page \($0) marker" }.joined(separator: "\n\n---\n\n")])
    }

    @Test
    func aNewRequestSupersedesTheOldOneAndCancelPreventsDelivery() async throws {
        let document = try #require(makeTextDocument(pages: ["First", "Second"]))
        let job = MarkdownExportJob()
        var outputs: [String] = []
        job.start(scope: .currentPage(0), document: document, isCurrent: { true }) { outputs.append("old: " + $0) }
        job.start(scope: .currentPage(1), document: document, isCurrent: { true }) { outputs.append($0) }
        try await wait { !outputs.isEmpty }
        #expect(outputs == ["Second"])
        job.start(scope: .entireDocument, document: document, isCurrent: { true }) { outputs.append("canceled: " + $0) }
        job.cancel()
        job.start(scope: .currentPage(0), document: document, isCurrent: { true }) { outputs.append($0) }
        try await wait { outputs.count >= 2 }
        #expect(outputs == ["Second", "First"])
    }

    @Test
    func changedOrClosedSourcesCannotDeliverAResult() async throws {
        let document = try #require(makeTextDocument(pages: ["Original"]))
        let job = MarkdownExportJob()
        var current = true
        var outputs: [String] = []
        job.start(scope: .entireDocument, document: document, isCurrent: { current }) { outputs.append($0) }
        current = false
        // A second owner provides an eventual completion without canceling the
        // first owner's stale job, so its admission guard is exercised.
        let other = MarkdownExportJob()
        var finished = false
        other.start(scope: .entireDocument, document: document, isCurrent: { true }) { _ in finished = true }
        try await wait { finished }
        #expect(outputs.isEmpty)
    }
    @Test
    func exportIncludesUnsavedPageEditsAndCommentsWithoutChangingTheBackingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.pdf")
        let original = try #require(makeTextDocument(pages: ["First", "Second"]))
        let bytes = try #require(original.dataRepresentation())
        try bytes.write(to: url)
        let document = try #require(PDFDocument(url: url))
        let replacement = try #require(makeTextDocument(text: "Unsaved replacement")?.page(at: 0))
        document.removePage(at: 1)
        document.insert(replacement, at: 1)
        let comment = CommentModel(text: "Analyst note", pageIndex: 1, bounds: CGRect(x: 36, y: 700, width: 100, height: 20))
        let job = MarkdownExportJob()
        var result: String?
        job.start(scope: .currentPage(1), document: document, comments: [comment], isCurrent: { true }) { result = $0 }
        try await wait { result != nil }
        #expect(result?.contains("Unsaved replacement") == true)
        #expect(result?.contains("> Analyst note") == true)
        #expect(result?.contains("First") == false)
        #expect(result?.contains("Second") == false)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test
    func anUnlockedEncryptedPDFRetainsItsTextCommentsAndPermissions() async throws {
        let plain = try #require(makeTextDocument(pages: ["First", "Second"]))
        let bytes = try #require(plain.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner",
            PDFDocumentWriteOption.userPasswordOption: "reader",
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsContentCopying.rawValue),
        ]))
        let document = try #require(PDFDocument(data: bytes))
        try #require(document.isLocked)
        try #require(document.unlock(withPassword: "reader"))
        try #require(document.isEncrypted && document.allowsCopying)
        let before = PDFPermissions(document)
        let comment = CommentModel(text: "Private research note", pageIndex: 1, bounds: CGRect(x: 36, y: 700, width: 100, height: 20))
        let job = MarkdownExportJob()
        var result: String?
        job.start(scope: .entireDocument, document: document, comments: [comment], isCurrent: { true }) { result = $0 }
        #expect(result == nil)
        try await wait { result != nil }
        #expect(result?.contains("First") == true)
        #expect(result?.contains("Second") == true)
        #expect(result?.contains("> Private research note") == true)
        #expect(PDFPermissions(document) == before)
        #expect(!document.isLocked)
    }

    @Test(arguments: [false, true], ["\n", "\r\n", "\r"])
    func multilineCommentsRemainQuotedThroughPDFExport(hasPageText: Bool, newline: String) async throws {
        let document = try #require(makeTextDocument(text: hasPageText ? "Evidence" : ""))
        let page = try #require(document.page(at: 0))
        if hasPageText {
            try #require((page.attributedString?.length ?? 0) > 0)
        } else {
            try #require((page.attributedString?.length ?? 0) == 0, "exercise the plain-text fallback")
        }
        let comment = CommentModel(
            text: ["First", "", "Second", "# Last"].joined(separator: newline), pageIndex: 0,
            bounds: CGRect(x: 36, y: 700, width: 100, height: 20)
        )
        let job = MarkdownExportJob()
        var result: String?
        job.start(scope: .entireDocument, document: document, comments: [comment], isCurrent: { true }) { result = $0 }
        try await wait { result != nil }
        let quote = "> First\n> \n> Second\n> # Last"
        #expect(result == (hasPageText ? "Evidence\n" : "") + quote)
    }



}
