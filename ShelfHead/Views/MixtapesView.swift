import SwiftUI

/// Batch 458: the Mixtapes list, a mixtape's detail (play, reorder, delete, rename, share), the import
/// sheet for a received link, and the "Clip 2 of 5" banner.

struct MixtapesView: View {
    @State private var store = MixtapeStore.shared
    @State private var showNew = false
    @State private var newTitle = ""

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if store.mixtapes.isEmpty {
                // Polish pass (ST-8): the app's one empty-state component, sentence case.
                EmptyStateView(icon: "music.note.list", title: "No mixtapes yet",
                               subtitle: "Open a book, tap Clip in the player’s menu, then Add to Mixtape.")
            } else {
                List {
                    ForEach(store.mixtapes) { tape in
                        NavigationLink {
                            MixtapeDetailView(mixtapeId: tape.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Typo.rowTitle(Text(verbatim: tape.title)).foregroundStyle(Color.shelfCream)
                                Typo.supporting(Text("\(tape.clips.count) clips, \(tape.totalDuration.formattedDuration)"))
                                    .foregroundStyle(Color.shelfMuted)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.mixtapes[$0].id }
                        ids.forEach { store.delete($0) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Mixtapes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newTitle = ""; showNew = true } label: { Image(systemName: "plus") }
                    .monochromeToolbarItem()
                    .accessibilityLabel("New Mixtape")
            }
        }
        .alert("New Mixtape", isPresented: $showNew) {
            TextField("Title", text: $newTitle)
            Button("Create") { store.create(title: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct MixtapeDetailView: View {
    let mixtapeId: UUID

    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var store = MixtapeStore.shared
    @State private var mixtapePlayer = MixtapePlayer.shared
    @State private var showRename = false
    @State private var draftTitle = ""
    @State private var showingShareSheet = false

    private var tape: Mixtape? { store.mixtape(id: mixtapeId) }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if let tape {
                List {
                    Section {
                        Button {
                            Haptics.selection()
                            mixtapePlayer.play(tape, using: playerViewModel)
                        } label: {
                            Label("Play Mixtape", systemImage: "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.shelfAmber)
                        .foregroundStyle(Color.onAccent)
                        .disabled(tape.clips.isEmpty)
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(Array(tape.clips.enumerated()), id: \.element.id) { offset, clip in
                            Button {
                                Haptics.selection()
                                mixtapePlayer.play(tape, from: offset, using: playerViewModel)
                            } label: { MixtapeClipRow(clip: clip, number: offset + 1) }
                                .listRowBackground(Color.shelfCard)
                        }
                        .onMove { store.move(mixtapeId, from: $0, to: $1) }
                        .onDelete { store.removeClips(mixtapeId, at: $0) }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle(tape.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        shareButton(for: tape)
                        Menu {
                            Button("Rename", systemImage: "pencil") { draftTitle = tape.title; showRename = true }
                            EditButton()
                        } label: { Image(systemName: "ellipsis.circle") }
                            .monochromeToolbarItem()
                            .accessibilityLabel("More")
                    }
                }
                .alert("Rename Mixtape", isPresented: $showRename) {
                    TextField("Title", text: $draftTitle)
                    Button("Save") { store.rename(mixtapeId, to: draftTitle) }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showingShareSheet) {
                    if let link = try? MixtapeLink.encode(tape, serverURL: AuthStore.shared.serverURL) {
                        ActivityView(items: [String(localized: "A mixtape from ShelfHead. You need to be on the same Audiobookshelf server."), link.url])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shareButton(for tape: Mixtape) -> some View {
        if (try? MixtapeLink.encode(tape, serverURL: AuthStore.shared.serverURL)) != nil {
            // Batch 464: a share sheet without SharePlay (`ActivityView`), not `ShareLink`.
            Button { showingShareSheet = true } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .monochromeToolbarItem()
            .accessibilityLabel("Share Mixtape")
        }
    }
}

struct MixtapeClipRow: View {
    let clip: MixtapeClip
    let number: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Typo.figure(Text("\(number)")).foregroundStyle(Color.shelfMuted).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Typo.rowTitle(Text(verbatim: clip.label ?? clip.title ?? clip.itemId)).foregroundStyle(Color.shelfCream)
                if let quote = clip.quote {
                    Typo.supporting(Text(verbatim: quote)).foregroundStyle(Color.shelfMuted).lineLimit(2)
                }
                Typo.supporting(Text(verbatim: "\(clip.start.formattedTime) \u{2013} \(clip.end.formattedTime)"))
                    .foregroundStyle(Color.shelfMuted).monospacedDigit()
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

/// Present as a sheet from the deep-link handler. Saving always works; Play needs the same server.
struct MixtapeImportView: View {
    let link: DecodedMixtapeLink

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var saved = false

    private var sameServer: Bool { link.serverFingerprint == MixtapeLink.currentFingerprint() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !sameServer {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.shelfOrange).accessibilityHidden(true)
                            Typo.supporting(Text("This mixtape is from a different server")).foregroundStyle(Color.shelfCream)
                        }
                    }
                }
                Section {
                    ForEach(Array(link.mixtape.clips.enumerated()), id: \.element.id) { offset, clip in
                        if sameServer {
                            MixtapeClipRow(clip: clip, number: offset + 1)
                        } else {
                            // Titles only: the clips can't be played from this account.
                            HStack(spacing: 12) {
                                Typo.figure(Text("\(offset + 1)")).foregroundStyle(Color.shelfMuted).monospacedDigit()
                                Typo.rowTitle(Text(verbatim: clip.label ?? clip.title ?? "")).foregroundStyle(Color.shelfCream)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                } header: { Text(verbatim: link.mixtape.title) }
                if sameServer {
                    Section {
                        Button {
                            let tape = saveCopy()
                            MixtapePlayer.shared.play(tape, using: playerViewModel)
                            dismiss()
                        } label: { Label("Play", systemImage: "play.fill").frame(minHeight: 44) }
                        Button {
                            _ = saveCopy()
                            Haptics.success()
                            dismiss()
                        } label: { Label(saved ? "Saved" : "Save to My Mixtapes", systemImage: "square.and.arrow.down").frame(minHeight: 44) }
                            .disabled(saved)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle("Mixtape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.monochromeToolbarItem()
                }
            }
        }
        .systemChromeTint()
    }

    private func saveCopy() -> Mixtape {
        if let existing = MixtapeStore.shared.mixtape(id: link.mixtape.id) { return existing }
        MixtapeStore.shared.upsert(link.mixtape)
        saved = true
        return link.mixtape
    }
}

/// "Clip 2 of 5" strip for the player to show while a mixtape runs.
struct MixtapeBanner: View {
    @State private var mixtapePlayer = MixtapePlayer.shared

    var body: some View {
        if let text = mixtapePlayer.bannerText, let mixtape = mixtapePlayer.mixtape {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Typo.supporting(Text(verbatim: text)).foregroundStyle(Color.shelfCream)
                    Typo.supporting(Text(verbatim: mixtape.title)).foregroundStyle(Color.shelfMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { mixtapePlayer.skipToNext() } label: {
                    Image(systemName: "forward.end.fill").frame(minWidth: 44, minHeight: 44)
                }
                .disabled(mixtapePlayer.index + 1 >= mixtapePlayer.clipCount)
                .accessibilityLabel("Next clip")
                Button { mixtapePlayer.stop() } label: {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Stop Mixtape")
            }
            .foregroundStyle(Color.shelfCream)
            .padding(.horizontal, 14)
            .background(Color.shelfCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}
