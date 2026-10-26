import Foundation
import Testing
@testable import PageFlow

@Suite("PDF write coalescing", .serialized)
struct PDFFileSessionTests {
    nonisolated private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(URL, Data)] = []
        func record(_ data: Data, to url: URL) {
            lock.lock()
            entries.append((url, data))
            lock.unlock()
        }
        var values: [(URL, Data)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    @Test("redundant pending saves write the latest snapshot and settle every caller")
    func adjacentCurrentSavesCoalesce() async throws {
        let writes = Writes()
        let file = URL(fileURLWithPath: "/tmp/pageflow-coalesced.pdf")
        let session = PDFFileSession(writer: { writes.record($0, to: $1) })
        session.reset(access: PDFFileAccess(url: file))
        let tickets = (1...40).map { revision in
            session.admit(data: Data("revision \(revision)".utf8), target: .current,
                          epoch: 1, revision: UInt64(revision))
        }
        _ = session.drain()
        #expect(writes.values.count == 1)
        #expect(writes.values.last?.1 == Data("revision 40".utf8))
        for ticket in tickets {
            let completion = await ticket.value()
            #expect(completion.didWrite)
            #expect(completion.saved?.revision == 40)
        }
    }

    @Test("Save As destinations remain ordered boundaries between coalesced saves")
    func distinctSaveAsTargetsAreNeverDropped() throws {
        let writes = Writes()
        let original = URL(fileURLWithPath: "/tmp/pageflow-original.pdf")
        let first = URL(fileURLWithPath: "/tmp/pageflow-first.pdf")
        let second = URL(fileURLWithPath: "/tmp/pageflow-second.pdf")
        let session = PDFFileSession(writer: { writes.record($0, to: $1) })
        session.reset(access: PDFFileAccess(url: original))
        func admit(_ text: String, to target: PDFFileSession.Target) {
            _ = session.admit(data: Data(text.utf8), target: target, epoch: 1, revision: 1)
        }
        admit("old current", to: .current)
        admit("latest current", to: .current)
        admit("first copy", to: .saveAs(PDFFileAccess(url: first)))
        admit("old first", to: .current)
        admit("latest first", to: .current)
        admit("second copy", to: .saveAs(PDFFileAccess(url: second)))
        admit("old second", to: .current)
        admit("latest second", to: .current)
        _ = session.drain()
        #expect(writes.values.map(\.0) == [original, first, first, second, second])
        #expect(writes.values.map { String(decoding: $0.1, as: UTF8.self) } ==
                ["latest current", "first copy", "latest first", "second copy", "latest second"])
    }

    @Test("document epochs prevent a later snapshot from replacing another document's request")
    func documentEpochsDoNotCoalesce() {
        let writes = Writes()
        let file = URL(fileURLWithPath: "/tmp/pageflow-epochs.pdf")
        let session = PDFFileSession(writer: { writes.record($0, to: $1) })
        session.reset(access: PDFFileAccess(url: file))
        _ = session.admit(data: Data("first".utf8), target: .current, epoch: 1, revision: 1)
        _ = session.admit(data: Data("second".utf8), target: .current, epoch: 2, revision: 1)
        _ = session.drain()
        #expect(writes.values.map { String(decoding: $0.1, as: UTF8.self) } == ["first", "second"])
    }

    @Test("a coalesced failure reaches all callers without reporting an earlier snapshot saved")
    func aFailedGroupSettlesEveryTicket() async {
        let session = PDFFileSession(writer: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        session.reset(access: PDFFileAccess(url: URL(fileURLWithPath: "/tmp/pageflow-failed.pdf")))
        let first = session.admit(data: Data("first".utf8), target: .current, epoch: 1, revision: 1)
        let last = session.admit(data: Data("last".utf8), target: .current, epoch: 1, revision: 2)
        _ = session.drain()
        #expect(!(await first.value()).didWrite)
        #expect(!(await last.value()).didWrite)
    }
    @Test("slow storage retains only the newest redundant save behind the running write")
    func repeatedSavesCoalesceBehindAnExecutingWriter() async throws {
        let writes = Writes()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        defer { proceed.signal() }
        let session = PDFFileSession(writer: { data, url in
            writes.record(data, to: url)
            if data == Data("executing".utf8) {
                entered.signal()
                guard proceed.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
            }
        })
        session.reset(access: PDFFileAccess(url: URL(fileURLWithPath: "/tmp/pageflow-slow.pdf")))
        _ = session.admit(data: Data("executing".utf8), target: .current, epoch: 1, revision: 1)
        let worker = Task.detached { _ = session.drain() }
        try #require(await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value)
        let tickets = (2...41).map { revision in
            session.admit(data: Data("revision \(revision)".utf8), target: .current,
                          epoch: 1, revision: UInt64(revision))
        }
        proceed.signal()
        await worker.value
        #expect(writes.values.map { String(decoding: $0.1, as: UTF8.self) } == ["executing", "revision 41"])
        for ticket in tickets { #expect((await ticket.value()).saved?.revision == 41) }
    }

}
