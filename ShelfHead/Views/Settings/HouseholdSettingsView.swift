import SwiftUI
import CloudKit

/// Batch 453: the Household page. A household is a few people (each with their own iCloud account, on any
/// Audiobookshelf server) sharing a small iCloud zone. Like `TranscriptsSettingsView`, the body is a group of
/// sections for `SettingsCategoryPage` to host. Nothing is shared until you create or join one, and later
/// batches add the things you can choose to share (what you're listening to, recommendations, book clubs).
struct HouseholdSettingsView: View {
    @AppStorage(SettingsKeys.householdDisplayName) private var displayName = ""
    @AppStorage(SettingsKeys.householdAvatarSymbol) private var avatarSymbol = HouseholdAvatar.symbols[0]
    @AppStorage(SettingsKeys.householdAvatarColor) private var avatarColor = 0

    @AppStorage(SettingsKeys.householdShareNowListening) private var shareNowListening = false

    @State private var store = HouseholdStore.shared
    @State private var inbox = HouseholdInbox.shared
    @State private var confirmLeave = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if case .iCloudUnavailable(let reason) = store.state {
                Section {
                    statusRow(symbol: "icloud.slash", text: Text(verbatim: reason), isProblem: true)
                } header: {
                    RetroSectionHeader(title: "Household")
                }
                .listRowBackground(Color.shelfCard)
                .settingsRowAnchor(SettingsRow.household)
            }

            // Search anchors live here rather than on the whole view, so the "Share what I'm
            // listening to" result can land on its own section instead of the page's first.
            if store.isInHousehold {
                Group {
                    membersSection
                    inboxSection
                    if store.isOwner { inviteSection }
                    profileSection
                }
                .settingsRowAnchor(SettingsRow.household)
                sharingSection
                    .settingsRowAnchor(SettingsRow.householdSharing)
                Group {
                    aboutSection
                    leaveSection
                }
                .settingsRowAnchor(SettingsRow.household)
            } else {
                introSection
                    .settingsRowAnchor(SettingsRow.household)
            }
        }
        .task { await store.start() }
        .onDisappear { store.publishMyProfile() }
    }

    // MARK: Not joined

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                settingRow("person.2.fill", "Household")
                SettingsCaption(text: "Share recommendations and book clubs with family or friends. Everyone keeps their own Audiobookshelf account, and they can be on different servers.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await store.createHousehold() }
                } label: {
                    Label("Create a Household", systemImage: "plus.circle")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(store.isBusy || isUnavailable)
                SettingsCaption(text: "To join one instead, ask its owner to send you an invitation and open it on this iPhone.")
            }
            if let error = store.lastError {
                statusRow(symbol: "exclamationmark.triangle.fill", text: Text(verbatim: error), isProblem: true)
            }
            // Batch 481: "you were removed" and "the household was deleted" land here, after the reset.
            if let notice = store.notice {
                statusRow(symbol: "info.circle", text: Text(verbatim: notice), isProblem: false)
            }
        } header: {
            RetroSectionHeader(title: "Household")
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: Members

    private var membersSection: some View {
        Section {
            if store.members.isEmpty {
                Typo.supporting(Text("No one here yet. People appear after they join."))
                    .foregroundStyle(Color.shelfMuted)
            }
            ForEach(store.members) { member in
                HStack(spacing: 12) {
                    HouseholdAvatarView(symbol: member.avatarSymbol, colorIndex: member.avatarColorIndex, size: 36)
                    Typo.rowTitle(Text(verbatim: member.displayName))
                        .foregroundStyle(Color.shelfCream)
                    if member.id == store.myMemberId {
                        Spacer()
                        Typo.supporting(Text("You")).foregroundStyle(Color.shelfMuted)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
            if let error = store.lastError {
                statusRow(symbol: "exclamationmark.triangle.fill", text: Text(verbatim: error), isProblem: true)
            }
            if let notice = store.notice {
                statusRow(symbol: "info.circle", text: Text(verbatim: notice), isProblem: false)
            }
        } header: {
            RetroSectionHeader(title: "Members")
        }
        .listRowBackground(Color.shelfCard)
    }

    private var inviteSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ShareLink(item: HouseholdInvite(share: store.existingShare), preview: SharePreview("ShelfHead Household")) {
                    Label("Invite Someone", systemImage: "person.badge.plus")
                        .frame(minHeight: 44, alignment: .leading)
                }
                SettingsCaption(text: "They need an iPhone with iCloud. Only the people you invite can join.")
            }
        } header: {
            RetroSectionHeader(title: "Invite")
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: You

    private var profileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SettingsControlRow(icon: "person.fill", title: "Your Name") {
                    TextField("Name", text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { store.publishMyProfile() }
                }
                SettingsCaption(text: "This is how other members see you.")
            }

            VStack(alignment: .leading, spacing: 10) {
                settingRow("face.smiling", "Your Picture")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                    ForEach(HouseholdAvatar.symbols, id: \.self) { symbol in
                        Button {
                            avatarSymbol = symbol
                            store.publishMyProfile()
                        } label: {
                            HouseholdAvatarView(symbol: symbol, colorIndex: avatarColor, size: 44,
                                                selected: symbol == avatarSymbol)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: symbol))
                        .accessibilityAddTraits(symbol == avatarSymbol ? .isSelected : [])
                    }
                }
                HStack(spacing: 10) {
                    ForEach(0..<HouseholdAvatar.colorCount, id: \.self) { index in
                        Button {
                            avatarColor = index
                            store.publishMyProfile()
                        } label: {
                            Circle()
                                .fill(HouseholdAvatarView.color(index))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if index == HouseholdAvatar.clampedColor(avatarColor) {
                                        Circle().strokeBorder(Color.shelfCream, lineWidth: 2).padding(-4)
                                    }
                                }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Colour \(index + 1)"))
                        .accessibilityAddTraits(index == HouseholdAvatar.clampedColor(avatarColor) ? .isSelected : [])
                    }
                }
            }
        } header: {
            RetroSectionHeader(title: "You")
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: Inbox and sharing (Batch 454)

    /// Recommendations sent to you, newest first. Swipe to dismiss hides one on this device only.
    @ViewBuilder private var inboxSection: some View {
        let items = inbox.items
        if !items.isEmpty {
            Section {
                ForEach(items) { rec in
                    inboxRow(rec)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                inbox.dismiss(rec.id)
                            } label: {
                                Label("Dismiss", systemImage: "xmark")
                            }
                        }
                        .accessibilityActions {
                            Button("Dismiss") { inbox.dismiss(rec.id) }
                        }
                }
            } header: {
                RetroSectionHeader(title: "Recommended to You")
            }
            .listRowBackground(Color.shelfCard)
        }
    }

    private func inboxRow(_ rec: HouseholdRecommendation) -> some View {
        let sender = store.snapshot.members[rec.fromMemberId]
        let sameServer = HouseholdShelfLogic.isSameServer(rec.serverFingerprint,
                                                          mine: ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL))
        return HStack(alignment: .top, spacing: 12) {
            HouseholdAvatarView(symbol: sender?.avatarSymbol ?? HouseholdAvatar.symbols[0],
                                colorIndex: sender?.avatarColorIndex ?? 0, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Typo.supporting(Text("\(sender?.displayName ?? String(localized: "Someone", comment: "Household: stands in for a member's name")) recommends",
                                     comment: "Household inbox: a member’s name before the book they recommend"))
                    .foregroundStyle(Color.shelfMuted)
                Typo.rowTitle(Text(verbatim: rec.title)).foregroundStyle(Color.shelfCream)
                if !rec.author.isEmpty {
                    Typo.rowSubtitle(Text(verbatim: rec.author)).foregroundStyle(Color.shelfMuted)
                }
                if !rec.note.isEmpty {
                    Typo.supporting(Text(verbatim: rec.note)).foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !sameServer {
                    Typo.fine(Text("On another server")).foregroundStyle(Color.shelfMuted)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var sharingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $shareNowListening) {
                    settingRow("headphones", "Share what I’m listening to")
                }
                .onChange(of: shareNowListening) { _, enabled in
                    HouseholdNowListeningPublisher.shared.sharingChanged(enabled: enabled)
                }
                SettingsCaption(text: "Members see the title and how far you are while you listen. Turn it off and it’s removed.")
            }
        } header: {
            RetroSectionHeader(title: "Sharing")
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: About and leave

    private var aboutSection: some View {
        Section {
            SettingsCaption(text: "Only what you choose to share is shared. It’s stored in iCloud, not on your Audiobookshelf server, and only members can see it. Your books, listening history and server login are never shared.", leadingInset: 0)
            if let synced = store.lastSyncedAt {
                LabeledContent {
                    Typo.supporting(Text(synced, style: .relative)).foregroundStyle(Color.shelfMuted)
                } label: {
                    settingRow("arrow.triangle.2.circlepath", "Last synced")
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise").frame(minHeight: 44, alignment: .leading)
            }
            .disabled(store.isBusy || isUnavailable)
        } header: {
            RetroSectionHeader(title: "Privacy")
        }
        .listRowBackground(Color.shelfCard)
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                confirmLeave = true
            } label: {
                Label(store.isOwner ? "Delete Household" : "Leave Household", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(store.isBusy || isUnavailable)
            .confirmationDialog(store.isOwner ? "Delete this household?" : "Leave this household?",
                                isPresented: $confirmLeave, titleVisibility: .visible) {
                Button(store.isOwner ? "Delete Household" : "Leave Household", role: .destructive) {
                    Task { await store.leave() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(store.isOwner
                     ? "This removes the household for everyone in it, including their recommendations and club posts."
                     : "You’ll stop seeing the household. Your posts and recommendations are removed from it.")
            }
            .systemChromeTint()
        }
        .listRowBackground(Color.shelfCard)
    }

    // MARK: Pieces

    private var isUnavailable: Bool {
        if case .iCloudUnavailable = store.state { return true }
        return false
    }

    private func statusRow(symbol: String, text: Text, isProblem: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                // DESIGN.md orange rule: orange glyph, cream sentence.
                .foregroundStyle(isProblem ? Color.shelfOrange : Color.shelfAmberText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Typo.supporting(text)
                .foregroundStyle(Color.shelfCream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Batch 453: a member's picture, an SF Symbol on a token colour. Reused by the later Household shelf.
struct HouseholdAvatarView: View {
    let symbol: String
    let colorIndex: Int
    var size: CGFloat = 36
    var selected = false

    /// The six avatar colours, from the app's tokens.
    static func color(_ index: Int) -> Color {
        let palette: [Color] = [.shelfAmberText, .shelfAccentText, .shelfOrange, .shelfAmberDark, .shelfMuted, .shelfCream]
        return palette[HouseholdAvatar.clampedColor(index)]
    }

    var body: some View {
        let tint = Self.color(colorIndex)
        Image(systemName: symbol)
            .font(.system(size: size * 0.45))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.18)))
            .overlay {
                if selected { Circle().strokeBorder(Color.shelfCream, lineWidth: 2) }
            }
            .accessibilityHidden(true)
    }
}
