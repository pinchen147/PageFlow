//
//  PasswordDialogView.swift
//  PageFlow
//
//  SwiftUI password dialog for protected PDFs
//

import SwiftUI

struct PasswordDialogView: View {
    let fileName: String
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    @State private var password = ""
    @State private var showError = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            Image(systemName: "lock.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Password Required")
                .font(.headline)

            Text("Enter password for \"\(fileName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: DesignTokens.textFieldWidth + 60)
                .focused($isPasswordFocused)
                .onSubmit { submitPassword() }

            if showError {
                Text("Incorrect password")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: DesignTokens.spacingSM) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open") {
                    submitPassword()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(DesignTokens.spacingLG)
        .frame(width: DesignTokens.dialogWidth + 20)
        .onAppear {
            isPasswordFocused = true
        }
    }

    private func submitPassword() {
        if onSubmit(password) {
            // Success - dialog will be dismissed by parent
        } else {
            showError = true
            password = ""
        }
    }
}

#Preview {
    PasswordDialogView(
        fileName: "Sample.pdf",
        onSubmit: { _ in false },
        onCancel: {}
    )
}
