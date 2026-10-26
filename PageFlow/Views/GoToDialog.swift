//
//  GoToDialog.swift
//  PageFlow
//
//  The ONE jump-dialog for both content types — "Go to Page" (PDF) and
//  "Go to Line" (Markdown) are the same sheet: headline, a number field,
//  a validation error line, Cancel/Go. The caller supplies the validate+jump
//  closure; the dialog owns input/error state and the dismiss protocol.
//

import SwiftUI

struct GoToDialog: View {
    let title: String
    let prompt: String
    /// Validates + performs the jump for a 1-based number. Return an error
    /// message to keep the sheet open, or nil on success (the dialog closes).
    let onSubmit: (Int) -> String?
    @Binding var isPresented: Bool

    @State private var input = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            Text(title)
                .font(.headline)

            TextField(prompt, text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: DesignTokens.textFieldWidth)
                .onSubmit { submit() }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .pageFlowClickCursor()
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    submit()
                }
                .pageFlowClickCursor()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.spacingLG)
        .frame(width: DesignTokens.dialogWidth)
    }

    private func submit() {
        guard let number = Int(input) else {
            error = "Please enter a valid number."
            return
        }
        if let failure = onSubmit(number) {
            error = failure
            return
        }
        dismiss()
    }

    private func dismiss() {
        isPresented = false
        input = ""
        error = nil
    }
}
