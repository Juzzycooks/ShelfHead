import SwiftUI

/// Batch 454: the pure rules for what the Household shelf shows. Pinned by `HouseholdSocialTests`.
nonisolated enum HouseholdShelfLogic {
    /// Now Listening records older than this are stale (the person stopped sharing or stopped listening).
    static let maxListeningAge: TimeInterval = 3 * 24 * 3600
    static let maxListeningRows = 5
    static let maxRecommendationRows = 3

    /// A book opens only for a member on the same Audiobookshelf server as this account: the item id means
    /// nothing anywhere else. An empty fingerprint (no usable host) never matches.
    static func isSameServer(_ fingerprint: String, mine: String) -> Bool {
        !fingerprint.isEmpty && fingerprint == mine
    }

    /// Other members' listening, freshest first, recent only.
    static func listening(snapshot: HouseholdSnapshot, myMemberId: String?, now: Date) -> [HouseholdNowListening] {
        snapshot.nowListening.values
            .filter { $0.memberId != myMemberId
                && snapshot.members[$0.memberId] != nil
                && now.timeIntervalSince($0.updatedAt) <= maxListeningAge }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The shelf shows nothing unless you're in a household and there's something to show.
    static func shouldShow(inHousehold: Bool, listeningCount: Int, inboxCount: Int) -> Bool {
        inHousehold && (listeningCount > 0 || inboxCount > 0)
    }
}

/// Batch 454: Home shelf "Household". What the others are listening to (if they chose to share it) and
/// recommendations sent to you. Renders nothing outside a household or when there's nothing to show.
struct HouseholdShelf: View {
    @State private var store = HouseholdStore.shared
    @State private var inbox = HouseholdInbox.shared

    var body: some View {
        let snapshot = store.snapshot
        let listening = Array(HouseholdShelfLogic.listening(snapshot: snapshot, myMemberId: store.myMemberId,
                                                            now: Date()).prefix(HouseholdShelfLogic.maxListeningRows))
        let recs = Array(inbox.items.prefix(HouseholdShelfLogic.maxRecommendationRows))
        if HouseholdShelfLogic.shouldShow(inHousehold: store.isSocialAvailable, listeningCount: listening.count,
                                          inboxCount: recs.count) {
            let myFingerprint = ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL)
            VStack(alignment: .leading, spacing: 12) {
                // Batch 490 (REVIEW 2026-11-11 A3): the header leads to Settings › Household, where
                // sharing and the inbox are managed (same route an accepted invite takes).
                HStack(alignment: .firstTextBaseline) {
                    RetroSectionHeader(title: "Household")
                    Spacer(minLength: 8)
                    Button {
                        Haptics.selection()
                        NotificationCenter.default.post(name: .shelfheadOpenHousehold, object: nil)
                    } label: {
                        Text("Manage")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Household settings"))
                }
                .padding(.horizontal, Space.pageH)
                VStack(spacing: 0) {
                    ForEach(listening) { entry in
                        if let member = snapshot.members[entry.memberId] {
                            HouseholdShelfRow(member: member, kind: .listening(progress: entry.progress),
                                              itemId: entry.libraryItemId, title: entry.title, author: entry.author,
                                              note: nil,
                                              sameServer: HouseholdShelfLogic.isSameServer(entry.serverFingerprint, mine: myFingerprint))
                            divider(after: entry.id, listening: listening, recs: recs)
                        }
                    }
                    ForEach(recs) { rec in
                        if let member = snapshot.members[rec.fromMemberId] {
                            HouseholdShelfRow(member: member, kind: .recommendation, itemId: rec.libraryItemId,
                                              title: rec.title, author: rec.author,
                                              note: rec.note.isEmpty ? nil : rec.note,
                                              sameServer: HouseholdShelfLogic.isSameServer(rec.serverFingerprint, mine: myFingerprint),
                                              // Batch 490 (REVIEW 2026-11-11 A3): the same dismiss as Settings › Household.
                                              onDismiss: { inbox.dismiss(rec.id) })
                            if rec.id != recs.last?.id { Divider().background(Color.shelfSurface) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .shelfCardStyle()
                .padding(.horizontal, Space.pageH)
            }
        }
    }

    @ViewBuilder
    private func divider(after id: String, listening: [HouseholdNowListening], recs: [HouseholdRecommendation]) -> some View {
        if id != listening.last?.id || !recs.isEmpty {
            Divider().background(Color.shelfSurface)
        }
    }
}

private struct HouseholdShelfRow: View {
    enum Kind { case listening(progress: Double), recommendation }

    let member: HouseholdMember
    let kind: Kind
    let itemId: String
    let title: String
    let author: String
    let note: String?
    let sameServer: Bool
    /// Batch 490 (REVIEW 2026-11-11 A3): recommendation rows only — hides it on this device.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        if let onDismiss {
            row
                .contextMenu {
                    Button(role: .destructive) {
                        onDismiss()
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                }
                .accessibilityActions {
                    Button("Dismiss") { onDismiss() }
                }
        } else {
            row
        }
    }

    @ViewBuilder private var row: some View {
            if sameServer {
                NavigationLink(destination: HouseholdBookDestination(itemId: itemId)) {
                    content(showChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                // Batch 490 (REVIEW 2026-11-11 A3): only the avatar dims (see `content`); the text
                // stays at full contrast so it's still readable.
                content(showChevron: false)
                    .accessibilityHint(Text("On another server"))
            }
    }

    private func content(showChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HouseholdAvatarView(symbol: member.avatarSymbol, colorIndex: member.avatarColorIndex, size: 36)
                .opacity(sameServer ? 1 : 0.65)
            VStack(alignment: .leading, spacing: 3) {
                caption
                    .foregroundStyle(Color.shelfMuted)
                Typo.rowTitle(Text(verbatim: title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !author.isEmpty {
                    Typo.rowSubtitle(Text(verbatim: author))
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(1)
                }
                if case .listening(let progress) = kind {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(Color.shelfMuted)
                        .accessibilityHidden(true)
                }
                if let note {
                    Typo.supporting(Text(verbatim: note))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if !sameServer {
                    Typo.fine(Text("On another server"))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer(minLength: 8)
            if showChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(13, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Color.shelfMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var caption: some View {
        switch kind {
        case .listening(let progress):
            Typo.supporting(Text("\(member.displayName) is listening, \(Int((min(max(progress, 0), 1) * 100).rounded()))%",
                                 comment: "Household shelf: a member's name and how far through the book they are"))
        case .recommendation:
            Typo.supporting(Text("\(member.displayName) recommends",
                                 comment: "Household shelf: a member's name before the book they recommend"))
        }
    }
}

/// Batch 454: opens Book Detail for an item known only by id (a household member's book on the same server).
struct HouseholdBookDestination: View {
    let itemId: String
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var item: LibraryItem?
    @State private var failed = false
    /// Batch 490 (REVIEW 2026-11-11 A3): bumped by Retry to run the load again.
    @State private var attempt = 0

    var body: some View {
        Group {
            if let item {
                BookDetailView(item: item)
            } else {
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    if failed {
                        // Batch 490 (REVIEW 2026-11-11 A3): the shared empty state with a way forward,
                        // instead of a bare caption.
                        EmptyStateView(
                            icon: "book.closed",
                            title: LocalizedStringResource("Couldn\u{2019}t open this book"),
                            subtitle: LocalizedStringResource("It may have been removed, or your server can\u{2019}t be reached."),
                            actionTitle: LocalizedStringResource("Retry", comment: "Button: try loading again")
                        ) {
                            Haptics.selection()
                            failed = false
                            attempt += 1
                        }
                    } else {
                        ProgressView()
                            .shelfSpinner()
                            .accessibilityLabel("Loading")
                    }
                }
            }
        }
        .task(id: attempt) {
            guard item == nil else { return }
            if let loaded = await libraryViewModel.getItemDetail(itemId: itemId)
                ?? DownloadManager.shared.libraryItem(for: itemId) {
                item = loaded
            } else {
                failed = true
            }
        }
    }
}
