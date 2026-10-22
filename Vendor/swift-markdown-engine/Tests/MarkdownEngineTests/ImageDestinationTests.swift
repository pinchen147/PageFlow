import AppKit
import Testing
@testable import MarkdownEngine

/// The image provider receives the link's destination itself, as CommonMark
/// reads it: no title, no `<…>`, escapes decoded.
@Suite("Image destinations")
struct ImageDestinationTests {
    private final class Recorder: EmbeddedImageProvider, @unchecked Sendable {
        var names: [String] = []
        func image(for reference: EmbeddedImageRequest) -> NSImage? {
            names.append(reference.name)
            return nil
        }
        func fingerprint() -> AnyHashable { 0 }
    }

    private func requestedName(for source: String) -> String? {
        let recorder = Recorder()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.images = recorder
        _ = MarkdownStyler.styleAttributes(
            text: source, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )
        return recorder.names.first
    }

    @Test(arguments: [
        ("![a](plain.png)", "plain.png"),
        ("![a](<my 'draft'.png>)", "my 'draft'.png"),
        ("![a](shot.png \"A title\")", "shot.png"),
        ("![a](<two words.png> 'title')", "two words.png"),
    ])
    func providerGetsTheDecodedDestination(_ source: String, _ expected: String) {
        #expect(requestedName(for: source) == expected)
    }
}
