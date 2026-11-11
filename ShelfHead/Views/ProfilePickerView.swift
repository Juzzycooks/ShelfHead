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
    /// Batch 490 (REVIEW 2026-11-11 O5): the same alerts and sheets every other switching
    /// surface uses (Insecure Connection, the prefilled sign-in for a server with no saved
    /// password, the failure alert). The picker still runs the switch itself, so its parent
    /// gate is asked once and the tap needs no extra "Switch to …?" confirmation (picking a
    /// tile on this screen is the choice); only the follow-ups go through the flow.
    @State private var flow = ServerSwitchFlow()
    /// The tile whose switch is still being finished through the flow (a password or an
    /// insecure-connection answer), so the picker closes once that lands.
    @State private var pendingTargetId: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 24)]

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    // Batch 490 (REVIEW 2026-11-11 V4): the page-title role and ink token.
                    Typo.pageTitle(Text("Who's listening?"))
                        .foregroundStyle(Color.shelfCream)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 48)
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(authViewModel.accounts) { account in
                            tile(for: account)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 40)
            }
            if showsSpinner {
                // Batch 490 (REVIEW 2026-11-11 O5): the brand spinner, with a spoken label.
                ProgressView()
                    .controlSize(.large)
                    .shelfSpinner()
                    .accessibilityLabel(Text("Switching account"))
            }
        }
        .task { await authViewModel.loadAccounts() }
        .serverSwitchFlow(flow)
        // Batch 490 (REVIEW 2026-11-11 O5): a switch finished through the flow (Allow on the
        // Insecure Connection alert) or its prefilled sign-in sheet closed: close the picker
        // if it landed on the chosen account.
        .onChange(of: flow.switchingAccountId) { _, new in
            if new == nil { finishIfSwitched() }
        }
        .onChange(of: flow.reauthenticating == nil) { _, closed in
            if closed { finishIfSwitched() }
        }
    }

    private var showsSpinner: Bool { isSwitching || flow.switchingAccountId != nil }

    private func tile(for account: ServerAccount) -> some View {
        let kid = KidProfileStore.standard.profile(for: account.id)
        return Button { Task { await choose(account) } } label: {
            VStack(spacing: 10) {
                KidAvatarView(symbol: kid?.symbol ?? KidAvatar.adultSymbol,
                              colorIndex: kid?.colorIndex ?? KidAvatar.defaultColorIndex(for: account.id),
                              size: 112)
                // Batch 490 (REVIEW 2026-11-11 V4, A5): tokens instead of `.headline`/
                // `.primary`/`.secondary`, and the names wrap rather than truncate at
                // accessibility text sizes.
                Typo.cardTitle(Text(verbatim: account.username))
                    .foregroundStyle(Color.shelfCream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Typo.metadata(Text(verbatim: account.displayHost))
                    .foregroundStyle(Color.shelfMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(showsSpinner)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: account.username))
        .accessibilityHint(Text(kid == nil ? "Switches to this account" : "Switches to this child's account"))
    }

    private func choose(_ account: ServerAccount) async {
        pendingTargetId = nil
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
        // Batch 490 (REVIEW 2026-11-11 O5): was a footnote line ("Sign in from Settings")
        // for a password and the bare error text for a failure, with no Insecure
        // Connection prompt at all. Now the shared flow's alerts and sheets, mapped the
        // same way every other surface maps them (`ServerSwitchConfirmation.followUp`).
        let target = ServerSwitchFlow.Target(account: account, item: nil)
        switch ServerSwitchConfirmation.followUp(for: outcome) {
        case .none:
            if outcome == .switched {
                KidProfileCoordinator.applyProfile(forAccountId: account.id)
                onFinish()
            }
        case .askForPassword:
            pendingTargetId = account.id
            flow.reauthenticating = target
        case .confirmInsecureConnection:
            // This surface owns the prompt (UX-4): clear the shared flag so no other
            // presenter picks it up. The parent gate already passed for this account
            // (`switchAccount` remembers that), so Allow doesn't ask again.
            authViewModel.pendingInsecureConnection = nil
            pendingTargetId = account.id
            flow.allowingInsecure = target
        case .showFailure(let failure):
            flow.failure = failure
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 O5): closes the picker once a switch finished through
    /// the flow has landed on the tile that was chosen.
    private func finishIfSwitched() {
        guard let targetId = pendingTargetId, flow.switchingAccountId == nil else { return }
        guard Self.switchLanded(targetId: targetId, currentAccountId: AccountStore.currentAccountId,
                                isAuthenticated: authViewModel.isAuthenticated) else { return }
        pendingTargetId = nil
        KidProfileCoordinator.applyProfile(forAccountId: targetId)
        onFinish()
    }

    /// Batch 490 (REVIEW 2026-11-11 O5): pure, pinned by `QuickWinsSignInTests`.
    nonisolated static func switchLanded(targetId: String, currentAccountId: String?, isAuthenticated: Bool) -> Bool {
        isAuthenticated && currentAccountId == targetId
    }
}
