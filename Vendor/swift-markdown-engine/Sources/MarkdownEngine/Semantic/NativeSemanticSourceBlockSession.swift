import AppKit
import SwiftUI

/// Fenced code and display math retain the source editor and styling they used
/// before prose adopted semantic storage. The mounted editor owns its source.
@MainActor
final class NativeSemanticSourceBlockSession: NSObject {
    static let attribute = NSAttributedString.Key("MarkdownEngine.sourceBlockSession")
    let id: UUID
    let controller = MarkdownEditorController()
    private(set) var source: String
    private(set) var coordinator: NativeTextViewCoordinator!
    private(set) var scroll: NSScrollView!
    private var wrapper: NativeTextViewWrapper!
    private var observers: [NSObjectProtocol] = []
    private var copyButton: NSButton?
    private var measuring = false
    private var awaitingInputSettlement = false
    var onChange: (() -> Void)?
    var onFocus: ((NSView) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onInputSettled: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var height: CGFloat = 48
    var textView: NativeTextView { scroll.nativeTextView! }
    var protectedInput: Bool { textView.hasMarkedText() || textView.isSettingMarkedText || textView.isCommittingMarkedText || coordinator.isWritingToolsActive }

    init(id: UUID, source: String, configuration: MarkdownEditorConfiguration, font: NSFont, undoManager: UndoManager?) {
        self.id = id
        self.source = source
        super.init()
        var config = configuration
        config.readingWidth = nil
        config.textInsets = .init(horizontal: 0, vertical: 0)
        config.scrollers = .hidden
        config.safeAreaInsets = .init()
        config.overscroll = .init(percent: 0, maxPoints: 0, minPoints: 0)
        config.showsSelectionBar = false
        wrapper = NativeTextViewWrapper(text: Binding(get: { [weak self] in self?.source ?? "" }, set: { [weak self] value in
            guard let self, !self.source.utf16.elementsEqual(value.utf16) else { return }
            self.source = value
            self.onChange?()
            self.scheduleMeasure()
        }), configuration: config, fontName: font.fontName, fontSize: font.pointSize,
           documentId: id.uuidString, onCodeBlockSelectionChange: { [weak self] selections in
               self?.copyButton?.isHidden = selections.isEmpty
           }, editorController: controller, undoManager: undoManager,
           onRequestFocus: { [weak self] in guard let self else { return }; self.onFocus?(self.textView) })
        coordinator = wrapper.makeCoordinator()
        scroll = wrapper.makeNativeView(coordinator: coordinator)
        scroll.setAccessibilityLabel("Code or equation block")
        observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSelectionChange?(); self?.scheduleMeasure() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.protectedInput else { return }
                self.source = self.textView.string
                self.onChange?()
                self.scheduleMeasure()
            }
        })
        if case .code(let language, _, _)? = (try? SemanticMarkdownImport.decode(source))?.blocks.first?.content {
            let button = NSButton(title: language?.uppercased() ?? "", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")!, target: self, action: #selector(copyCode))
            button.bezelStyle = .accessoryBarAction
            button.setAccessibilityLabel("Copy code")
            button.sizeToFit()
            copyButton = button
            scroll.addSubview(button)
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func committedSource() -> String {
        protectedInput ? source : textView.string
    }

    func content() -> SemanticMarkdownBlock.Content {
        let value = committedSource()
        guard let document = try? SemanticMarkdownImport.decode(value), document.blocks.count == 1 else {
            return .opaque(value)
        }
        switch document.blocks[0].content {
        case .math, .code: return document.blocks[0].content
        default: return .opaque(value)
        }
    }

    func updateConfiguration(_ configuration: MarkdownEditorConfiguration, font: NSFont) {
        guard !protectedInput else { return }
        var config = configuration
        config.readingWidth = nil
        config.textInsets = .init(horizontal: 0, vertical: 0)
        config.scrollers = .hidden
        config.safeAreaInsets = .init()
        config.overscroll = .init(percent: 0, maxPoints: 0, minPoints: 0)
        config.showsSelectionBar = false
        wrapper.configuration = config
        wrapper.fontName = font.fontName
        wrapper.fontSize = font.pointSize
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        scheduleMeasure()
    }

    func adopt(source: String) {
        guard !protectedInput, !committedSource().utf16.elementsEqual(source.utf16) else { return }
        self.source = source
        wrapper.updateNativeView(scroll, coordinator: coordinator)
    }

    func mount(in parent: NativeSemanticTextView, rect: NSRect) {
        if scroll.superview !== parent { parent.addSubview(scroll) }
        scroll.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        textView.isEditable = parent.isEditable
        copyButton?.frame.origin = NSPoint(x: max(0, scroll.bounds.width - (copyButton?.frame.width ?? 0) - 8), y: 6)
        measure()
    }

    @objc private func copyCode() {
        guard case .code(_, let body, _) = content() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    func detach() {
        NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
        scroll.removeFromSuperview()
    }

    func scheduleMeasure() {
        awaitingInputSettlement = awaitingInputSettlement || protectedInput
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measure()
            if self.awaitingInputSettlement && !self.protectedInput {
                self.awaitingInputSettlement = false
                self.onInputSettled?()
            }
        }
    }

    func measure() {
        guard !measuring, scroll.frame.width > 0 else { return }
        measuring = true
        defer { measuring = false }
        textView.ensureWholeNoteLayoutUnlessLong()
        let measured = max(32, ceil(textView.textLayoutManager?.usageBoundsForTextContainer.height ?? 32) + 8)
        guard abs(height - measured) > 0.5 else { return }
        height = measured
        scroll.frame.size.height = measured
        onResize?(measured)
    }
}

extension NativeSemanticTextView {
    func refreshSemanticSourceBlocks() {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        var mounted: Set<ObjectIdentifier> = []
        storage.enumerateAttribute(NativeSemanticSourceBlockSession.attribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let session = value as? NativeSemanticSourceBlockSession,
                  let location = content.location(content.documentRange.location, offsetBy: range.location) else { return }
            mounted.insert(ObjectIdentifier(session.scroll))
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            session.onSelectionChange = { [weak semanticCoordinator] in semanticCoordinator?.onSelectionChange?() }
            session.onFocus = { [weak semanticCoordinator] view in
                semanticCoordinator?.onRequestFocus?()
                semanticCoordinator?.preferredInputView = view
            }
            session.mount(in: self, rect: NSRect(x: textContainerOrigin.x, y: fragment.layoutFragmentFrame.minY + textContainerOrigin.y,
                                                width: textContainer?.size.width ?? bounds.width, height: session.height))
        }
        for child in subviews.compactMap({ $0 as? NSScrollView }) where child.accessibilityLabel() == "Code or equation block" {
            if !mounted.contains(ObjectIdentifier(child)) { child.removeFromSuperview() }
        }
    }
}
