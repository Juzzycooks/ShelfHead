import SwiftUI

/// Batch 454: the pure side of "Recommend to…". Pinned by `HouseholdSocialTests`.
nonisolated enum RecommendDraft {
    static let maxNoteLength = 280

    static func clampedNote(_ text: String) -> String { String(text.prefix(maxNoteLength)) }

    static func canSend(selected: Set<String>) -> Bool { !selected.isEmpty }

    /// Members you can send to: everyone but you, in the household's display order.
    static func recipients(members: [HouseholdMember], myMemberId: String?) -> [HouseholdMember] {
        members.filter { $0.id != myMemberId }
    }

    static func make(fromMemberId: String, toMemberIds: Set<String>, members: [HouseholdMember],
                     libraryItemId: String, serverFingerprint: String, title: String, author: String,
                     note: String, now: Date, id: String = HouseholdRecommendation.makeId()) -> HouseholdRecommendation {
        // Stable order (the members list's), not Set order.
        let ordered = members.map(\.id).filter { toMemberIds.contains($0) }
        return HouseholdRecommendation(id: id, fromMemberId: fromMemberId, toMemberIds: ordered,
                                       libraryItemId: libraryItemId, serverFingerprint: serverFingerprint,
                                       title: title, author: author,
                                       note: clampedNote(note).trimmingCharacters(in: .whitespacesAndNewlines),
                                       createdAt: now)
    }
}

/// Batch 454: pick household members (one or more), add an optional note, send. One `Recommendation` record
/// addresses everyone you picked.
struct RecommendBookSheet: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var store = HouseholdStore.shared
    @State private var selected: Set<String> = []
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private var recipients: [HouseholdMember] {
        RecommendDraft.recipients(members: store.members, myMemberId: store.myMemberId)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if recipients.isEmpty {
                        Typo.supporting(Text("No one else is in your household yet."))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    ForEach(recipients) { member in
                        Button {
                            Haptics.selection()
                            if selected.contains(member.id) { selected.remove(member.id) } else { selected.insert(member.id) }
                        } label: {
                            HStack(spacing: 12) {
                                HouseholdAvatarView(symbol: member.avatarSymbol, colorIndex: member.avatarColorIndex, size: 36)
                                Typo.rowTitle(Text(verbatim: member.displayName))
                                    .foregroundStyle(Color.shelfCream)
                                Spacer()
                                Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(member.id) ? Color.shelfCream : Color.shelfMuted)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(member.id) ? .isSelected : [])
                    }
                } header: {
                    RetroSectionHeader(title: "Send To")
                }
                .listRowBackground(Color.shelfCard)

                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($noteFocused)
                        .onChange(of: note) { _, newValue in
                            let clamped = RecommendDraft.clampedNote(newValue)
                            if clamped != newValue { note = clamped }
                        }
                    Typo.fine(Text("\(note.count) of \(RecommendDraft.maxNoteLength)"))
                        .foregroundStyle(Color.shelfMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    RetroSectionHeader(title: "Note")
                }
                .listRowBackground(Color.shelfCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle(Text("Recommend"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!RecommendDraft.canSend(selected: selected))
                }
            }
        }
    }

    private func send() {
        guard let me = store.myMemberId else { return }
        let rec = RecommendDraft.make(
            fromMemberId: me, toMemberIds: selected, members: store.members,
            libraryItemId: item.id,
            serverFingerprint: ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL),
            title: item.title, author: item.authorName, note: note, now: Date())
        store.save(.recommendation(rec))
        Haptics.success()
        dismiss()
    }
}
