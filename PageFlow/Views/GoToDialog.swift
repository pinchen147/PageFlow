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
    /// Takes the typed text as is instead of a number (an EPUB's print page
    /// labels, like "iv"); same contract as `onSubmit`.
    var onSubmitText: ((String) -> String?)?

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
        if let onSubmitText {
            if let failure = onSubmitText(input) {
                error = failure
            } else {
                dismiss()
            }
            return
        }
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
