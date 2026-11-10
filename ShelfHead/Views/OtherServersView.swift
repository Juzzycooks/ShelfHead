import SwiftUI
import UIKit

/// Opens `item` through the app's own `shelfhead://book/<id>` deep link — the same route
/// `ContentView`'s root routing already handles, including App Lock — but only once
/// `account` is actually current. Shared by every "tap a book on another server" path
/// (the Home shelf and the See-all screen), through `ServerSwitchFlow`.
@MainActor
private func openBookIfCurrent(_ item: LibraryItem, on account: ServerAccount, authViewModel: AuthViewModel) {
    guard authViewModel.currentAccountId == account.id,
          let url = URL(string: "shelfhead://book/\(item.id)") else { return }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
}

/// Critique 2026-10-06 (harden): the one confirmation shown wherever ShelfHead switches the
/// signed-in server — Settings > Servers, the Home "On Other Servers" shelf, and this
/// screen's book rows and "Sign in to browse this server" row. A switch stops playback and
/// clears Up Next (`AuthViewModel.tearDownAccountScopedState`), so it names the server and,
/// when a book is loaded, says that book stops. The position itself is saved by the
/// switch's flush. No "Are you sure" (DESIGN.md voice). Pure, pinned by
/// `ServerSwitchConfirmationTests`.
enum ServerSwitchConfirmation {
    static func title(host: String) -> String {
        String(localized: "Switch to \(host)?", comment: "Confirmation title before switching servers; %@ is the server host")
    }

    /// "Switch & Open" when the switch also opens a book on that server, else "Switch".
    static func confirmButton(opensBook: Bool) -> String {
        opensBook ? String(localized: "Switch & Open", comment: "Confirmation button: switch servers and open a book on it")
            : String(localized: "Switch", comment: "Confirmation button: switch to another saved server")
    }

    /// What the switch interrupts, or nil when nothing is loaded (the title says enough).
    static func message(currentBookTitle: String?) -> String? {
        guard let raw = currentBookTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String(localized: "\u{201C}\(raw)\u{201D} stops and Up Next is cleared. Your place in it is saved.", comment: "Server switch confirmation body; %@ is the title of the loaded book")
    }

    /// Critique 2026-10-06 (harden): what the surface that started a switch does next with
    /// `AuthViewModel.switchAccount`'s result. Pure, pinned by `ServerSwitchOutcomeTests`.
    enum FollowUp: Equatable {
        /// Switched, or the SSO sheet was closed (nothing changed): nothing to show.
        case none
        /// Nothing stored to sign in with: Add Server, prefilled, asking for the password.
        case askForPassword
        /// The plain-HTTP gate is up: this surface's own Insecure Connection alert.
        case confirmInsecureConnection
        case showFailure(AuthViewModel.AccountSwitchFailure)
    }

    static func followUp(for outcome: AuthViewModel.AccountSwitchOutcome) -> FollowUp {
        switch outcome {
        case .switched, .cancelled: return .none
        case .needsPassword: return .askForPassword
        case .awaitingInsecureConfirmation: return .confirmInsecureConnection
        case .failed(let failure): return .showFailure(failure)
        }
    }
}

/// Critique 2026-10-06 (harden + clarify): what a failed server switch says, where it was
/// started. Built on `ServerConnectionRules.failureAdvice` (the Add Server test's wording)
/// for an unreachable server, and always says which server you're on now and whether the
/// book stopped. Pure, pinned by `ServerSwitchOutcomeTests`.
enum ServerSwitchFailureCopy {
    static func title(host: String) -> String {
        String(localized: "Couldn\u{2019}t Switch to \(host)", comment: "Alert title when switching servers failed; %@ is the server host")
    }

    /// Why it failed and what to do, in one or two sentences.
    static func reason(_ reason: AuthViewModel.AccountSwitchFailure.Reason) -> String {
        switch reason {
        case .signInFailed(let message):
            return message
        case .unreachable(let failure, let resolvedURL):
            // `failureAdvice` is written for the Add Server form; two of its next steps
            // point at that form ("test again", "try plain http instead"), which a switch
            // to a saved server can't act on, so those two are worded for here.
            let advice = ServerConnectionRules.failureAdvice(failure: failure, resolvedURL: resolvedURL,
                                                            triedPlainHTTP: false)
            switch failure {
            case .offline:
                return advice.message + " " + String(localized: "Connect to Wi-Fi or mobile data, then try again.")
            case .secureConnection:
                return advice.message + " " + String(localized: "If its certificate changed or expired, iOS won\u{2019}t trust it until that\u{2019}s fixed on the server.")
            default:
                return advice.message + " " + advice.nextStep
            }
        }
    }

    /// The alert body: the reason, then where that leaves the user.
    static func message(_ failure: AuthViewModel.AccountSwitchFailure) -> String {
        var text = reason(failure.reason)
        guard let current = failure.currentHost else { return text }
        if failure.stoppedPlayback {
            if let book = failure.stoppedBookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
                text += " " + String(localized: "You\u{2019}re still on \(current). \u{201C}\(book)\u{201D} stopped and Up Next was cleared; your place in it is saved.", comment: "Server switch failure body; first %@ is the current server host, second the stopped book's title")
            } else {
                text += " " + String(localized: "You\u{2019}re still on \(current). Up Next was cleared.", comment: "Server switch failure body; %@ is the current server host")
            }
        } else {
            text += " " + String(localized: "Nothing changed. You\u{2019}re still on \(current).", comment: "Server switch failure body; %@ is the current server host")
        }
        return text
    }

    /// One line for the first-run sign-in screen's saved servers, where nobody is signed in.
    static func inlineMessage(_ failure: AuthViewModel.AccountSwitchFailure) -> String {
        String(localized: "Couldn\u{2019}t sign in to \(failure.targetHost).", comment: "Inline sign-in failure; %@ is the server host. A reason sentence follows.") + " " + reason(failure.reason)
    }
}

/// Critique 2026-10-06 (harden): one server-switch flow for every surface that switches
/// from a saved server (Settings > Servers, the Home shelf, Other Servers). It asks the
/// right question first (a server with nothing stored to sign in with opens a prefilled
/// sign-in instead of a "Switch" that can't work), runs the switch, and shows what came of
/// it on the screen that started it. Presented by `.serverSwitchFlow(_:)`.
@MainActor
@Observable
final class ServerSwitchFlow {
    struct Target: Identifiable {
        let account: ServerAccount
        /// The book to open once switched (Home shelf / Other Servers book rows).
        let item: LibraryItem?
        var id: String { account.id }
    }

    /// Showing the "Switch to …?" confirmation.
    var confirming: Target?
    /// Showing this surface's Insecure Connection alert.
    var allowingInsecure: Target?
    /// Showing Add Server, prefilled with this server and username.
    var reauthenticating: Target? {
        didSet { if let reauthenticating { openAfterReauthentication = reauthenticating } }
    }
    var failure: AuthViewModel.AccountSwitchFailure?
    /// The insecure-connection choice didn't reach the Keychain (Item 4).
    var acknowledgementFailed = false
    /// The server being switched to, for the row's spinner; every switch row is disabled
    /// while it's set (LS-4).
    private(set) var switchingAccountId: String?

    @ObservationIgnored private var openAfterReauthentication: Target?

    /// A saved server was tapped.
    func start(_ account: ServerAccount, item: LibraryItem? = nil, authViewModel: AuthViewModel) {
        guard switchingAccountId == nil else { return }
        Task {
            let method = await authViewModel.reauthenticationMethod(for: account)
            switch AuthViewModel.switchEntry(for: method) {
            case .confirmSwitch: confirming = Target(account: account, item: item)
            case .askForPassword: reauthenticating = Target(account: account, item: item)
            }
        }
    }

    func confirm(_ target: Target, authViewModel: AuthViewModel) {
        confirming = nil
        run(target, authViewModel: authViewModel) { await authViewModel.switchAccount(target.account) }
    }

    func allowInsecure(_ target: Target, authViewModel: AuthViewModel) {
        allowingInsecure = nil
        run(target, authViewModel: authViewModel) { [weak self] in
            let result = await authViewModel.confirmInsecureConnectionAndSwitch(target.account)
            // Said only once connected; a failure has its own alert.
            if result.outcome == .switched { self?.acknowledgementFailed = !result.acknowledged }
            return result.outcome
        }
    }

    /// The prefilled Add Server sheet closed: open the book if its sign-in switched.
    func reauthenticationEnded(authViewModel: AuthViewModel) {
        defer { openAfterReauthentication = nil }
        guard let target = openAfterReauthentication, let item = target.item else { return }
        openBookIfCurrent(item, on: target.account, authViewModel: authViewModel)
    }

    private func run(_ target: Target, authViewModel: AuthViewModel,
                     _ body: @escaping @MainActor () async -> AuthViewModel.AccountSwitchOutcome) {
        switchingAccountId = target.account.id
        Task {
            let outcome = await body()
            switchingAccountId = nil
            switch ServerSwitchConfirmation.followUp(for: outcome) {
            case .none:
                if outcome == .switched, let item = target.item {
                    openBookIfCurrent(item, on: target.account, authViewModel: authViewModel)
                }
            case .askForPassword:
                reauthenticating = target
            case .confirmInsecureConnection:
                // This surface owns the prompt (UX-4): clear the shared flag so no other
                // presenter (the Add Server sheet's own alert) picks it up.
                authViewModel.pendingInsecureConnection = nil
                allowingInsecure = target
            case .showFailure(let failure):
                self.failure = failure
            }
        }
    }
}

/// Presents a `ServerSwitchFlow`: the switch confirmation, the Insecure Connection alert,
/// the prefilled Add Server sheet, and the failure alert.
private struct ServerSwitchFlowModifier: ViewModifier {
    @Bindable var flow: ServerSwitchFlow
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel

    init(flow: ServerSwitchFlow) {
        _flow = Bindable(wrappedValue: flow)
    }

    func body(content: Content) -> some View {
        content
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .confirmationDialog(
                flow.confirming.map { ServerSwitchConfirmation.title(host: $0.account.displayHost) } ?? "",
                isPresented: Binding(get: { flow.confirming != nil }, set: { if !$0 { flow.confirming = nil } }),
                titleVisibility: .visible,
                presenting: flow.confirming
            ) { target in
                Button(ServerSwitchConfirmation.confirmButton(opensBook: target.item != nil)) {
                    flow.confirm(target, authViewModel: authViewModel)
                }
                Button("Cancel", role: .cancel) { flow.confirming = nil }
            } message: { _ in
                if let text = ServerSwitchConfirmation.message(currentBookTitle: playerViewModel.currentBook?.title) {
                    Text(text)
                }
            }
            .systemChromeTint()
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .alert("Insecure Connection", isPresented: Binding(
                get: { flow.allowingInsecure != nil }, set: { if !$0 { flow.allowingInsecure = nil } }
            ), presenting: flow.allowingInsecure) { target in
                Button("Cancel", role: .cancel) { flow.allowingInsecure = nil }
                Button("Allow Insecure Connection", role: .destructive) {
                    flow.allowInsecure(target, authViewModel: authViewModel)
                }
            } message: { _ in
                // Same sentence as Add Server's and Settings' alert (HIG audit L5).
                Text("This connection is unencrypted \u{2014} anyone on the network path could read or alter your data.")
            }
            .systemChromeTint()
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .alert(flow.failure.map { ServerSwitchFailureCopy.title(host: $0.targetHost) } ?? "",
                   isPresented: Binding(get: { flow.failure != nil }, set: { if !$0 { flow.failure = nil } }),
                   presenting: flow.failure) { _ in
                Button("OK", role: .cancel) { flow.failure = nil }
            } message: { failure in
                Text(ServerSwitchFailureCopy.message(failure))
            }
            .systemChromeTint()
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
            .alert("Couldn\u{2019}t Remember That Choice", isPresented: $flow.acknowledgementFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Couldn\u{2019}t save to the Keychain. You\u{2019}re connected, but ShelfHead will ask you to allow this insecure connection again next time you switch to this server.")
            }
            .systemChromeTint()
            .sheet(item: $flow.reauthenticating, onDismiss: {
                flow.reauthenticationEnded(authViewModel: authViewModel)
            }) { target in
                AddServerView(reauthenticating: target.account)
            }
    }
}

extension View {
    /// Critique 2026-10-06 (harden): see `ServerSwitchFlow`.
    func serverSwitchFlow(_ flow: ServerSwitchFlow) -> some View {
        modifier(ServerSwitchFlowModifier(flow: flow))
    }
}

/// A cover for a book on another (not-currently-signed-in) server. Loaded through that
/// server's own private client (`OtherServersStore.coverData`), never the primary
/// account's `AudiobookshelfAPI.shared` — same placeholder look as `CachedCover`.
struct OtherServerCover: View {
    let item: LibraryItem
    let shelf: OtherServersStore.ServerShelf
    var size: CGFloat = 64

    @State private var image: UIImage?
    // Design review 2026-09-23 AN-1: same fade as `CachedCover` (Extensions.swift), but
    // applied locally rather than by reusing that view. `CachedCover`'s network path is
    // hard-wired to `AudiobookshelfAPI.shared` (the currently signed-in account); a cover
    // here belongs to a *different* saved server, fetched through that server's own
    // private client (`OtherServersStore.coverData` → `shelf.client`), so routing this
    // through `CachedCover` would authenticate the wrong server's request and fail.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color.shelfSurface)
                    .overlay(Image(systemName: "book.closed.fill").foregroundStyle(Color.shelfMuted))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        .task(id: item.id) {
            let loaded = await OtherServersStore.shared.coverData(for: item, from: shelf).flatMap(UIImage.init(data:))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                image = loaded
            }
        }
    }
}

/// The Home "On Other Servers" shelf — a horizontal scroller of in-progress books
/// interleaved across every other saved account, each tagged with a host chip.
struct OtherServersShelf: View {
    @State private var store = OtherServersStore.shared
    @Environment(AuthViewModel.self) private var authViewModel
    /// Critique 2026-10-06 (harden): the shared switch flow — confirmation, prefilled
    /// sign-in for a server with no stored password, and the failure alert, all here
    /// where the switch started. Its `switchingAccountId` is LS-4's in-flight state (the
    /// card shows progress and the whole shelf is disabled while a switch runs).
    @State private var flow = ServerSwitchFlow()

    private func shelf(for account: ServerAccount) -> OtherServersStore.ServerShelf? {
        store.shelves.first { $0.id == account.id }
    }

    /// Critique 2026-10-06 (harden): servers that need a sign-in (no stored password, or
    /// SSO) had no card here, so a shelf HomeView shows for them alone was a header over
    /// nothing. Each gets a "Sign in" card after the books.
    private var signInShelves: [OtherServersStore.ServerShelf] {
        store.shelves.filter { $0.state == .needsSignIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                RetroSectionHeader(title: "On Other Servers")
                Spacer(minLength: 8)
                NavigationLink("See all") { OtherServersView() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.shelfAmberText)
            }
            .padding(.horizontal, Space.pageH)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(store.mergedItems.prefix(10)), id: \.item.id) { entry in
                        Button {
                            flow.start(entry.account, item: entry.item, authViewModel: authViewModel)
                        } label: {
                            cardView(entry)
                        }
                        .buttonStyle(.plain)
                        // LS-4: the whole shelf is disabled while any switch is in
                        // flight, not just the row being switched to — avoids a second
                        // overlapping teardown/reload race.
                        .disabled(flow.switchingAccountId != nil)
                    }
                    ForEach(signInShelves) { shelf in
                        Button {
                            flow.start(shelf.account, authViewModel: authViewModel)
                        } label: {
                            signInCard(shelf.account)
                        }
                        .buttonStyle(.plain)
                        .disabled(flow.switchingAccountId != nil)
                    }
                }
                .padding(.horizontal, Space.pageH)
            }
        }
        .serverSwitchFlow(flow)
    }

    @ViewBuilder
    private func cardView(_ entry: (account: ServerAccount, item: LibraryItem)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let shelf = shelf(for: entry.account) {
                    OtherServerCover(item: entry.item, shelf: shelf, size: 96)
                }
                // LS-4: progress on the specific card being switched to.
                if flow.switchingAccountId == entry.account.id {
                    Color.black.opacity(0.35)
                    ProgressView()
                        // LS-13 (docs/design-review.md, Round 3): routed through the
                        // shared brand-tint helper.
                        .shelfSpinner()
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
            Typo.rowTitle(Text(entry.item.title))
                .foregroundStyle(Color.shelfCream)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Typo.rowSubtitle(Text(entry.item.authorName))
                .foregroundStyle(Color.shelfMuted)
                .lineLimit(1)
            hostChip(entry.account.displayHost)
        }
        .frame(width: 96, alignment: .leading)
        // HIG audit 2026-09-17 L7: title, author, and host chip were three separate
        // VoiceOver stops on what's a single tappable card (this is a Button label) —
        // combine them into one, matching `resultMessage`/`serverSummarySection`'s
        // pattern elsewhere in the app.
        .accessibilityElement(children: .combine)
        // LS-4: VoiceOver otherwise has no way to tell the card is mid-switch, since the
        // progress overlay has no label of its own.
        .accessibilityValue(flow.switchingAccountId == entry.account.id ? Text("Switching") : Text(verbatim: ""))
    }

    /// Critique 2026-10-06 (harden): a server that needs a sign-in, as a card the same
    /// size as a book's, so it reads as part of the shelf.
    private func signInCard(_ account: ServerAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.shelfSurface)
                if flow.switchingAccountId == account.id {
                    ProgressView().shelfSpinner()
                } else {
                    Image(systemName: "person.badge.key.fill")
                        .font(.title2)
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
            Typo.rowTitle(Text("Sign in"))
                .foregroundStyle(Color.shelfAmberText)
                .lineLimit(1)
            Typo.rowSubtitle(Text(account.username))
                .foregroundStyle(Color.shelfMuted)
                .lineLimit(1)
            hostChip(account.displayHost)
        }
        .frame(width: 96, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sign in to \(account.displayHost) as \(account.username)")
        .accessibilityValue(flow.switchingAccountId == account.id ? Text("Switching") : Text(verbatim: ""))
    }

    // Critique 2026-10-06 (harden/colour): the host chip is a label, not an action or
    // live state, so it's taupe, not accent (DESIGN.md One Light Rule).
    private func hostChip(_ host: String) -> some View {
        Typo.fine(Text(host), weight: .semibold)
            .foregroundStyle(Color.shelfMuted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.shelfSurface))
    }
}

/// Full "Other Servers" screen — every other saved account's in-progress books,
/// grouped by server, including accounts that need a fresh sign-in.
struct OtherServersView: View {
    @State private var store = OtherServersStore.shared
    @Environment(AuthViewModel.self) private var authViewModel
    /// Critique 2026-10-06 (harden): the shared switch flow (see `OtherServersShelf.flow`).
    /// "Sign in to browse this server" goes through it too, so a server with no stored
    /// password asks for it instead of failing silently.
    @State private var flow = ServerSwitchFlow()

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()

            if store.shelves.isEmpty {
                EmptyStateView(
                    icon: "server.rack",
                    title: LocalizedStringResource("No Other Servers"),
                    subtitle: LocalizedStringResource("Add another server in Settings to browse it here.")
                )
            } else {
                List {
                    ForEach(store.shelves) { shelf in
                        Section {
                            rowContent(for: shelf)
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shelf.account.displayHost)
                                Typo.fine(Text(shelf.account.username))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await store.refresh(currentAccountId: authViewModel.currentAccountId, force: true)
                }
            }
        }
        .navigationTitle("Other Servers")
        .task {
            await store.refresh(currentAccountId: authViewModel.currentAccountId)
        }
        .serverSwitchFlow(flow)
    }

    @ViewBuilder
    private func rowContent(for shelf: OtherServersStore.ServerShelf) -> some View {
        switch shelf.state {
        case .loading:
            ProgressView()
                // LS-13 (docs/design-review.md, Round 3): this shelf's loading
                // spinner previously fell back to the system tint.
                .shelfSpinner()
                .listRowBackground(Color.shelfCard)
        case .ready:
            if shelf.items.isEmpty {
                Text("Nothing in progress on this server.")
                    .foregroundStyle(Color.shelfMuted)
                    .listRowBackground(Color.shelfCard)
            } else {
                ForEach(shelf.items) { item in
                    Button {
                        flow.start(shelf.account, item: item, authViewModel: authViewModel)
                    } label: {
                        bookRow(item: item, shelf: shelf)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.shelfCard)
                    // LS-4: the whole book list is disabled while any switch is in
                    // flight, matching `AccountSecuritySettingsView`'s saved-account list.
                    .disabled(flow.switchingAccountId != nil)
                }
            }
        case .needsSignIn:
            Button {
                // Critique 2026-10-06 (harden): confirm first, like every other switch —
                // or, with no stored password, ask for it (`ServerSwitchFlow.start`).
                flow.start(shelf.account, authViewModel: authViewModel)
            } label: {
                HStack {
                    // Critique 2026-10-06 (polish): on a `shelfCard` row, so the surface-tuned accent.
                    Text("Sign in to browse this server")
                        .foregroundStyle(Color.shelfAmberTextOnSurface)
                    Spacer(minLength: Space.s)
                    if flow.switchingAccountId == shelf.account.id {
                        ProgressView()
                            .shelfSpinner()
                            .accessibilityLabel("Switching account")
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .listRowBackground(Color.shelfCard)
            .disabled(flow.switchingAccountId != nil)
        case .failed(let message):
            Text(message)
                .foregroundStyle(Color.shelfMuted)
                .listRowBackground(Color.shelfCard)
        }
    }

    private func bookRow(item: LibraryItem, shelf: OtherServersStore.ServerShelf) -> some View {
        HStack(spacing: 12) {
            OtherServerCover(item: item, shelf: shelf, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Typo.rowTitle(Text(item.title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)
                Typo.rowSubtitle(Text(item.authorName))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // LS-4: progress on the specific row being switched to, in place of the
            // percentage readout so the row doesn't look ignored while it switches.
            if flow.switchingAccountId == shelf.account.id {
                ProgressView()
                    // LS-13 (docs/design-review.md, Round 3): routed through the
                    // shared brand-tint helper.
                    .shelfSpinner()
                    .accessibilityLabel("Switching account")
            } else if let progress = item.mediaProgress?.progress {
                Typo.supporting(Text("\(Int(progress * 100))%"), weight: .semibold)
                    .foregroundStyle(Color.shelfMuted)
            }
        }
    }
}
