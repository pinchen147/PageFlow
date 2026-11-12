import AppKit

extension NativeSemanticDocumentCoordinator {
    @discardableResult
    func editTableSource(session: NativeSemanticTableSession) -> Bool {
        guard let storage = textView.textStorage else { return false }
        var location: Int?
        storage.enumerateAttribute(NativeSemanticAttributes.tableSession, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? NativeSemanticTableSession) === session { location = range.location; stop.pointee = true }
        }
        guard let location else { return false }
        editObject(at: location)
        return true
    }

    func objectSource(at index: Int) throws -> String? {
        guard let storage = textView.textStorage, index >= 0, index < storage.length else { return nil }
        if let object = storage.attribute(NativeSemanticAttributes.object, at: index, effectiveRange: nil) as? SemanticInlineObject {
            return try SemanticInlineCodec.encode(.init(runs: [.init(object: object)]))
        }
        guard let id = storage.attribute(NativeSemanticAttributes.blockID, at: index, effectiveRange: nil) as? UUID else { return nil }
        var document = snapshot()
        document.blocks = document.blocks.filter { $0.id == id }
        guard document.blocks.count == 1, storage.attribute(NativeSemanticAttributes.blockPayload, at: index, effectiveRange: nil) != nil else { return nil }
        return try SemanticMarkdownImport.export(document).source
    }

    @discardableResult
    func replaceObjectSource(at index: Int, source: String, expectedRevision: UInt64) throws -> Bool {
        guard revision == expectedRevision, textView.isEditable, !hasActiveComposition, !isWritingToolsActive,
              let storage = textView.textStorage, index >= 0, index < storage.length else { return false }
        if storage.attribute(NativeSemanticAttributes.object, at: index, effectiveRange: nil) != nil {
            let inline = try SemanticInlineCodec.decode(source)
            guard inline.runs.count == 1, case .object = inline.runs[0].payload else { return false }
            let replacement = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(inline,
                font: textView.font ?? .systemFont(ofSize: 16)))
            let previous = storage.attributes(at: index, effectiveRange: nil)
            for key in [NativeSemanticAttributes.blockID, NativeSemanticAttributes.paragraphRole,
                        NativeSemanticAttributes.blockLineEnding, NativeSemanticAttributes.objectID] {
                if let value = previous[key] { replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length)) }
            }
            NativeSemanticAttributes.renderObjects(in: replacement, configuration: configuration,
                font: textView.font ?? .systemFont(ofSize: 16), maxWidth: textView.textContainer?.size.width ?? 600)
            return replaceVisible(NSRange(location: index, length: 1), with: replacement, actionName: "Edit Object")
        }
        guard let id = storage.attribute(NativeSemanticAttributes.blockID, at: index, effectiveRange: nil) as? UUID else { return false }
        let imported = try SemanticMarkdownImport.decode(source)
        guard imported.blocks.count == 1 else { return false }
        var document = snapshot()
        guard let position = document.blocks.firstIndex(where: { $0.id == id }) else { return false }
        if case .table(var previous) = document.blocks[position].content {
            guard case .table(let replacement) = imported.blocks[0].content else { return false }
            previous.rows = replacement.rows
            previous.alignments = replacement.alignments
            document.blocks[position].content = .table(previous)
        } else { document.blocks[position].content = imported.blocks[0].content }
        _ = try SemanticMarkdownImport.export(document)
        install(document, selection: textView.selectedRange(), actionName: "Edit Object")
        return true
    }

    func editObject(at index: Int) {
        do {
            guard let source = try objectSource(at: index), textView.isEditable else { return }
            let expected = revision
            let editor = NativeSemanticObjectSourceEditor(source: source)
            let popover = NSPopover()
            popover.contentViewController = editor
            popover.behavior = .semitransient
            editor.onSave = { [weak self] source in
                guard let self else { return false }
                do { return try self.replaceObjectSource(at: index, source: source, expectedRevision: expected) }
                catch { self.onExportFailure?(error); return false }
            }
            editor.onClose = { [weak self, weak popover] in popover?.performClose(nil); self?.objectPopover = nil }
            objectPopover?.performClose(nil)
            objectPopover = popover
            let screen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            let rect = textView.window.map { textView.convert($0.convertFromScreen(screen), from: nil) } ?? .zero
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            textView.window?.makeFirstResponder(editor.editor)
        } catch { onExportFailure?(error) }
    }

    @discardableResult
    func editSelectedImage(_ update: (inout ImageAltTokens) -> Void) -> Bool {
        let range = textView.selectedRange()
        guard let storage = textView.textStorage, range.location < storage.length,
              case .image(let source, let alt, let title)? = storage.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject else { return false }
        var tokens = ImageAltTokens.parse(alt)
        update(&tokens)
        do {
            let inline = SemanticInlineText(runs: [.init(object: .image(source: source, alt: ImageAltTokens.format(tokens), title: title))])
            return try replaceObjectSource(at: range.location, source: SemanticInlineCodec.encode(inline), expectedRevision: revision)
        } catch { onExportFailure?(error); return false }
    }

    func beginImageCrop() {
        let range = textView.selectedRange()
        guard let scroll = textView.enclosingScrollView, let storage = textView.textStorage, range.location < storage.length,
              case .image(let source, let alt, _)? = storage.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject,
              let image = configuration.services.images.image(for: EmbeddedImageRequest(name: source)) else { return }
        let expected = revision
        let crop = ImageCropView(image: image, pixels: image.size, crop: ImageAltTokens.parse(alt).crop) { [weak self, weak scroll] in
            guard let self, let scroll, let window = self.textView.window else { return nil }
            return scroll.convert(window.convertFromScreen(self.textView.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
        }
        crop.onApply = { [weak self] rect in
            guard let self, self.revision == expected else { return }
            self.textView.setSelectedRange(range)
            _ = self.editSelectedImage { $0.crop = rect }
        }
        crop.onClose = { [weak self] _ in self?.imageCropView = nil }
        imageCropView = crop
        crop.present(in: scroll)
    }

    func editImageAltText() {
        let range = textView.selectedRange()
        guard let scroll = textView.enclosingScrollView, let storage = textView.textStorage, range.location < storage.length,
              case .image(_, let alt, _)? = storage.attribute(NativeSemanticAttributes.object, at: range.location, effectiveRange: nil) as? SemanticInlineObject else { return }
        let expected = revision
        let popover = ImageAltTextPopover(text: ImageAltTokens.parse(alt).displayDescription)
        popover.onSave = { [weak self] value in
            guard let self, self.revision == expected else { return }
            self.textView.setSelectedRange(range)
            _ = self.editSelectedImage { $0.description = ImageAltTokens.sanitizedDescription(value) }
        }
        popover.onClose = { [weak self] in self?.imageAltPopover = nil }
        imageAltPopover = popover
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let rect = textView.window.map { scroll.convert($0.convertFromScreen(screen), from: nil) } ?? .zero
        popover.present(in: scroll, imageRect: rect)
    }
}
