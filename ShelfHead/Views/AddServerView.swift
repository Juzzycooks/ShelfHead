import SwiftUI

/// Compact form to add (and switch to) another Audiobookshelf server.
struct AddServerView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var localError: String?

    private var isValid: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                Form {
                    Section {
                        TextField("https://your-server.com", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    } footer: {
                        if let localError {
                            Text(localError).foregroundColor(.red)
                        }
                    }
                    .listRowBackground(Color.shelfCard)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") { connect() }
                        .disabled(!isValid || isConnecting)
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        localError = nil
        Task {
            await authViewModel.login(serverURL: serverURL, username: username, password: password)
            isConnecting = false
            if authViewModel.errorMessage == nil {
                dismiss()
            } else {
                localError = authViewModel.errorMessage
                authViewModel.errorMessage = nil
            }
        }
    }
}
