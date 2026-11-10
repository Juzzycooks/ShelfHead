import SwiftUI

/// Lists the recent mark-finished / mark-unfinished / reset-progress actions recorded
/// by `PlaybackHistoryStore`, with an "Undo" action per row. Only the most recent entry
/// for a given book is actually undoable (see `PlaybackHistoryStore.canUndo`) — older
/// entries for a book that's changed again since are shown for reference but greyed out,
/// rather than silently discarding whatever changed it most recently.
struct PlaybackHistoryView: View {
    var bottomInset: CGFloat = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Critique 2026-10-06 (harden): read so the grouping below re-renders after a switch.
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var history = PlaybackHistoryStore.shared
    @State private var undoingId: UUID?
    @State private var toastMessage: String?
    @State private var showClearConfirm = false
    /// Critique 2026-10-06 (harden): the entry whose Undo just failed, for the failure
    /// alert's Retry. A failed undo used to clear the spinner and say nothing.
    @State private var failedUndo: PlaybackHistoryStore.HistoryEntry?

    /// What a failed undo says: nothing changed, why, and what to do. Pinned by
    /// `HardenCopyTests`.
    static var undoFailureTitle: String { String(localized: "Couldn\u{2019}t Undo") }
    /// Critique 2026-10-06 (clarify): only blames the network when `ReachabilityStore`
    /// says it is down; any other failure (a server error, a decode error) no longer
    /// claims a cause it can't know.
    static func undoFailureMessage(reachability: ReachabilityStore.Status) -> String {
        switch reachability {
        case .offline:
            return String(localized: "This device is offline, so nothing changed. Try again when connected.")
        case .serverUnreachable:
            return String(localized: "Couldn\u{2019}t reach your server, so nothing changed. Try again when connected.")
        case .ok:
            return String(localized: "Couldn\u{2019}t undo this change. Try again.")
        }
    }

    /// The caption on a superseded row, so the reason it can't be undone is visible text
    /// and not 50% opacity. Pinned by a test.
    static var supersededCaption: String { String(localized: "Changed since", comment: "Caption on a history row that can no longer be undone because the book changed again") }

    /// Critique 2026-10-06 (harden): headings and captions for the groups
    /// `PlaybackHistoryStore.sections` makes. Pinned by `PlaybackHistoryScopeTests`.
    static func sectionTitle(for kind: PlaybackHistoryStore.HistorySection.Kind) -> String? {
        switch kind {
        case .current: return nil
        case .otherServer(let host): return String(localized: "On \(host)", comment: "History section header; %@ is a server hostname")
        case .unknownServer: return String(localized: "Server not recorded")
        }
    }

    static func sectionCaption(for kind: PlaybackHistoryStore.HistorySection.Kind) -> String {
        switch kind {
        case .current:
            return String(localized: "Only the most recent action for a book can be undone \u{2014} if something changed it again since, undoing an older entry would just discard that newer change.")
        case .otherServer:
            return String(localized: "Made while signed in to another server. Switch to it in Settings to undo these.")
        case .unknownServer:
            return String(localized: "Recorded before ShelfHead noted which server a change was on, so these can\u{2019}t be undone.")
        }
    }

    static var clearAlertTitle: String { String(localized: "Clear Recent Changes?") }
    static var clearAlertMessage: String { String(localized: "This removes the undo entries listed here. Your books and progress on the server stay as they are.") }

    /// UI-12: this previously always fell back to a flat 88pt regardless of whether a
    /// book was loaded — the one drifted copy of the duplicated `bottomClearance`
    /// calculation the review found (every other page correctly reserved 152pt when
    /// the mini-player was showing). Now routed through the same shared
    /// `bottomBarClearance` helper (Extensions.swift) every other page uses, so this
    /// screen's last row (and its "Undo" tap target — see the UI-12 tap-target fix
    /// above) no longer sits behind the mini-player.
    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                EmptyStateView(
                    icon: "arrow.uturn.backward.circle",
                    title: LocalizedStringResource("No recent actions"),
                    subtitle: LocalizedStringResource("Marking a book finished, unfinished, or resetting its progress shows up here so you can undo it.")
                )
            } else {
                // Critique 2026-10-06 (harden): grouped by server. Only this account's
                // changes can be undone; another server's are listed under "On <host>"
                // without Undo (they used to offer one that could only fail).
                List {
                    ForEach(PlaybackHistoryStore.sections(for: history.entries,
                                                          currentAccountId: authViewModel.currentAccountId)) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(for: entry, in: section.kind)
                            }
                        } header: {
                            if let title = Self.sectionTitle(for: section.kind) {
                                RetroSectionHeader(title: .verbatim(title))
                            }
                        } footer: {
                            Typo.supporting(Text(Self.sectionCaption(for: section.kind)))
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        // Critique 2026-10-06 (harden): named for what it holds (changes you can undo), not
        // listening history. The Settings > Diagnostics row is renamed with it.
        .navigationTitle("Recent Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showClearConfirm = true } label: { Label("Clear", systemImage: "trash") }   // iPhone Duo (§2): titled + symbol
                        // Critique 2026-10-06 (colorize): plain chrome colour (Monochrome
                        // Chrome); the destructive role stays on the alert's confirm button.
                        // (polish) Through the shared nav-bar helper, as every other toolbar
                        // item, rather than a one-off `Color.primary`.
                        .monochromeToolbarItem()
                        .accessibilityHint("Clears this log. Doesn't change any book's progress.")
                }
            }
        }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        // Critique 2026-10-06 (colorize): one tint above, then one systemChromeTint() per
        // presenter (the second stacked .tint(amber) is gone).
        .alert(Self.clearAlertTitle, isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { history.clear() }
        } message: {
            Text(Self.clearAlertMessage)
        }
        .systemChromeTint()
        .alert(Self.undoFailureTitle, isPresented: Binding(
            get: { failedUndo != nil }, set: { if !$0 { failedUndo = nil } }
        ), presenting: failedUndo) { entry in
            Button("Retry") { performUndo(entry) }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text(Self.undoFailureMessage(reachability: ReachabilityStore.shared.status))
        }
        .systemChromeTint()
        .toast(message: $toastMessage, style: .success, bottomInset: bottomInset)
        .reexpandsTabBarOnAppear()
    }

    private func row(for entry: PlaybackHistoryStore.HistoryEntry,
                     in kind: PlaybackHistoryStore.HistorySection.Kind) -> some View {
        let undoable = history.canUndo(entry)
        // "Changed since" is only true of this account's superseded entries; the other
        // groups say why in their caption.
        let superseded = kind == .current && !undoable
        // N-4 (REVIEW_2026-09-14_DESIGN.md): this row had zero accessibility
        // annotations — VoiceOver split it into an unlabelled action icon, the
        // title, and a "label • timestamp" caption as three separate stops, and the
        // only signal that an older entry could no longer be undone was 50% opacity
        // (a color/transparency-only cue). The info portion is now one composed
        // element (title, action, when, plus an explicit "can't be undone" note for
        // superseded entries) via `rowAccessibilityLabel`, kept separate from the
        // Undo button/progress spinner so that control stays independently
        // reachable and actionable (VoiceOver swipe, Switch Control scan, Voice
        // Control target) rather than being swallowed into a combined label.
        //
        // AX Dynamic Type: below `.accessibilitySize`, the title's `.lineLimit(1)`
        // stays (matches the original design at standard sizes); at an accessibility
        // size the row switches to a vertical layout so the title can wrap and the
        // Undo control gets its own row instead of being squeezed into a shrinking
        // trailing slot next to wrapped text.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    historyRowInfo(entry: entry, undoable: undoable, superseded: superseded, kind: kind)
                    historyRowControl(entry: entry, undoable: undoable)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 12) {
                    historyRowInfo(entry: entry, undoable: undoable, superseded: superseded, kind: kind)
                    Spacer()
                    historyRowControl(entry: entry, undoable: undoable)
                }
            }
        }
        // Critique 2026-10-06 (colorize): superseded rows keep full contrast and say
        // "Changed since" in the caption (was 0.5 opacity on the whole row).
        .padding(.vertical, 2)
    }

    private func historyRowInfo(entry: PlaybackHistoryStore.HistoryEntry, undoable: Bool, superseded: Bool,
                                kind: PlaybackHistoryStore.HistorySection.Kind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.action.icon)
                .foregroundStyle(undoable ? Color.shelfAmberText : Color.shelfMuted)
                .frame(width: 24)
                // Decorative: the action is already spelled out in the composed
                // label below, so the glyph carries no information on its own.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Typo.supporting(Text(historyRowCaption(entry: entry, superseded: superseded)))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.rowAccessibilityLabel(for: entry, undoable: undoable, groupKind: kind))
    }

    private func historyRowCaption(entry: PlaybackHistoryStore.HistoryEntry, superseded: Bool) -> String {
        let when = entry.timestamp.formatted(date: .abbreviated, time: .shortened)
        return superseded
            ? String(localized: "\(entry.action.label) \u{2022} \(when) \u{2022} \(Self.supersededCaption)", comment: "History row caption: %1$@ is the action (e.g. Marked finished), %2$@ is a date and time, %3$@ is Changed since")
            : String(localized: "\(entry.action.label) \u{2022} \(when)", comment: "History row caption: %1$@ is the action (e.g. Marked finished), %2$@ is a date and time")
    }

    @ViewBuilder
    private func historyRowControl(entry: PlaybackHistoryStore.HistoryEntry, undoable: Bool) -> some View {
        if undoingId == entry.id {
            // LS-13 (docs/design-review.md, Round 3): brand-tinted, was falling back
            // to the system tint.
            ProgressView().shelfSpinner().scaleEffect(0.7)
                .accessibilityLabel("Undoing \u{201C}\(entry.title)\u{201D}")
        } else if undoable {
            Typo.supporting(Button("Undo") {
                performUndo(entry)
            }, weight: .bold)
            .foregroundStyle(Color.shelfAmberText)
            .buttonStyle(.plain)
            // UI-12: with `.buttonStyle(.plain)` and no explicit frame, the tappable
            // area was exactly the rendered "Undo" text's own bounds — ~13pt tall,
            // the smallest tap target the review found anywhere in the app, on a
            // *repeated* primary row action (every undoable history entry has one).
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            // Voice Control: a screen with several history rows would otherwise
            // repeat the bare "Undo" label once per row, forcing users to
            // disambiguate with overlay numbers. Naming the book keeps each
            // instance unique and speakable while the visible button text stays
            // the shorter "Undo".
            .accessibilityLabel("Undo, \(entry.title)")
            .accessibilityHint("Restores this book to its progress before this action.")
        }
    }

    private func performUndo(_ entry: PlaybackHistoryStore.HistoryEntry) {
        guard undoingId == nil else { return }
        Task {
            undoingId = entry.id
            let ok = await history.undo(entry, libraryViewModel: libraryViewModel)
            undoingId = nil
            if ok {
                toastMessage = String(localized: "Restored \u{201C}\(entry.title)\u{201D} to its previous progress", comment: "Toast; %@ is a book title")
            } else if history.canUndo(entry) {
                // Critique 2026-10-06 (harden): say so, with Retry. (Not undoable any
                // more means something newer changed it; the row already shows that.)
                failedUndo = entry
            }
        }
    }

    /// Pure so it can be pinned with a regression test (see
    /// `ShelfHeadTests/HistoryAndCollectionsA11yTests.swift`) rather than only
    /// exercised through a live VoiceOver pass.
    ///
    /// Critique 2026-10-06 (harden): `groupKind` says why an entry outside this account
    /// can't be undone, instead of "changed again since".
    static func rowAccessibilityLabel(for entry: PlaybackHistoryStore.HistoryEntry, undoable: Bool,
                                      groupKind: PlaybackHistoryStore.HistorySection.Kind = .current) -> String {
        var parts = [entry.title, entry.action.label, entry.timestamp.formatted(date: .abbreviated, time: .shortened)]
        if !undoable {
            switch groupKind {
            case .current:
                parts.append(String(localized: "can't be undone, changed again since", comment: "VoiceOver"))
            case .otherServer(let host):
                parts.append(String(localized: "on \(host), switch to that server to undo", comment: "VoiceOver; %@ is a server hostname"))
            case .unknownServer:
                parts.append(String(localized: "can't be undone, server not recorded", comment: "VoiceOver"))
            }
        }
        return parts.joined(separator: ", ")
    }
}
