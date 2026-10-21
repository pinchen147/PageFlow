import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image commands", .serialized)
struct ImageCommandsTests {
    @Test("align and description edits preserve destination, crop and a trailing width, and undo together")
    func editsPreserveImage() async throws {
        let source = "Before\n![Chart|crop=0,0.2,0.75,0.8|336](wide.png)\nAfter"
        let editor = try MountedImageEditor(source: source, images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        editor.coordinator.setImageAlignment(.center)
        #expect(editor.main.string.contains("![Chart|center|crop=0,0.2,0.75,0.8|336](wide.png)"))
        let aligned = editor.main.string
        editor.coordinator.setImageDescription("A [chart] | result")
        #expect(editor.main.string.contains("![A \\[chart\\] \\| result|center|crop=0,0.2,0.75,0.8|336](wide.png)"))
        #expect(editor.coordinator.objectSelection?.token == editor.main.selectedRange())
        editor.state.undo.undo()
        #expect(editor.main.string == aligned)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
    }

    @Test("image metadata stays save-safe before its normal source publication")
    func metadataFlushBeforeDebounce() async throws {
        let source = "![Chart|336](wide.png)\nAfter"
        let changed = "![Chart|300](wide.png)\nAfter"
        let editor = try MountedImageEditor(source: source,
            images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        editor.coordinator.setImageWidth(300, actionName: "Resize Image")
        #expect(editor.main.string == changed)
        #expect(editor.state.text == source, "pointer input must not synchronously publish the whole note")
        #expect(editor.state.controller.commitPendingText() == changed)
        #expect(editor.state.text == changed)
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        #expect(editor.state.controller.commitPendingText() == source)
        #expect(editor.state.text == source)
        editor.state.undo.redo()
        #expect(editor.main.string == changed)
        #expect(editor.state.controller.commitPendingText() == changed)
        #expect(editor.state.text == changed)
    }

    @Test("resize clamps to the column and crop keeps the displayed scale in one edit")
    func sizing() async throws {
        let editor = try MountedImageEditor(source: "![Chart|640](wide.png)\nAfter", images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        editor.coordinator.setImageWidth(9999, actionName: "Resize Image")
        #expect(editor.coordinator.selectedImageTarget()?.tokens.width == 672)
        editor.coordinator.setImageWidth(640, actionName: "Set Image Size")
        editor.coordinator.applyImageCrop(CGRect(x: 0, y: 0.2, width: 0.75, height: 0.8), fullWidth: 640)
        #expect(editor.main.string == "![Chart|crop=0,0.2,0.75,0.8|480](wide.png)\nAfter")
        editor.state.undo.undo()
        #expect(editor.main.string == "![Chart|640](wide.png)\nAfter")
    }

    @Test("center resizing doubles travel and all alignments stop at the column")
    func resizeGeometry() {
        #expect(ImageResizeGeometry.width(start: 300, travel: 40, left: false, alignment: .center, column: 672) == 380)
        #expect(ImageResizeGeometry.width(start: 300, travel: -999, left: true, alignment: .right, column: 672) == 672)
        #expect(ImageResizeGeometry.width(start: 300, travel: -999, left: false, alignment: .left, column: 672) == 40)
    }

    @Test("crop corners move both edges, snap at borders, and preserve a two percent minimum")
    func cropGeometry() {
        let original = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        #expect(ImageCropGeometry.drag(original, handle: .topLeft, delta: CGPoint(x: -0.195, y: -0.195)) == CGRect(x: 0, y: 0, width: 0.8, height: 0.8))
        let result = ImageCropGeometry.drag(original, handle: .bottomRight, delta: CGPoint(x: -1, y: -1))
        #expect(abs(result.width - 0.02) < 0.00001)
        #expect(abs(result.height - 0.02) < 0.00001)
    }
    @Test("resize preserves caret, text and image selections through preview, commit and history", arguments: 0..<7)
    func resizeGesture(selectionCase: Int) async throws {
        let source = "Before prose\n![OtherBefore|40](wide.png)\n\n![Chart|96](wide.png)\n\nAfter prose\n![OtherAfter|40](wide.png)\nTail"
        let changed = "Before prose\n![OtherBefore|40](wide.png)\n\n![Chart|136](wide.png)\n\nAfter prose\n![OtherAfter|40](wide.png)\nTail"
        let editor = try MountedImageEditor(source: source, images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        let after = (source as NSString).range(of: "After prose").location
        let initial: NSRange
        switch selectionCase {
        case 0: initial = NSRange(location: 3, length: 0)
        case 1: initial = NSRange(location: 0, length: 6)
        case 2: initial = NSRange(location: after + 3, length: 0)
        case 3: initial = NSRange(location: after, length: 5)
        case 4: initial = try editor.imageToken(onLineOf: "![OtherBefore").range
        case 5: initial = try editor.imageToken(onLineOf: "![OtherAfter").range
        default: initial = try editor.imageToken(onLineOf: "![Chart").range
        }
        editor.main.setSelectedRange(initial)
        let initialObject = editor.coordinator.objectSelection
        // 96 -> 136 adds one UTF16 unit inside the resized image's alt text.
        let mapped: NSRange
        if selectionCase == 6 { mapped = NSRange(location: initial.location, length: initial.length + 1) }
        else if [2, 3, 5].contains(selectionCase) { mapped = NSRange(location: initial.location + 1, length: initial.length) }
        else { mapped = initial }
        let controls = try #require(editor.coordinator.imageControls)
        func expectSelection(_ expected: NSRange) {
            #expect(editor.main.selectedRange() == expected)
            if initialObject != nil {
                #expect(editor.coordinator.objectSelection?.token == expected)
            } else { #expect(editor.coordinator.objectSelection == nil) }
        }
        func resize(travel: CGFloat, cancel: Bool = false) async throws {
            // A text/other-image selection and Undo invalidate native layout;
            // the raster rect deliberately refuses to materialize fragments.
            await editor.settle()
            expectSelection(initial)
            controls.refresh()
            let rect = try #require(editor.main.renderedImageRect(at: editor.imageAnchor(onLineOf: "![Chart")))
            let point = CGPoint(x: rect.maxX + 6, y: rect.midY)
            let moved = CGPoint(x: point.x + travel, y: point.y)
            var events = [try editor.mouseEvent(.leftMouseDragged, at: moved)]
            if cancel {
                events.append(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: editor.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            } else { events.append(try editor.mouseEvent(.leftMouseUp, at: moved)) }
            let handled = editor.main.routeMouseDownToBlocks(try editor.mouseEvent(.leftMouseDown, at: point)) {
                #expect(editor.main.string == source, "preview never edits characters")
                expectSelection(initial)
                return events.isEmpty ? nil : events.removeFirst()
            }
            #expect(handled)
        }
        try await resize(travel: 40)
        #expect(editor.main.string == changed)
        expectSelection(mapped)
        #expect(editor.state.undo.undoActionName == "Resize Image")
        editor.state.undo.undo()
        #expect(editor.main.string == source)
        expectSelection(initial)
        editor.state.undo.redo()
        #expect(editor.main.string == changed)
        expectSelection(mapped)
        editor.state.undo.undo()
        expectSelection(initial)
        let undoAvailable = editor.state.undo.canUndo
        try await resize(travel: 40, cancel: true)
        #expect(editor.main.string == source)
        expectSelection(initial)
        #expect(editor.state.undo.canUndo == undoAvailable)
        try await resize(travel: 0)
        #expect(editor.main.string == source)
        expectSelection(initial)
        #expect(editor.state.undo.canUndo == undoAvailable)
    }

    @Test("source edits cancel crop and the resize handles expose incremental accessibility actions")
    func transientLifecycleAndAccessibility() async throws {
        let editor = try MountedImageEditor(source: "![Chart|336](wide.png)\nAfter", images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        let token = try editor.imageToken(onLineOf: "![")
        editor.main.setSelectedRange(token.range)
        let controls = try #require(editor.coordinator.imageControls)
        controls.beginCrop()
        #expect(controls.cropView != nil)
        editor.type("x")
        #expect(controls.cropView == nil)
        editor.state.undo.undo()
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![").range)
        controls.refresh()
        let image = try #require(editor.main.renderedImageRect(at: editor.imageAnchor(onLineOf: "![")))
        editor.main.mouseMoved(with: try editor.mouseEvent(.mouseMoved, at: CGPoint(x: image.maxX + 100, y: image.midY)))
        try? await Task.sleep(for: .milliseconds(300))
        let bar = try #require(editor.main.accessibilityChildren()?.compactMap { $0 as? NSView }.first { $0.accessibilityLabel() == "Resize image controls" })
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        let handle = try #require(bar.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(handle.accessibilityPerformIncrement())
        #expect(editor.coordinator.selectedImageTarget()?.tokens.width == 346)
        #expect(handle.accessibilityPerformDecrement())
        #expect(editor.coordinator.selectedImageTarget()?.tokens.width == 336)
    }

    @Test("resize accessibility describes and edits the selected image while another image is hovered")
    func accessibilityTargetIgnoresOtherHover() async throws {
        let editor = try MountedImageEditor(source: "![First|336](wide.png)\n\n![Second|160](wide.png)\nAfter", images: ["wide.png": TestImages.solid(CGSize(width: 640, height: 400))])
        defer { editor.close() }
        await editor.settle()
        editor.main.setSelectedRange(try editor.imageToken(onLineOf: "![First").range)
        let controls = try #require(editor.coordinator.imageControls)
        controls.refresh()
        let second = try editor.imageCenter(onLineOf: "![Second")
        editor.main.mouseMoved(with: try editor.mouseEvent(.mouseMoved, at: second))
        let group = try #require(editor.main.accessibilityChildren()?.compactMap { $0 as? NSView }.first { $0.accessibilityLabel() == "Resize image controls" })
        #expect(!group.isHiddenOrHasHiddenAncestor)
        let handle = try #require(group.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect((handle.accessibilityValue() as? NSNumber)?.intValue == 336)
        #expect(handle.accessibilityPerformIncrement())
        #expect(editor.main.string == "![First|346](wide.png)\n\n![Second|160](wide.png)\nAfter")
    }

}
