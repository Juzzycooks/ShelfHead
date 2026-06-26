import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var focusedField: Field?

    enum Field {
        case serverURL, username, password
    }

    var body: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer()
                        .frame(height: 60)

                    // Logo & Branding
                    VStack(spacing: 12) {
                        Image(systemName: "headphones.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.shelfAmber, Color.shelfAmber.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text("ShelfHead")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("Your audiobook companion")
                            .font(.subheadline)
                            .foregroundColor(Color.shelfMuted)
                    }

                    // Login Form
                    VStack(spacing: 16) {
                        // Server URL
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server URL")
                                .font(.caption)
                                .foregroundColor(Color.shelfMuted)

                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(Color.shelfMuted)
                                TextField("https://your-server.com", text: $serverURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .focused($focusedField, equals: .serverURL)
                            }
                            .padding()
                            .background(Color.shelfCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focusedField == .serverURL ? Color.shelfAmber : Color.clear, lineWidth: 1)
                            )
                        }

                        // Username
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Username")
                                .font(.caption)
                                .foregroundColor(Color.shelfMuted)

                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundColor(Color.shelfMuted)
                                TextField("Username", text: $username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .username)
                            }
                            .padding()
                            .background(Color.shelfCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focusedField == .username ? Color.shelfAmber : Color.clear, lineWidth: 1)
                            )
                        }

                        // Password
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.caption)
                                .foregroundColor(Color.shelfMuted)

                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(Color.shelfMuted)

                                if showPassword {
                                    TextField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .focused($focusedField, equals: .password)
                                } else {
                                    SecureField("Password", text: $password)
                                        .focused($focusedField, equals: .password)
                                }

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                        .foregroundColor(Color.shelfMuted)
                                }
                            }
                            .padding()
                            .background(Color.shelfCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(focusedField == .password ? Color.shelfAmber : Color.clear, lineWidth: 1)
                            )
                        }

                        // Error Message
                        if let error = authViewModel.errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(.vertical, 8)
                        }

                        // Login Button
                        Button {
                            Task {
                                await authViewModel.login(
                                    serverURL: serverURL,
                                    username: username,
                                    password: password
                                )
                            }
                        } label: {
                            HStack {
                                if authViewModel.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Connect")
                                        .fontWeight(.semibold)
                                }
                            }
                            .shelfButtonStyle()
                        }
                        .disabled(!isFormValid || authViewModel.isLoading)
                        .opacity(isFormValid ? 1 : 0.6)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
        }
        .onSubmit {
            switch focusedField {
            case .serverURL:
                focusedField = .username
            case .username:
                focusedField = .password
            case .password:
                if isFormValid {
                    Task {
                        await authViewModel.login(
                            serverURL: serverURL,
                            username: username,
                            password: password
                        )
                    }
                }
            case .none:
                break
            }
        }
    }

    private var isFormValid: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }
}

#Preview {
    LoginView()
        .environment(AuthViewModel())
}
