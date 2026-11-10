import SwiftUI

/// Batch 455: Book Club for one book, inside the household. An optional goal ("Chapter 12 by Friday"), how
/// far each member is toward it (from their shared Now Listening, else "Not shared"), and a timeline of posts
/// pinned to a place in the book. Posts ahead of your own position are hidden behind `SpoilerGate`.
///
/// Presented as a sheet. `myPositionSeconds` is where you are now (the live position when this book is
/// playing); `isFinished` shows every post. `startComposing` focuses the post field (the player's
/// "Post to Book Club" entry).
struct BookClubView: View {
    let item: LibraryItem
    let chapters: [Chapter]
    let myPositionSeconds: Double
    var isFinished = false
    var startComposing = false

    @Environment(\.dismiss) private var dismiss
    @State private var store = HouseholdStore.shared

    // Goal editor
    @State private var editingGoal = false
    @State private var goalText = ""
    @State private var goalSeconds: Double?
    @State private var hasGoalDate = false
    @State private var goalDate = Date()

    // Composer
    @State private var postText = ""
    @State private var postPosition: Double?
    @FocusState private var postFocused: Bool

    private var myFingerprint: String { ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL) }
    /// Batch 482: new writes go to the title-and-author id, so members on other servers share the club.
    private var clubIds: BookClubIds {
        BookClubIds(serverFingerprint: myFingerprint, libraryItemId: item.id, title: item.title, author: item.authorName)
    }
    private var clubId: String { clubIds.shared }
    private var club: HouseholdClub? { clubIds.club(in: store.snapshot) }
    private var duration: Double { item.duration }
    private var effectivePosition: Double { isFinished ? .infinity : myPositionSeconds }

    var body: some View {
        NavigationStack {
            List {
                goalSection
                if club.map({ ClubGoal.hasGoal($0) }) == true || !store.members.isEmpty {
                    progressSection
                }
                composerSection
                postsSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle(Text("Book Club"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if startComposing { postFocused = true }
                await store.refresh()
            }
        }
    }

    // MARK: Goal

    private var goalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Typo.cardTitle(Text(verbatim: item.title)).foregroundStyle(Color.shelfCream)
                if !item.authorName.isEmpty {
                    Typo.rowSubtitle(Text(verbatim: item.authorName)).foregroundStyle(Color.shelfMuted)
                }
            }
            if editingGoal {
                goalEditor
            } else if let club, ClubGoal.hasGoal(club) {
                goalSummary(club)
                Button("Edit Goal") { beginEditingGoal() }
                    .frame(minHeight: 44, alignment: .leading)
            } else {
                Button {
                    beginEditingGoal()
                } label: {
                    Label("Set a Goal", systemImage: "flag").frame(minHeight: 44, alignment: .leading)
                }
            }
        } header: {
            RetroSectionHeader(title: "Goal")
        }
        .listRowBackground(Color.shelfCard)
    }

    private func goalSummary(_ club: HouseholdClub) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = club.goalText, !text.isEmpty {
                Typo.rowTitle(Text(verbatim: text)).foregroundStyle(Color.shelfCream)
            }
            if let seconds = club.goalSeconds {
                Typo.supporting(Text("Target: \(targetDescription(seconds))"))
                    .foregroundStyle(Color.shelfMuted)
            }
            if let date = club.goalDate {
                Typo.supporting(Text("By \(date.formatted(date: .abbreviated, time: .omitted))"))
                    .foregroundStyle(Color.shelfMuted)
                if let days = ClubGoal.daysLeft(goalDate: date, now: Date()) {
                    Typo.fine(Text(daysLeftText(days))).foregroundStyle(Color.shelfMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var goalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Goal (optional)", text: $goalText, axis: .vertical)
                .lineLimit(1...3)
            if !chapters.isEmpty {
                Picker("Finish by the end of", selection: Binding(get: { goalSeconds ?? -1 }, set: { goalSeconds = $0 < 0 ? nil : $0 })) {
                    Text("No target").tag(-1.0)
                    ForEach(chapters) { chapter in
                        Text(verbatim: chapter.title).tag(chapter.end)
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("Set a date", isOn: $hasGoalDate)
            if hasGoalDate {
                DatePicker("Date", selection: $goalDate, in: Date()..., displayedComponents: .date)
            }
            HStack {
                Button("Cancel") { editingGoal = false }
                    .frame(minHeight: 44)
                Spacer()
                Button("Save Goal") { saveGoal() }
                    .frame(minHeight: 44)
            }
        }
    }

    private func beginEditingGoal() {
        goalText = club?.goalText ?? ""
        goalSeconds = club?.goalSeconds
        hasGoalDate = club?.goalDate != nil
        goalDate = club?.goalDate ?? Date()
        editingGoal = true
    }

    private func saveGoal() {
        var updated = existingOrNewClub()
        let trimmed = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.goalText = trimmed.isEmpty ? nil : trimmed
        updated.goalSeconds = goalSeconds
        updated.goalDate = hasGoalDate ? goalDate : nil
        updated.updatedAt = Date()
        store.save(.club(updated))
        editingGoal = false
    }

    private func existingOrNewClub() -> HouseholdClub {
        // An older server-keyed club is carried over to the shared id, goal and all.
        if var club {
            club.id = clubId
            return club
        }
        return HouseholdClub(id: clubId, libraryItemId: item.id, title: item.title, author: item.authorName,
                             serverFingerprint: myFingerprint, goalText: nil, goalSeconds: nil, goalDate: nil,
                             createdBy: store.myMemberId ?? "", updatedAt: Date())
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            ForEach(store.members) { member in
                memberProgressRow(member)
            }
        } header: {
            RetroSectionHeader(title: "Progress")
        }
        .listRowBackground(Color.shelfCard)
    }

    private func memberProgressRow(_ member: HouseholdMember) -> some View {
        let isMe = member.id == store.myMemberId
        // Your own position is known locally; others only if they chose to share it.
        let shared: Double? = {
            if isMe { return duration > 0 ? min(max(myPositionSeconds / duration, 0), 1) : nil }
            guard let club else { return nil }
            return ClubGoal.sharedProgress(of: store.snapshot.nowListening[member.id], in: club)
        }()
        let goal = club?.goalSeconds
        return HStack(spacing: 12) {
            HouseholdAvatarView(symbol: member.avatarSymbol, colorIndex: member.avatarColorIndex, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Typo.rowTitle(Text(verbatim: member.displayName)).foregroundStyle(Color.shelfCream)
                Typo.supporting(statusText(shared: shared, goal: goal)).foregroundStyle(Color.shelfMuted)
                if shared != nil {
                    ProgressView(value: goal.map { ClubGoal.fractionOfGoal(sharedProgress: shared, bookDuration: duration, goalSeconds: $0) } ?? (shared ?? 0))
                        .tint(Color.shelfMuted)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func statusText(shared: Double?, goal: Double?) -> Text {
        guard let shared else { return Text("Not shared") }
        if let goal {
            switch ClubGoal.status(sharedProgress: shared, bookDuration: duration, goalSeconds: goal) {
            case .reached: return Text("Reached the goal")
            case .behind(let seconds): return Text("\(seconds.formattedDuration) to go")
            case .notShared: return Text("Not shared")
            }
        }
        return Text("\(Int((shared * 100).rounded()))% through")
    }

    // MARK: Composer

    private var composerSection: some View {
        Section {
            TextField("Say something about this part", text: $postText, axis: .vertical)
                .lineLimit(2...6)
                .focused($postFocused)
                .onChange(of: postText) { _, newValue in
                    let clamped = ClubPostDraft.clamped(newValue)
                    if clamped != newValue { postText = clamped }
                }
            Menu {
                Button("Current position (\(myPositionSeconds.formattedTime))") { postPosition = nil }
                ForEach(chapters.filter { $0.start <= effectivePosition }) { chapter in
                    Button { postPosition = chapter.start } label: {
                        Text("\(chapter.title) (\(chapter.start.formattedTime))")
                    }
                }
            } label: {
                Label("At \((postPosition ?? myPositionSeconds).formattedTime)", systemImage: "clock")
                    .frame(minHeight: 44, alignment: .leading)
            }
            Button {
                post()
            } label: {
                Label("Post", systemImage: "paperplane").frame(minHeight: 44, alignment: .leading)
            }
            .disabled(!ClubPostDraft.canPost(postText) || store.myMemberId == nil)
        } header: {
            RetroSectionHeader(title: "New Post")
        } footer: {
            Typo.fine(Text("Everyone in the household sees a post once they've listened that far."))
                .foregroundStyle(Color.shelfMuted)
        }
        .listRowBackground(Color.shelfCard)
    }

    private func post() {
        guard let me = store.myMemberId, ClubPostDraft.canPost(postText) else { return }
        if club?.id != clubId { store.save(.club(existingOrNewClub())) }
        let entry = HouseholdClubPost(id: HouseholdClubPost.makeId(), clubId: clubId, memberId: me,
                                      positionSeconds: postPosition ?? myPositionSeconds,
                                      text: postText.trimmingCharacters(in: .whitespacesAndNewlines),
                                      createdAt: Date())
        store.save(.clubPost(entry))
        postText = ""
        postPosition = nil
        postFocused = false
        Haptics.success()
    }

    // MARK: Posts

    private var postsSection: some View {
        let gate = SpoilerGate.filter(posts: clubIds.posts(in: store.snapshot), myPosition: effectivePosition,
                                      myMemberId: store.myMemberId)
        return Section {
            if gate.visible.isEmpty && gate.hiddenAheadCount == 0 {
                Typo.supporting(Text("No posts yet."))
                    .foregroundStyle(Color.shelfMuted)
            }
            ForEach(gate.visible) { entry in
                postRow(entry)
            }
            if gate.hiddenAheadCount > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    Typo.supporting(Text("\(gate.hiddenAheadCount) posts ahead of you"))
                        .foregroundStyle(Color.shelfMuted)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("They appear as you listen on."))
            }
        } header: {
            RetroSectionHeader(title: "Posts")
        }
        .listRowBackground(Color.shelfCard)
    }

    private func postRow(_ entry: HouseholdClubPost) -> some View {
        let member = store.snapshot.members[entry.memberId]
        let mine = entry.memberId == store.myMemberId
        return HStack(alignment: .top, spacing: 12) {
            HouseholdAvatarView(symbol: member?.avatarSymbol ?? HouseholdAvatar.symbols[0],
                                colorIndex: member?.avatarColorIndex ?? 0, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Typo.rowTitle(Text(verbatim: member?.displayName ?? String(localized: "Former member", comment: "Household: a post's author is no longer in the household")))
                        .foregroundStyle(Color.shelfCream)
                    Typo.fine(Text("at \(entry.positionSeconds.formattedTime)"))
                        .foregroundStyle(Color.shelfMuted)
                }
                Typo.supporting(Text(verbatim: entry.text))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
                Typo.fine(Text(entry.createdAt, style: .relative))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if mine {
                Button(role: .destructive) {
                    store.delete(.clubPost(entry))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityActions {
            if mine {
                Button("Delete") { store.delete(.clubPost(entry)) }
            }
        }
    }

    // MARK: Text

    /// "the end of Chapter 12 (1:23:45)", or just the time when no chapter ends there.
    private func targetDescription(_ seconds: Double) -> String {
        if let chapter = chapters.first(where: { abs($0.end - seconds) < 1 }) {
            return "\(chapter.title) (\(seconds.formattedTime))"
        }
        return seconds.formattedTime
    }

    private func daysLeftText(_ days: Int) -> String {
        if days > 1 { return String(localized: "\(days) days left", comment: "Book Club: days until the goal date") }
        if days == 1 { return String(localized: "1 day left", comment: "Book Club: one day until the goal date") }
        if days == 0 { return String(localized: "Due today", comment: "Book Club: the goal date is today") }
        return String(localized: "Past the date", comment: "Book Club: the goal date has passed")
    }
}
