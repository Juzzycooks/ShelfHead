import SwiftUI

/// The first-run sign-in screen, shown by `ContentView` whenever nobody is signed in.
///
/// SB-1 (REVIEW_2026-09-14_DESIGN.md): this used to be its own bespoke screen — a
/// three-step stepper that gated the username/password fields behind a passing `/ping`
/// test — with no OIDC/SSO entry point and no custom-header editor. Both of those lived
/// only in `AddServerView`, which is reachable exclusively from Settings > Account &
/// Security, i.e. behind `authViewModel.isAuthenticated`. A new user whose server is
/// SSO-only, or gated by Cloudflare Access / Authelia / an nginx `auth_request`, could
/// therefore never sign in at all — and the gate made it worse, because such a server
/// answers `/ping` with the proxy's block page, so Step 1 could never go green and the
/// credential fields never appeared.
///
/// Both screens are now the same view (`ServerConnectionView`); the only difference is
/// the chrome around it (`ServerConnectionPurpose`). The connection test and its
/// per-outcome diagnosis — the genuinely valuable half of the old stepper — are kept,
/// and available on the Add Server sheet too.
///
/// Batch 319 (device feedback, 14 Sep 2026) put a gate back in front of the credential
/// fields — they appear only once the test passes — but NOT the old one. The old gate
/// hid the custom-header editor behind the same pass, which is what made a proxy-gated
/// server unsignable-into; that editor now lives in step 1, reachable with no passing
/// test and auto-expanded on the `.notAudiobookshelf` outcome a gate produces — and a
/// failed diagnosis additionally offers an explicit "Sign in anyway" bypass, so a gate
/// that blocks the test no matter what can't lock anyone out. The two steps are also two
/// separate pages rather than one scrolling form, so a passing test lands on a live sign-in
/// page instead of revealing more of the same screen below. See `ServerConnectionView`,
/// `ServerConnectionRules.showsCredentials` and `ServerConnectionRules.resolvedPage`.
///
/// `ServerConnectionView` itself lives in `AddServerView.swift` (see its doc comment for
/// why). Kept as a distinct type here, and constructible with no arguments, because
/// `ContentView` refers to it by name.
struct LoginView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    var body: some View {
        // Polish pass (J1-2): a saved session the server refused at launch opens this screen
        // prefilled with that server and username, saying why — instead of a blank first-run
        // form that reads as "you were never signed in". `.id` rebuilds the form if the
        // prefill arrives while it's already on screen (its fields are `@State`).
        if let prefill = authViewModel.sessionEndedPrefill {
            ServerConnectionView(purpose: .firstRun,
                                 prefillServerURL: prefill.serverURL,
                                 prefillUsername: prefill.username,
                                 prefillHeaders: prefill.customHeaders,
                                 passwordNeededPrompt: prefill.message)
                .id(prefill)
        } else {
            ServerConnectionView(purpose: .firstRun)
        }
    }
}

/// Polish pass (J1-1): "Sign in again", raised over the running app when the server refuses
/// the session mid-use (the refresh token and any stored-password re-login have already
/// been tried). The session stays signed in underneath — the book keeps its place,
/// downloads keep playing and progress keeps queueing — and signing in here only ever
/// renews THIS account (`AuthViewModel.reauthenticateExpiredSession`). Switching to
/// someone else is Settings' job, so the username is shown, not edited.
///
/// Presented by `ContentView` from `authViewModel.sessionExpiredPrompt`. A standard
/// sheet with Not Now as its cancellation action (HIG › Modality: a clear way out).
struct SessionExpiredSheet: View {
    let prompt: AuthViewModel.SessionExpiredPrompt
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var passwordFocused: Bool

    private var isWorking: Bool { authViewModel.isReauthenticating }
    private var canSubmit: Bool { !password.isEmpty && !isWorking }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()
                Form {
                    Section {
                        Typo.supporting(Text("Your session on \(prompt.host) has ended. Sign in again to keep syncing. Your downloads still play.",
                                             comment: "Sign in again sheet; %@ is the server host"))
                            .foregroundStyle(Color.shelfCream)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(Color.shelfCard)

                    if prompt.usesSingleSignOn {
                        ssoSection
                    } else {
                        passwordSection
                    }

                    if let message = authViewModel.reauthErrorMessage {
                        Section {
                            Label {
                                Typo.supporting(Text(message))
                                    .foregroundStyle(Color.shelfCream)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // Batch 490 (REVIEW 2026-11-11 O4): the SSO redirect-URI
                                    // error carries the address to allow; selectable here (the
                                    // sign-in form has a Copy button; this file has no UIKit).
                                    .textSelection(.enabled)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.shelfOrange)
                                    .accessibilityHidden(true)
                            }
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(Text("Sign In Again"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { authViewModel.dismissSessionExpiredPrompt() }
                        .disabled(isWorking)
                        .monochromeToolbarItem()
                }
            }
        }
        // A swipe-down mid-attempt would drop the sheet while the result is still coming.
        .interactiveDismissDisabled(isWorking)
        .onAppear { if !prompt.usesSingleSignOn { passwordFocused = true } }
    }

    private var passwordSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: prompt.username)
                    .foregroundStyle(Color.shelfMuted)
            } label: {
                Text("Username")
            }
            .accessibilityElement(children: .combine)

            HStack {
                if showPassword {
                    TextField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($passwordFocused)
                        .onSubmit(submitPassword)
                } else {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($passwordFocused)
                        .onSubmit(submitPassword)
                }
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
            }
            .disabled(isWorking)

            primaryButton(title: Text("Sign In"), action: submitPassword)
                .disabled(!canSubmit)
                .opacity(canSubmit || isWorking ? 1 : 0.6)
        }
        .listRowBackground(Color.shelfCard)
    }

    private var ssoSection: some View {
        Section {
            primaryButton(title: Text("Sign In with SSO")) {
                Task { await authViewModel.reauthenticateExpiredSessionWithSSO() }
            }
            .disabled(isWorking)
        } footer: {
            Typo.fine(Text("Sign in as \(prompt.username).", comment: "Sign in again sheet, SSO account; %@ is the username"))
                .foregroundStyle(Color.shelfMuted)
        }
        .listRowBackground(Color.shelfCard)
    }

    private func primaryButton(title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if isWorking {
                    ProgressView()
                        .tint(Color.onAccent)
                } else {
                    title.fontWeight(.semibold)
                }
            }
            .shelfButtonStyle()
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func submitPassword() {
        guard canSubmit else { return }
        let typed = password
        Task {
            if await authViewModel.reauthenticateExpiredSession(password: typed) == false {
                passwordFocused = true
            }
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
}
