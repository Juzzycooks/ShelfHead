import SwiftUI

/// Manual-entry recovery path (addendum §2.1 Option B). Reached from
/// `WatchAccountView` regardless of whether the phone is reachable — the one
/// recovery option that works with no phone nearby at all, which is the entire
/// reason it exists alongside the handoff path rather than instead of it.
///
/// Per the addendum's threat model (§3) and `WatchAudiobookshelfAPI.login(_:)`'s own
/// doc comment: the password typed here is used for exactly one HTTPS request and
/// never persisted — only the resulting access/refresh tokens are saved to this
/// Watch's Keychain. Nothing in this view needs to enforce that itself; it falls out
/// of `login(_:)`'s own implementation already not writing `.password` anywhere.
struct WatchManualSignInView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Non-nil while the plain-HTTP gate is waiting for an answer — holds the
    /// normalised URL so the alert can name the host it's about to send credentials
    /// to in the clear. See `WatchStore.signInGate(rawServerURL:acknowledgedInsecureConnection:)`.
    @State private var insecureURLAwaitingConfirmation: String?

    private var canSubmit: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://abs.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
            }
            Section("Account") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            if let errorMessage {
                // Critique 2026-10-06 (colorize): alert glyph, cream sentence.
                WatchAlertNotice(text: .verbatim(errorMessage), font: WatchMetrics.secondaryFont())
            }
            Button {
                Task { await signIn() }
            } label: {
                if isSubmitting {
                    // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                    // falling back to the system tint.
                    ProgressView().tint(WatchTheme.accent)
                } else {
                    Text("Sign In")
                }
            }
            .disabled(!canSubmit)
        }
        .navigationTitle("Sign In")
        // Plain-HTTP gate (review HIGH, 9 September 2026). A confirmation alert is the
        // smallest form that fits this screen — the phone shows the same choice as an
        // alert too (`AuthViewModel.acknowledgedInsecureConnection`), and a Watch
        // `Form` has nowhere sensible to put a persistent warning row that the user
        // would still have to act on. Answering it once per server is remembered
        // (`WatchStore.rememberInsecureAcknowledgement`), so this doesn't nag.
        .alert("Unencrypted Connection", isPresented: Binding(
            get: { insecureURLAwaitingConfirmation != nil },
            set: { if !$0 { insecureURLAwaitingConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) { insecureURLAwaitingConfirmation = nil }
            Button("Continue") {
                insecureURLAwaitingConfirmation = nil
                Task { await signIn(acknowledgingInsecureConnection: true) }
            }
        } message: {
            Text("\(insecureURLAwaitingConfirmation ?? String(localized: "This server")) isn't using HTTPS. Your username, password, and library could be read by others on the network.")
        }
    }

    private func signIn(acknowledgingInsecureConnection: Bool = false) async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await store.loginManually(
                serverURL: serverURL.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                acknowledgedInsecureConnection: acknowledgingInsecureConnection
            )
            dismiss()
        } catch WatchSignInGateRefusal.insecureConnectionNotAcknowledged(let cleanURL) {
            // Not a failure to report — nothing has been sent yet. Ask, then retry
            // this same sign-in with the answer.
            insecureURLAwaitingConfirmation = cleanURL
        } catch {
            // `store.authFailureMessage` was already set (with the right
            // per-cause text — see `WatchStore.WatchAuthFailureReason`) by
            // `loginManually` itself before it rethrew; read it back rather than
            // deriving a second message from the raw error here.
            errorMessage = store.authFailureMessage ?? String(localized: "Sign in failed. Please try again.")
        }
    }
}

#Preview {
    NavigationStack { WatchManualSignInView() }
        .environment(WatchStore.shared)
}
