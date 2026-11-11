import SwiftUI

/// Lists in-progress / paused downloads and offers safe repair actions: reload the
/// index for the active account (re-syncs after an account switch) and a confirmed
/// "remove all" for the current account's downloads.
///
/// Moved out of `SettingsView.swift` into its own file under `Views/Diagnostics/`
/// (UI-12, REVIEW_2026-08-12.md, "Split SettingsView.swift into Views/Settings/") — its
/// content and behavior are unchanged, only its location.
struct DownloadHealthView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Height reserved so content clears the floating mini-player + tab bar.
    var bottomInset: CGFloat = 0
    @State private var showRemoveAllConfirm = false
    /// Per-book results from the last `verifyDownload` pass, keyed by item id. Nil for a
    /// book that hasn't been checked yet this screen visit — verification is on-demand
    /// (a "Verify all" button, or per-row), not automatic, since walking every downloaded
    /// file's bytes on every visit to this screen would be wasted work most of the time.
    @State private var healthReports: [String: DownloadHealthReport] = [:]
    /// Item ids currently mid-repair, so their row can show a spinner instead of a
    /// tappable "Repair" button (repair kicks off real background download tasks; the
    /// completion callback lives in `DownloadManager`, not here, so this view has to poll
    /// via a short delay rather than observe a "repair finished" signal directly).
    @State private var repairingIds: Set<String> = []
    /// LS-11 (docs/design-review.md, Round 3): mirrors `repairingIds` for the per-book
    /// "Verify" button, which previously gave no sign it was doing anything while it
    /// walked every track file on disk.
    @State private var verifyingIds: Set<String> = []
    /// LS-11: set while "Verify all downloads" is running, so that button and every
    /// per-book Verify/Repair button can be disabled for the duration.
    @State private var isVerifyingAll = false

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    private var active: [DownloadTask] {
        DownloadManager.shared.activeDownloads.values.sorted { $0.title < $1.title }
    }
    private var pausedCount: Int {
        DownloadManager.shared.activeDownloads.values.filter { $0.isPaused }.count
    }
    /// A plain `(id:title:)` tuple isn't usable as `ForEach`'s `id:` key path — Swift key
    /// paths can't refer to tuple elements — so this needs a real `Identifiable` struct.
    private struct DownloadedBookSummary: Identifiable {
        let id: String
        let title: String
    }

    private var downloadedBooks: [DownloadedBookSummary] {
        DownloadManager.shared.downloadedItems
            .compactMap { id in DownloadManager.shared.manifest(for: id).map { DownloadedBookSummary(id: id, title: $0.title) } }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            Section {
                healthRow("Downloaded books", value: "\(DownloadManager.shared.downloadedItems.count)")
                healthRow("In progress", value: "\(DownloadManager.shared.activeDownloads.count - pausedCount)")
                healthRow("Paused", value: "\(pausedCount)")
            } header: {
                RetroSectionHeader(title: "Summary")
            }
            .listRowBackground(Color.shelfCard)

            if !active.isEmpty {
                Section {
                    ForEach(active) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .foregroundStyle(Color.shelfCream)
                                    .lineLimit(1)
                                Typo.supporting(Text(task.isPaused ? "Paused" : "\(Int(task.progress * 100))%"))
                                    .foregroundStyle(Color.shelfMuted)
                            }
                            Spacer()
                            if task.isPaused {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundStyle(Color.shelfAmberText)
                            }
                        }
                    }
                } header: {
                    RetroSectionHeader(title: "Transfers")
                }
                .listRowBackground(Color.shelfCard)
            }

            if !downloadedBooks.isEmpty {
                Section {
                    ForEach(downloadedBooks, id: \.id) { book in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(book.title)
                                    .foregroundStyle(Color.shelfCream)
                                    .lineLimit(1)
                                Spacer()
                                if let report = healthReports[book.id] {
                                    Image(systemName: report.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        // Finding 21 (code review, 26 August 2026): raw `.green`
                                        // replaced with the app's accent token for consistency
                                        // and Light-theme contrast (same fix as BookDetailView).
                                        // Batch 490 (REVIEW 2026-11-11 V6): "healthy" is a quiet cream
                                        // check, not the second accent (teal reads as finished).
                                        .foregroundStyle(report.isHealthy ? Color.shelfCream : Color.shelfOrange)
                                        // Critique 2026-10-06 (colorize): alarm is shelfOrange (DESIGN.md), not raw red.
                                        // HIG audit 2026-09-17 L8: the glyph carried no label,
                                        // so VoiceOver read nothing at this stop.
                                        .accessibilityLabel(report.isHealthy ? "Healthy" : "Needs repair")
                                }
                            }
                            if let report = healthReports[book.id], !report.isHealthy {
                                Typo.supporting(Text(Self.repairSummary(broken: report.brokenTracks.count, total: report.tracks.count)))
                                    .foregroundStyle(Color.shelfMuted)
                            }
                            HStack(spacing: 16) {
                                // HIG audit 2026-09-17 H5: two buttons in one `HStack` inside a
                                // `List` row, with no `.buttonStyle`, collapse into one row-wide
                                // tap target under SwiftUI's default `List` row button behavior —
                                // a tap on either label could dispatch both closures. Same fix
                                // (and the same reasoning) as `ActiveDownloadRow` in
                                // `DownloadsView.swift`: `.buttonStyle(.borderless)` restores each
                                // as its own independent tap target, and the explicit frame +
                                // `contentShape` gives each a real 44x44 pt hit region even though
                                // the visible label is caption-sized text, not a glyph.
                                if verifyingIds.contains(book.id) {
                                    // LS-11 (docs/design-review.md, Round 3): Verify had no
                                    // in-flight state at all, unlike Repair below — mirror
                                    // that spinner so a slow verify pass over a big book
                                    // doesn't look like a dropped tap.
                                    // LS-13 (docs/design-review.md, Round 3): brand-tinted,
                                    // was falling back to the system tint.
                                    ProgressView()
                                        .shelfSpinner()
                                        .scaleEffect(0.7)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .accessibilityLabel("Verify")
                                        .accessibilityValue("Verifying")
                                } else {
                                    Typo.supporting(Button("Verify") {
                                        // Item 25 (Batch 313): the per-track file reads now run off
                                        // main inside `verifyDownloadAsync`; the Button action is
                                        // synchronous, so hop into a Task to await it.
                                        verifyingIds.insert(book.id)
                                        Task {
                                            defer { verifyingIds.remove(book.id) }
                                            healthReports[book.id] = await DownloadManager.shared.verifyDownloadAsync(itemId: book.id)
                                        }
                                    }, weight: .bold)
                                    // Critique 2026-10-06 (colorize): action text, not "finished" teal.
                                    .foregroundStyle(Color.shelfAmberText)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                                    .buttonStyle(.borderless)
                                    // LS-11: don't let a per-book Verify race that same
                                    // book's Repair, or start mid "Verify all".
                                    .disabled(repairingIds.contains(book.id) || isVerifyingAll)
                                }

                                if let report = healthReports[book.id], !report.isHealthy {
                                    if repairingIds.contains(book.id) {
                                        // LS-13 (docs/design-review.md, Round 3):
                                        // brand-tinted, was falling back to the system tint.
                                        ProgressView().shelfSpinner().scaleEffect(0.7)
                                    } else {
                                        Typo.supporting(Button("Repair") {
                                            repairingIds.insert(book.id)
                                            Task {
                                                _ = await DownloadManager.shared.repairDownload(itemId: book.id)
                                                // The repair kicks off real background download
                                                // tasks rather than awaiting their completion (they
                                                // finish via the shared session delegate, same as any
                                                // other download) — give them a moment before
                                                // re-checking on disk so "Repair" doesn't immediately
                                                // flip back to showing the same failure.
                                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                                healthReports[book.id] = await DownloadManager.shared.verifyDownloadAsync(itemId: book.id)
                                                repairingIds.remove(book.id)
                                            }
                                        }, weight: .bold)
                                        // Critique 2026-10-06 (colorize): Repair isn't destructive.
                                        .foregroundStyle(Color.shelfAmberText)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                        .buttonStyle(.borderless)
                                        // LS-11: Repair would re-download over a track that a
                                        // fresh Verify pass (per-book or "Verify all") is
                                        // still reading.
                                        .disabled(verifyingIds.contains(book.id) || isVerifyingAll)
                                    }
                                }
                            }
                            .shelfAnimation(.default, value: verifyingIds)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        isVerifyingAll = true
                        Task {
                            defer { isVerifyingAll = false }
                            for book in downloadedBooks {
                                healthReports[book.id] = await DownloadManager.shared.verifyDownloadAsync(itemId: book.id)
                            }
                        }
                    } label: {
                        // LS-11 (docs/design-review.md, Round 3): "Verify all" walked every
                        // downloaded book's track files with no visible sign it was working
                        // — on a big library it looked like the tap did nothing. Swap only
                        // the leading glyph for a spinner so the row's size stays stable.
                        if isVerifyingAll {
                            settingRowLabel(text: "Verifying\u{2026}", tint: Color.shelfAmberText) {
                                // LS-13 (docs/design-review.md, Round 3): brand-tinted,
                                // was falling back to the system tint.
                                ProgressView().shelfSpinner().scaleEffect(0.7)
                            }
                        } else {
                            settingRowLabel("checkmark.seal", "Verify all downloads", tint: Color.shelfAmberText)
                        }
                    }
                    .disabled(isVerifyingAll)
                    .accessibilityLabel(isVerifyingAll ? "Verifying all downloads" : "Verify all downloads")
                    .shelfAnimation(.default, value: isVerifyingAll)
                } header: {
                    RetroSectionHeader(title: "Downloaded Books")
                } footer: {
                    Typo.supporting(Text("Verify checks each downloaded file for missing, empty, or corrupted tracks. Repair re-downloads only the broken ones \u{2014} your progress and the rest of the book are untouched."))
                        .foregroundStyle(Color.shelfMuted)
                }
                .listRowBackground(Color.shelfCard)
            }

            Section {
                Button {
                    DownloadManager.shared.reloadForActiveScope()
                } label: {
                    settingRowLabel("arrow.clockwise", "Reload for current account", tint: Color.shelfAmberText)
                }

                Button(role: .destructive) {
                    showRemoveAllConfirm = true
                } label: {
                    // Critique 2026-10-06 (colorize): no raw red; the destructive role colours it.
                    HStack {
                        Image(systemName: "trash.fill").frame(width: 24)
                        Text("Remove All Downloads")
                    }
                }
            } header: {
                RetroSectionHeader(title: "Repair")
            } footer: {
                Typo.supporting(Text("\u{201C}Reload\u{201D} re-reads this account\u{2019}s download index (use it if downloads look out of sync after switching accounts). \u{201C}Remove all\u{201D} deletes only the current account\u{2019}s downloaded files."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Download Health")
        .navigationBarTitleDisplayMode(.inline)
        // T10 (REVIEW_2026-09-04_UI.md): unified with DownloadsSettingsView's "Remove
        // All Downloads" action — same presentation style, button order, and wording,
        // via `RemoveAllDownloadsCopy`.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .confirmationDialog(RemoveAllDownloadsCopy.title, isPresented: $showRemoveAllConfirm, titleVisibility: .visible) {
            Button(RemoveAllDownloadsCopy.confirm, role: .destructive) {
                DownloadManager.shared.removeAllDownloads()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(RemoveAllDownloadsCopy.message(storageUsed: DownloadManager.shared.formattedStorageUsed))
        }
        .systemChromeTint()
        .reexpandsTabBarOnAppear()
    }

    /// Critique 2026-10-06 (clarify): proper singular/plural instead of "track(s)".
    static func repairSummary(broken: Int, total: Int) -> String {
        // Whole sentences per case (not spliced fragments) so grammar can differ per language.
        if broken == 1 {
            return String(localized: "1 track of \(total) needs repair", comment: "Download health summary. %lld is the total number of tracks.")
        }
        return String(localized: "\(broken) tracks of \(total) need repair", comment: "Download health summary. First %lld is the number of broken tracks (not 1), second is the total.")
    }

    private func healthRow(_ label: LocalizedStringResource, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.shelfCream)
            Spacer()
            Typo.supporting(Text(value)).foregroundStyle(Color.shelfMuted)
        }
    }

    private func settingRowLabel(_ icon: String, _ text: LocalizedStringResource, tint: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(text)
                .foregroundStyle(tint)
        }
    }

    /// LS-11 (docs/design-review.md, Round 3): same layout as `settingRowLabel(_:_:tint:)`
    /// above, but with a custom leading view instead of a named SF Symbol, so an in-flight
    /// spinner can swap in for the icon without changing the row's icon column width or
    /// text baseline.
    private func settingRowLabel<Leading: View>(text: LocalizedStringResource, tint: Color, @ViewBuilder leading: () -> Leading) -> some View {
        HStack {
            leading()
                .frame(width: 24)
            Text(text)
                .foregroundStyle(tint)
        }
    }
}
