import SwiftUI

/// Batch 457: the full-screen picture picker. One big tile per saved account: a child's own symbol and colour, a
/// person glyph for a grown-up. Tapping a tile switches to that account. When a child account exists, switching to
/// a grown-up's needs the parent's Face ID or passcode (`ParentGate`). Shown at launch only when the user turned on
/// "Show profile picker at launch" (default off).
struct ProfilePickerView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    /// Called when the picker should go away (a switch finished, or the current account was chosen).
    var onFinish: () -> Void

    @State private var isSwitching = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 24)]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    Text("Who's listening?")
                        .scaledFont(28, weight: .bold, design: .rounded, relativeTo: .largeTitle)
                        .padding(.top, 48)
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(authViewModel.accounts) { account in
                            tile(for: account)
                        }
                    }
                    .padding(.horizontal, 24)
                    if let message {
                        Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 40)
            }
            if isSwitching { ProgressView().controlSize(.large) }
        }
        .task { await authViewModel.loadAccounts() }
    }

    private func tile(for account: ServerAccount) -> some View {
        let kid = KidProfileStore.standard.profile(for: account.id)
        return Button { Task { await choose(account) } } label: {
            VStack(spacing: 10) {
                KidAvatarView(symbol: kid?.symbol ?? KidAvatar.adultSymbol,
                              colorIndex: kid?.colorIndex ?? KidAvatar.defaultColorIndex(for: account.id),
                              size: 112)
                Text(verbatim: account.username)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: account.displayHost)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: account.username))
        .accessibilityHint(Text(kid == nil ? "Switches to this account" : "Switches to this child's account"))
    }

    private func choose(_ account: ServerAccount) async {
        message = nil
        // Review 2 High 1 (30 October 2026): the picker gates every grown-up tile while a child profile is saved,
        // including the active account's. `switchAccount` is then told the check is done, so it doesn't ask twice.
        let gated = ParentGate.pickerNeedsGate(target: account.id)
        if gated {
            let ok = await ParentGate.authenticate(reason: String(localized: "Open a grown-up's account", comment: "Reason shown in the Face ID / passcode prompt when leaving a child's profile"))
            guard ok else { return }
        }
        if account.id == AccountStore.currentAccountId, authViewModel.isAuthenticated {
            KidProfileCoordinator.applyProfile(forAccountId: account.id)
            onFinish()
            return
        }
        isSwitching = true
        defer { isSwitching = false }
        let outcome = await authViewModel.switchAccount(account, parentGateChecked: gated)
        switch outcome {
        case .switched:
            KidProfileCoordinator.applyProfile(forAccountId: account.id)
            onFinish()
        case .needsPassword:
            message = String(localized: "This account needs its password. Sign in from Settings.")
        case .awaitingInsecureConfirmation, .cancelled:
            break
        case .failed(let failure):
            if case .signInFailed(let text) = failure.reason { message = text } else { message = authViewModel.errorMessage }
        }
    }
}
