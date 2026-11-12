import AppKit

extension NativeTextView {
    // Direct responder actions use the same structural owners as keyboard commands.
    // Owners redispatch native steps under their existing navigation guards.
    private func routeRichCharacterMovement(_ selector: Selector) -> Bool {
        guard let owner = delegate as? NativeTextViewCoordinator,
              !owner.emphasisEditor.navigating, owner.listEditor.navigation == nil,
              owner.pendingTableEntry == nil else { return false }
        return owner.textView(self, doCommandBy: selector)
    }

    override func moveForward(_ sender: Any?) {
        if !routeRichCharacterMovement(#selector(NSResponder.moveForward(_:))) { super.moveForward(sender) }
    }

    override func moveBackward(_ sender: Any?) {
        if !routeRichCharacterMovement(#selector(NSResponder.moveBackward(_:))) { super.moveBackward(sender) }
    }

    override func moveLeft(_ sender: Any?) {
        if !routeRichCharacterMovement(#selector(NSResponder.moveLeft(_:))) { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if !routeRichCharacterMovement(#selector(NSResponder.moveRight(_:))) { super.moveRight(sender) }
    }
}
