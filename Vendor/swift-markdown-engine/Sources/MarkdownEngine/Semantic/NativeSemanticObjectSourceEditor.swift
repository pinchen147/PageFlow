import AppKit

@MainActor
final class NativeSemanticObjectSourceEditor: NSViewController {
    let editor = NSTextView()
    var onSave: ((String) -> Bool)?
    var onClose: (() -> Void)?
    private let initialSource: String

    init(source: String) {
        initialSource = source
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        let label = NSTextField(labelWithString: "Edit source")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.frame = NSRect(x: 16, y: 285, width: 468, height: 20)
        view.addSubview(label)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 52, width: 468, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.frame = scroll.contentView.bounds
        editor.autoresizingMask = [.width]
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.string = initialSource
        editor.setAccessibilityLabel("Object source")
        scroll.documentView = editor
        view.addSubview(scroll)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        cancel.frame = NSRect(x: 300, y: 12, width: 88, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Apply", target: self, action: #selector(saveEdit))
        save.frame = NSRect(x: 396, y: 12, width: 88, height: 28)
        save.keyEquivalent = "\r"
        view.addSubview(cancel); view.addSubview(save)
    }

    @objc private func saveEdit() {
        guard !editor.hasMarkedText(), onSave?(editor.string) == true else { return }
        onClose?()
    }
    @objc private func cancelEdit() { onClose?() }
}
