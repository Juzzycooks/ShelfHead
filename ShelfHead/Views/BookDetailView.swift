import SwiftUI
import AppIntents

// Critique 2026-10-05 (Book Detail, 2nd): UI-10 came back through pushed detail screens. A
// `BookDetailView` pushed from the series/author/genre pages INSIDE a sheet-presented detail
// is built with `isPresentedModally == false`, so its Play opened the full player (a ZStack
// overlay) behind the still-open sheet. `dismiss()` is no use there: in a pushed context it
// pops one screen, it does not close the sheet. So the sheet's ROOT detail publishes its own
// `dismiss` action through this key, and any detail below it calls that to close the whole
// sheet before asking for the player. (The captured action belongs to the root's environment,
// so invoking it from the pushed screen dismisses the sheet, not the pushed screen.)
private struct BookDetailSheetDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private extension EnvironmentValues {
    /// Non-nil inside a sheet-presented Book Detail's subtree: closes that sheet.
    var bookDetailSheetDismiss: (() -> Void)? {
        get { self[BookDetailSheetDismissKey.self] }
        set { self[BookDetailSheetDismissKey.self] = newValue }
    }
}

struct BookDetailView: View {
    let item: LibraryItem
    // UI-10 (REVIEW_2026-08-12.md): the full player is a `ZStack` overlay inside
    // `ContentView`, not a system sheet — so it renders *behind* an actual `.sheet`.
    // Every call site that presents this view as the root of a sheet-presented
    // `NavigationStack` (`ContentView`'s Spotlight/deep-link `deepLinkedItem`,
    // `PlayerView`'s `showBookDetails` and the queue's `detailItem`) passes `true` here;
    // every plain pushed `NavigationLink` destination (Home, Library, Series, Authors,
    // Collections/Playlists, Downloads) leaves it at the default `false`. Used below to
    // dismiss the enclosing sheet before triggering `showFullPlayer`, so the player
    // actually becomes visible instead of materializing invisibly behind the sheet.
    var isPresentedModally: Bool = false
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bookDetailSheetDismiss) private var inheritedSheetDismiss
    // HIG audit 2026-09-17 M5: drives the metadata grid's accessibility-size layout below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Critique 2026-10-05 (Book Detail): the cover's extra hairline is Dark-only; Light already
    // gets `shelfElevation`'s border, so drawing both gave Light two edges.
    @Environment(\.colorScheme) private var colorScheme
    // Critique 2026-10-06 (distill, user decision): while this screen's pinned Play bar is up the
    // mini player steps aside (one play control). The tab this stack sits in, this screen's
    // owner id, and the token of its live registration; see `updateMiniPlayerSuppression()`.
    @Environment(\.shelfTabIndex) private var shelfTabIndex
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var miniPlayerSuppressionOwner = UUID()
    @State private var miniPlayerSuppressionToken: UUID?
    /// Critique 2026-10-06 (harden): this pushed screen's registration as the host of the
    /// single-book Undo toast (`PlayerViewModel.progressToastHosts`); see `updateProgressToastHost()`.
    @State private var progressToastToken: UUID?
    /// Critique 2026-10-06 (harden): the bookmark fetch failed (it used to look like "no bookmarks").
    @State private var bookmarksLoadFailed = false
    @State private var isOnScreen = false
    @State private var detailedItem: LibraryItem?
    // Design review (14 Aug 2026), item 4: chapters/bookmarks used to expand inline in
    // the scroll body — replaced with a compact row that opens a sheet (see
    // `chaptersRow`/`bookmarksRow` and the `.sheet` modifiers in `body`), demoting them
    // to reference material you open on demand rather than something scrolled past on
    // every visit to this screen.
    @State private var showChaptersSheet = false
    @State private var showBookmarksSheet = false
    /// Batch 424: Search in Book sheet.
    @State private var showTranscriptSearch = false
    @State private var isLoading = true
    /// Polish pass (J3-4): the detail fetch failed with no local copy to show.
    @State private var detailLoadFailed = false
    @State private var downloadManager = DownloadManager.shared
    @State private var strippedDescription = ""   // HTML stripped once, off the render path
    @State private var bookmarks: [AudioBookmark] = []
    @State private var showResetConfirm = false
    @State private var showRemoveDownloadConfirm = false
    @State private var shareSession: ShareSession?
    @State private var editingBookmark: AudioBookmark?
    @State private var editNoteText = ""
    // Local free-text note (not the server `title`), edited alongside it below.
    @State private var editNoteBody = ""
    @State private var notesStore = BookmarkNotesStore.shared
    /// Critique 2026-10-06 (harden): Delete in the bookmark sheet offers Undo, through the
    /// shared `BookmarkDeleteUndo` (also used by the player's sheet and All Bookmarks).
    @State private var bookmarkUndo = BookmarkDeleteUndo()
    /// Critique 2026-10-06 (harden): Edit Bookmark's Save waits for the result; a failure
    /// keeps the sheet open with this message.
    @State private var editSaveError: String?
    @State private var isSavingEdit = false
    /// Critique 2026-10-06 (harden): a short note from the ••• menu's series actions when
    /// there was nothing to do ("no next book", "nothing to download").
    @State private var menuNotice: String?
    /// Batch 450: read here too so the Transcript row's place in `bookToolsList` follows the setting.
    @AppStorage(SettingsKeys.transcriptsEnabled) private var transcriptsEnabled = true
    /// Batch 490 (REVIEW 2026-11-11 F19): the Siri tip's own close button turns this off for good.
    @AppStorage("bookDetail.siriTipVisible") private var siriTipVisible = true
    @State private var exportPayload: SharePayload?
    @State private var descriptionExpanded = false
    @State private var showEbookReader = false
    // Batch 490 (REVIEW 2026-11-11 F11a): e-reader devices the server lets this user send to (empty = no menu item).
    @State private var eReaderDevices: [EReaderDevice] = []
    @State private var showEReaderDialog = false
    @State private var recapText: String?
    @State private var recapIsGenerated = false
    /// Batch 428: "Previously On…" offered in the recap card after a few days away (iOS 26+).
    @State private var recapOfferShown = false
    @State private var showIntelligenceRecap = false
    /// Batch 429: X-Ray and Ask the Book sheets.
    @State private var showXRay = false
    @State private var showAskBook = false
    /// Batch 454/455: Recommend to… and Book Club (both need a household).
    @State private var showRecommend = false
    @State private var showBookClub = false
    @State private var householdStore = HouseholdStore.shared

    private var displayItem: LibraryItem {
        detailedItem ?? item
    }

    /// Batch 427 (Section E): bumped when chapters made on this device are saved or reset, so
    /// the resolved list below (read through a non-observable cache) is read again.
    @State private var chapterOverrideRevision = 0

    /// The chapters this screen shows and counts: the ones made on this device when they
    /// still apply, else the server's.
    private var displayChapters: [Chapter] {
        _ = chapterOverrideRevision
        return ChapterOverrideStore.resolvedChapters(itemId: displayItem.id, server: displayItem.chapters)
    }

    /// No "couldn't read N chapters" note once the server's list has been replaced.
    private var displayDroppedChapterCount: Int {
        _ = chapterOverrideRevision
        return ChapterOverrideStore.isApplied(itemId: displayItem.id, server: displayItem.chapters)
            ? 0 : displayItem.droppedChapterCount
    }

    /// Critique 2026-10-05 (Book Detail, 2nd): closes the enclosing sheet, if any, before the
    /// full player is asked to show. Root of a sheet: `dismiss()` closes it. Pushed inside a
    /// sheet: `dismiss()` would only pop, so use the root's action from the environment.
    private func closeSheetIfModal() {
        if isPresentedModally {
            dismiss()
        } else {
            inheritedSheetDismiss?()
        }
    }

    /// Prefer the shared progress map (kept current across the app), falling back to
    /// whatever progress the item itself carries.
    private var resolvedProgress: Double {
        libraryViewModel.progressFor(itemId: displayItem.id)?.progress ?? displayItem.progressPercent
    }

    private var resolvedFinished: Bool {
        libraryViewModel.progressFor(itemId: displayItem.id)?.isFinished ?? displayItem.isFinished
    }

    /// Position (seconds) used to shade each chapter row as finished / in-progress in
    /// the chapter sheet (see `ChapterRow`) — P-5 (REVIEW_2026-09-14_DESIGN.md). Live
    /// playback position when this book is the one actually playing right now,
    /// otherwise the book's last-saved progress translated into seconds so a book
    /// that isn't currently playing still shows which chapters were already heard.
    private var chapterProgressPosition: Double {
        if playerViewModel.currentBook?.id == displayItem.id {
            return playerViewModel.currentTime
        }
        return resolvedProgress * displayItem.duration
    }

    /// Listening time left for an in-progress book at its resolved speed, e.g.
    /// "≈3h 20m left at 1.5×". Nil for finished / unstarted books.
    private var listeningTimeLeftText: String? {
        guard !resolvedFinished, resolvedProgress > 0 else { return nil }
        let duration = displayItem.duration
        guard duration > 0 else { return nil }
        let remaining = duration * (1 - min(resolvedProgress, 1))
        guard remaining > 60 else { return nil }
        let speed = SettingsStore.resolvedSpeed(forItem: displayItem.id)
        let listening = remaining / max(speed, 0.1)
        let speedText = String(format: "%g×", speed)
        // Critique 2026-10-05 (Book Detail, 2nd): one "time left" form everywhere: speed-adjusted
        // with a leading ≈ (the loaded-state readout says "≈… left in book" the same way).
        return speed != 1
            ? String(localized: "≈\(listening.formattedDuration) left in book at \(speedText)", comment: "Time left in a book at the listener's speed; %1$@ is a duration like 3h 20m, %2$@ is a speed like 1.5×")
            : String(localized: "≈\(listening.formattedDuration) left in book", comment: "Time left in a book; %@ is a duration like 3h 20m")
    }

    /// Nav-bar miscellany menu contents; shared by the legacy Menu and the iOS 27 system
    /// overflow menu (iPhone Duo §2).
    @ViewBuilder private var moreOptionsMenuContent: some View {
        // Batch 449: the menu had grown to seven rows. When another book is playing, the two Up
        // Next actions and Share sit in one row of icons at the top (`ControlGroup` inside a menu,
        // iOS 15+), so the list itself is three rows. Download Series left the menu: the series
        // page (the series link in the header) has Download All.
        if playerViewModel.currentBook != nil, playerViewModel.currentBook?.id != displayItem.id {
            ControlGroup {
                Button {
                    playerViewModel.playNext(displayItem)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    playerViewModel.addToQueue(displayItem)
                } label: {
                    Label(String(localized: "Up Next", comment: "Book Detail menu: short label for Add to Up Next in the row of icons"),
                          systemImage: "text.badge.plus")
                }
                .accessibilityLabel("Add to Up Next")
                shareProgressButton(title: String(localized: "Share", comment: "Book Detail menu: short label for Share Progress in the row of icons"))
            }
        }

        // Series action (best-effort; see nextInSeries).
        if displayItem.seriesName != nil {
            Button {
                Task {
                    // Critique 2026-10-06 (harden): a miss used to do nothing at all.
                    if let next = await libraryViewModel.nextInSeries(after: displayItem) {
                        playerViewModel.addToQueue(next)
                    } else {
                        menuNotice = Self.noNextInSeriesNotice
                    }
                }
            } label: {
                Label("Queue Next in Series", systemImage: "books.vertical")
            }
            Divider()
        }

        // Batch 490 (REVIEW 2026-11-11 F11a): email the ebook to an e-reader the server's admin has set up.
        // Only with an ebook file here and at least one device the server offers this user.
        if displayItem.media?.ebookFile != nil, !eReaderDevices.isEmpty {
            Button {
                showEReaderDialog = true
            } label: {
                Label("Send to E-reader…", systemImage: "paperplane")
            }
        }

        // Batch 454: send this book to people in your household.
        if householdStore.isSocialAvailable && !displayItem.isPodcast {
            Button {
                showRecommend = true
            } label: {
                Label("Recommend to…", systemImage: "person.2")
            }
        }

        if resolvedFinished {
            Button {
                runProgressAction { await libraryViewModel.markUnfinished(item: displayItem) }
            } label: {
                Label("Mark as Not Finished", systemImage: "circle")
            }
        } else {
            Button {
                runProgressAction { await libraryViewModel.markFinished(item: displayItem) }
            } label: {
                Label("Mark as Finished", systemImage: "checkmark.circle")
            }
        }

        if resolvedProgress > 0 || resolvedFinished {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset Progress", systemImage: "arrow.counterclockwise")
            }
        }

        // Nothing else playing: no icon row, so Share stays a row of its own at the end.
        if playerViewModel.currentBook == nil || playerViewModel.currentBook?.id == displayItem.id {
            Divider()
            shareProgressButton(title: String(localized: "Share Progress"))
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 F11a): `POST /api/emails/send-ebook-to-device`. Success and failure both
    /// show as the same toast the other menu actions use; a failure is one plain sentence (the server's reason,
    /// usually an unfinished mail setup, isn't something the app can fix).
    private func sendToEReader(_ device: EReaderDevice) {
        let itemId = displayItem.id
        Task {
            do {
                try await AudiobookshelfAPI.shared.sendEbookToDevice(itemId: itemId, deviceName: device.name)
                menuNotice = String(localized: "Sent to \(device.name).", comment: "Toast after emailing an ebook to an e-reader; %@ is the device name")
            } catch {
                menuNotice = String(localized: "Couldn’t send that to \(device.name). Check that your server can send email, then try again.", comment: "Toast when emailing an ebook to an e-reader fails; %@ is the device name")
            }
        }
    }

    private func shareProgressButton(title: String) -> some View {
        Button {
            Task { await presentShare() }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share Progress")
    }

    private var moreOptionsMenu: some View {
        Menu {
            moreOptionsMenuContent
        } label: {
            // LG-2 (docs/visual-design-review.md, Round V1): plain symbol, not the
            // circle variant — the glass toolbar container already draws the ring.
            Label("More options", systemImage: "ellipsis")
        }
        .monochromeToolbarItem()
    }

    var body: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Cover Art & Info Header
                    headerSection

                    // A podcast show is played episode-by-episode, not as one continuous
                    // "book" — the usual Play/download actions below assume the latter, so
                    // podcasts get their own episode list instead (see `episodesSection`).
                    // Scope note: streaming-only for now, no per-episode downloads yet.
                    if displayItem.isPodcast {
                        episodesSection
                    } else if displayItem.isEbookOnly, let note = ebookFormatNote {
                        // Critique 2026-10-05 (Book Detail): the Read button itself is pinned
                        // now (see `pinnedEbookBar`); only the unsupported-format note stays inline.
                        Typo.fine(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                            .multilineTextAlignment(.center)
                    }
                    // Design review (14 Aug 2026), item 4: Play/Resume moved out of
                    // the scroll body entirely, into `pinnedPlayBar` below (a
                    // `safeAreaInset(edge: .bottom)` bar) — it's the one thing this
                    // screen exists for, and used to be competing for attention with
                    // "Show more" on the description and a genre chip row further
                    // down, reachable only by scrolling past however long the
                    // description happened to be.
                    //
                    // P-4 (REVIEW_2026-09-14_DESIGN.md): the download action used to
                    // render here too, as its own full-width "Download for Offline"
                    // block — the first thing under the cover, ahead of About/Genres,
                    // which made a secondary action outrank the jacket itself. It now
                    // lives as a compact icon button in `headerSection`'s metadata row,
                    // right beside the duration/chapter-count line — see
                    // `BookDetailDownloadSection` below for the same states (not
                    // downloaded / downloading / paused / downloaded / failed-retry)
                    // moved into that compact form.

                    // Spinner while the detailed item (description, chapters, bookmarks)
                    // is still loading, so the sections don't just pop in silently.
                    if isLoading && detailedItem == nil {
                        ProgressView()
                            // U6 (REVIEW_2026-08-20_UI_SECURITY.md): raw `shelfAmber` as a
                            // spinner tint is a foreground, not a fill — 1.87:1 in Light,
                            // under the 3:1 non-text floor. `shelfAmberText` (no opacity)
                            // is the safe token. LS-13 (docs/design-review.md, Round 3):
                            // routed through the shared `.shelfSpinner()` helper.
                            .shelfSpinner()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }

                    // Design review (14 Aug 2026), item 4: Chapters/Bookmarks demoted
                    // from full inline (collapsible) sections to compact rows that open
                    // a sheet — see `chaptersRow`/`bookmarksRow`. They're structurally
                    // reference material (checking where you are, jumping to a saved
                    // moment), not part of deciding whether to listen, so they no
                    // longer add their own full list length to this screen's scroll.
                    // Batch 450: Chapters, Bookmarks, Transcript, X-Ray, Ask the Book and Read the
                    // Book were up to five separate cards. They are now one grouped list of rows
                    // (HIG Lists and tables: inset grouped rows with a trailing value and chevron).
                    if detailLoadFailed {
                        detailLoadFailedRow
                    }

                    bookToolsList

                    // Item 11 (REVIEW-2026-09-09-REMAINING.md): chapters the server sent
                    // in a shape this client can't use are dropped rather than failing
                    // the whole item (see `Media.init(from:)`), so the reader is told
                    // once, quietly, instead of the book silently having fewer chapters
                    // than the server shows. Only shown here when EVERY chapter was
                    // dropped — the row above is then hidden (there is no list to open),
                    // and the book would otherwise read as simply chapterless. When some
                    // chapters survived, the same note is the last row of the chapter
                    // sheet, next to the list it describes.
                    if displayChapters.isEmpty,
                       let note = Chapter.droppedChapterNote(count: displayDroppedChapterCount) {
                        Typo.supporting(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    // Critique 2026-10-05 (Book Detail): Chapters/Bookmarks now sit above
                    // Details (they are the "where am I / jump" tools; Details is last-resort
                    // reference).
                    detailsSection

                    // Batch 490 (REVIEW 2026-11-11 F19): the system Siri tip for "Play <book> in
                    // ShelfHead" (the App Shortcut in `ShelfHeadShortcuts`), last on the page so it
                    // never sits between the reader and the book. Audiobooks only; dismissing it
                    // hides it on every book.
                    if !displayItem.isPodcast && !displayItem.isEbookOnly {
                        SiriTipView(intent: Self.playIntent(for: displayItem), isVisible: $siriTipVisible)
                            .siriTipViewStyle(.automatic)
                    }

                    // Critique 2026-10-05 (Book Detail): the trailing `Spacer(minLength:)` is
                    // gone. Inside a scroll view it never stretched, so it was only a dead band
                    // above the pinned bar; the bar's safe-area inset already reserves the space.
                }
                // Batch 218 (R9): propagates `Space.pageH` — this screen used 16pt
                // margins like `LibraryView`/`SeriesBrowseView`, one of the review's
                // named mismatches against Home/Downloads' 20pt. No grid here, so
                // no column-solve arithmetic needed first (unlike `LibraryView`).
                .padding(.horizontal, Space.pageH)
                .padding(.top, 16)
                // Cap + centre the column on iPad / landscape so it doesn't stretch.
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        // Design review (14 Aug 2026), item 4: pins Play/Resume (+ a compact progress
        // readout) to the bottom of the screen for the standard audiobook case, so it's
        // reachable without scrolling regardless of how long the description or genre
        // list happens to be — the one thing this screen exists for. Podcasts/ebooks
        // don't get this bar: they each have their own clear per-row entry point
        // (episode rows, the "Read" button) instead of one book-level Play action.
        //
        // LG-1 (docs/visual-design-review.md, Round V2): on iOS 26+ this is a
        // `safeAreaBar`, so the system draws its scroll-edge effect and content dissolves
        // under the bar instead of showing through a hand-built translucent slab. The
        // iOS 17–25 path keeps `safeAreaInset` and the card-coloured material. See
        // `PinnedBottomBar`.
        // Critique 2026-10-06 (harden): inside the pinned bar's inset, so the note sits above
        // the Play bar rather than on it.
        .toast(message: $menuNotice, style: .info, duration: 3)
        // Critique 2026-10-06 (harden): the single-book Mark Finished / Reset Undo, hosted here
        // (inside the pinned bar's inset, like the note above) so it sits above the Play bar.
        // Was: modal details hosted it after the bar (so on top of it), and pushed details left
        // it to `ContentView`'s root slot, whose inset only knows the tab bar. A pushed screen
        // registers as the host (`progressToastToken`) and the root copy stands down; in a sheet
        // the root is covered anyway.
        .toast(message: hostsProgressUndo ? Binding(
                    get: { libraryViewModel.progressUndoMessage },
                    set: { libraryViewModel.progressUndoMessage = $0 }
               ) : .constant(nil),
               style: .success, duration: 6,
               action: ToastAction(label: "Undo") { libraryViewModel.undoLastProgressChange() })
        .modifier(PinnedBottomBar {
            pinnedBar
        })
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
            // F9 (REVIEW_2026-09-04_UI.md): presented as a sheet (deep link, Spotlight,
            // Handoff) this screen had no visible way out — the nav bar held only the
            // overflow menu, and the sheet's own grabber is the sole affordance. Pushed
            // from Library it gets a real back button, so this is scoped to the modal
            // case rather than adding a redundant second dismiss to the pushed one.
            if isPresentedModally {
                ToolbarItem(placement: .topBarLeading) {
                    // iPhone Duo (§2): a titled Label so the item can sit in the side bar.
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .monochromeToolbarItem()
                }
            }
            #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.0, *) {
                // iPhone Duo (§2): fold the app-owned "more" menu into the system overflow menu.
                ToolbarOverflowMenu { moreOptionsMenuContent }
            } else {
                ToolbarItem(placement: .topBarTrailing) { moreOptionsMenu }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) { moreOptionsMenu }
            #endif
        }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .confirmationDialog("Reset progress for this book?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset Progress", role: .destructive) {
                runProgressAction { await libraryViewModel.resetProgress(item: displayItem) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Critique 2026-10-06 (harden): Reset now has an Undo toast
            // (`LibraryViewModel.progressUndoMessage`), so the copy no longer says it can't.
            Text("This clears your listening position and finished status on the server. You can undo this right after.")
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        // Critique 2026-10-06 (harden): shared wording with the List swipe and long-press menu.
        .confirmationDialog(RemoveDownloadConfirmation.title,
                            isPresented: $showRemoveDownloadConfirm, titleVisibility: .visible) {
            Button(RemoveDownloadConfirmation.button, role: .destructive) {
                downloadManager.removeDownload(itemId: displayItem.id)
                Haptics.impact(.medium)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RemoveDownloadConfirmation.message(title: displayItem.title))
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        // Batch 490 (REVIEW 2026-11-11 F11a): pick the device; the result comes back as the menu's toast.
        .confirmationDialog("Send to E-reader", isPresented: $showEReaderDialog, titleVisibility: .visible) {
            ForEach(eReaderDevices) { device in
                Button(device.name) { sendToEReader(device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your server emails the ebook to the device you choose.")
        }
        .systemChromeTint()
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        // Batch 490 (REVIEW 2026-11-11 F11a): the device list only matters for a book with an ebook file.
        .task(id: displayItem.media?.ebookFile != nil) {
            guard displayItem.media?.ebookFile != nil else { eReaderDevices = []; return }
            eReaderDevices = (try? await AudiobookshelfAPI.shared.getEReaderDevices()) ?? []
        }
        .sheet(item: $shareSession) { session in
            ShareComposerSheet(context: session.context)
        }
        // Left as a plain full-height sheet, deliberately not given
        // `.presentationDetents` in the polish pass below — `EbookReaderView` is a
        // full reading surface, not a list peek, so a partial-height presentation
        // would just crop the page rather than offer a useful "glance and dismiss."
        .sheet(isPresented: $showEbookReader) {
            EbookReaderView(item: displayItem, onListen: { time in listenFromReader(at: time) })
        }
        // Design review (14 Aug 2026), item 4: Chapters/Bookmarks demoted to sheets.
        // iOS 26/27 Liquid Glass polish pass (26 August 2026): added
        // `.presentationDetents([.medium, .large])` + `.presentationDragIndicator`,
        // matching the same fix made to `PlayerView`'s `ChapterListSheet`/
        // `BookmarksSheet`. `.presentationBackground(.thinMaterial)` deliberately
        // NOT added here either — `chaptersSheetContent`/`bookmarksSheetContent`
        // both paint their own opaque `Color.shelfBackground.ignoresSafeArea()`, so
        // it would sit invisibly behind that fill; see `PlayerView`'s identical note
        // on its own three sheets for the full reasoning.
        .onReceive(NotificationCenter.default.publisher(for: .shelfheadChapterOverrideChanged)) { _ in
            chapterOverrideRevision += 1
        }
        .sheet(isPresented: $showChaptersSheet) {
            chaptersSheetContent
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTranscriptSearch) {
            TranscriptSearchSheet(itemId: displayItem.id, bookTitle: displayItem.title,
                                  chapters: displayChapters,
                                  onSelect: { time in jumpFromSheet { playerViewModel.seek(to: time, reason: .search) } })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showIntelligenceRecap) {
            // Batch 490 (REVIEW 2026-11-11 P5): this book may not be the loaded one, so hand the
            // sheets its chapters; moments then read "12:44 · Chapter 3" as they do in the player.
            RecapSheet(itemId: displayItem.id, title: displayItem.title, author: displayItem.authorName,
                       chapters: displayChapters)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showXRay) {
            XRaySheet(itemId: displayItem.id, title: displayItem.title,
                      onSeek: { time, reason in jumpFromSheet { playerViewModel.seek(to: time, reason: reason) } },
                      chapters: displayChapters)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAskBook) {
            AskBookSheet(itemId: displayItem.id, title: displayItem.title, author: displayItem.authorName,
                         onSeek: { time, reason in jumpFromSheet { playerViewModel.seek(to: time, reason: reason) } },
                         chapters: displayChapters)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecommend) {
            RecommendBookSheet(item: displayItem)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBookClub) {
            BookClubView(item: displayItem, chapters: displayChapters,
                         myPositionSeconds: chapterProgressPosition, isFinished: resolvedFinished)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBookmarksSheet) {
            bookmarksSheetContent
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task { await loadDetail() }
        .reexpandsTabBarOnAppear()
        // Critique 2026-10-06 (distill): hide the mini player while this pinned bar is up.
        .onAppear {
            isOnScreen = true
            updateMiniPlayerSuppression()
            updateProgressToastHost()
        }
        .onDisappear {
            isOnScreen = false
            updateMiniPlayerSuppression()
            updateProgressToastHost()
        }
        // The detail fetch can turn a placeholder into an ebook-only item (no play control).
        .onChange(of: suppressesMiniPlayer) { _, _ in updateMiniPlayerSuppression() }
        // Only the sheet's root publishes its dismiss action; pushed details keep inheriting it.
        .transformEnvironment(\.bookDetailSheetDismiss) { value in
            if isPresentedModally { value = { dismiss() } }
        }
    }

    /// Polish pass (J3-4 / CR-3): the detail fetch used to be silent on failure and the spinner
    /// also waited on bookmarks. Now a failed fetch falls back to the local download manifest
    /// (so a downloaded book still shows chapters offline), else shows a Retry row, and the
    /// spinner clears as soon as the detail is settled — bookmarks load after.
    private func loadDetail() async {
        detailLoadFailed = false
        isLoading = true
        // Strip the description's HTML once here, not in body — NSAttributedString
        // HTML parsing is expensive and was running on every re-render.
        strippedDescription = (item.description ?? "").strippingHTML
        var detailed = await libraryViewModel.getItemDetail(itemId: item.id)
        if Task.isCancelled { return }
        if detailed == nil {
            // Offline / unreachable: a downloaded book carries its chapters in the manifest.
            if let local = DownloadManager.shared.libraryItem(for: item.id) {
                // Only adopt the manifest copy when it adds chapters the row item lacks, so
                // it never replaces richer metadata the caller already passed in.
                if item.chapters.isEmpty, !local.chapters.isEmpty { detailed = local }
            } else {
                detailLoadFailed = true
            }
        }
        if let detailed {
            detailedItem = detailed
            TranscriptionCenter.shared.noteBookLanguage(detailed.media?.metadata?.language, for: detailed.id)
            if let d = detailed.description, !d.isEmpty {
                strippedDescription = d.strippingHTML
            }
            updateRecapOffer(for: detailed)
            if !detailed.isPodcast, let f = RecapGenerator.facts(for: detailed, description: strippedDescription) {
                recapText = RecapGenerator.templateRecap(f)
                Task {
                    if let m = await RecapGenerator.modelRecap(f) {
                        recapText = m
                        recapIsGenerated = true
                    }
                }
            }
        }
        isLoading = false
        await reloadBookmarks(itemId: item.id)
    }

    /// "Couldn’t load details · Retry", shown when the detail fetch failed and there is no
    /// local copy to fall back on (Polish pass J3-4).
    private var detailLoadFailedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color.shelfMuted)
                .accessibilityHidden(true)
            Typo.supporting(Text("Couldn’t load the full details. Check your connection and try again."))
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Haptics.selection()
                Task { await loadDetail() }
            } label: {
                Typo.supporting(Text("Retry"), weight: .semibold)
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading details")
        }
        .padding(.horizontal, 4)
    }

    /// Critique 2026-10-06 (distill): whether this screen's pinned bar should replace the mini
    /// player. In a sheet (root or pushed inside one) the sheet already covers the mini player.
    private var suppressesMiniPlayer: Bool {
        MiniPlayerSuppression.detailSuppresses(
            isPodcast: displayItem.isPodcast,
            isEbookOnly: displayItem.isEbookOnly,
            inSheet: isPresentedModally || inheritedSheetDismiss != nil)
    }

    /// Registers this screen with `PlayerViewModel.miniPlayerSuppression` while it is on screen
    /// and its bar has a play control; releases it otherwise. The release waits one run-loop
    /// turn and quotes its token, so pushing book → book (the old one disappears, the new one
    /// appears) never shows the mini player for a frame, and a quick return to this screen
    /// isn't undone by its own late release. Animated unless Reduce Motion is on.
    private func updateMiniPlayerSuppression() {
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.25)
        let owner = miniPlayerSuppressionOwner
        let player = playerViewModel
        if isOnScreen && suppressesMiniPlayer {
            guard miniPlayerSuppressionToken == nil else { return }
            withAnimation(animation) {
                miniPlayerSuppressionToken = player.miniPlayerSuppression.register(owner, tab: shelfTabIndex)
            }
        } else if let token = miniPlayerSuppressionToken {
            miniPlayerSuppressionToken = nil
            DispatchQueue.main.async {
                withAnimation(animation) {
                    player.miniPlayerSuppression.release(owner, token: token)
                }
            }
        }
    }

    /// Critique 2026-10-06 (harden): whether this screen shows the single-book Undo toast. In a
    /// sheet (root or pushed inside one) always; pushed in a tab while it is the registered host.
    private var hostsProgressUndo: Bool {
        isPresentedModally || inheritedSheetDismiss != nil || progressToastToken != nil
    }

    /// Registers this pushed screen as the Undo toast's host while it is on screen, so
    /// `ContentView`'s root copy (which would land on the pinned bar) stands down. Same
    /// token-checked, one-run-loop-deferred release as `updateMiniPlayerSuppression()`.
    private func updateProgressToastHost() {
        let inSheet = isPresentedModally || inheritedSheetDismiss != nil
        let owner = miniPlayerSuppressionOwner
        let player = playerViewModel
        if isOnScreen && !inSheet {
            guard progressToastToken == nil else { return }
            progressToastToken = player.progressToastHosts.register(owner, tab: shelfTabIndex)
        } else if let token = progressToastToken {
            progressToastToken = nil
            DispatchQueue.main.async {
                player.progressToastHosts.release(owner, token: token)
            }
        }
    }

    /// Runs a progress mutation, then refreshes the detail so the UI reflects it.
    private func runProgressAction(_ action: @escaping () async -> Bool) {
        Task {
            _ = await action()
            if let refreshed = await libraryViewModel.getItemDetail(itemId: item.id) {
                detailedItem = refreshed
            }
        }
    }

    /// Loads the cover, builds the card data, and opens the swipeable style picker.
    @MainActor
    private func presentShare() async {
        async let coverA = ShareCardRenderer.loadCover(itemId: displayItem.id)
        async let statsA = AudiobookshelfAPI.shared.getListeningStats()
        async let sessionsA = AudiobookshelfAPI.shared.getListeningSessions(itemsPerPage: 100)
        let cover = await coverA
        let statsModel = try? await statsA
        let sessions = (try? await sessionsA) ?? []
        let duration = displayItem.duration
        let progress = min(max(resolvedProgress, 0), 1)
        let listened = duration * progress
        let speed = SettingsStore.resolvedSpeed(forItem: displayItem.id)
        let speedStr = speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
        let progressData = ProgressShareData(
            progress: progress,
            listened: listened.formattedDuration,
            remaining: "\(max(duration - listened, 0).formattedDuration) remaining",
            speed: speedStr,
            chapters: displayChapters.count
        )
        let stats = ListeningStatistics.from(stats: statsModel, sessions: sessions,
                                             finishedBooks: libraryViewModel.finishedBooksCount,
                                             streak: libraryViewModel.listeningStreak)
        let completion = resolvedFinished ? CompletionShareData(
            totalTime: duration.formattedDuration,
            finishedInDays: nil,
            bookNumber: libraryViewModel.finishedBooksCount) : nil
        let ctx = ShareCardContext(
            itemId: displayItem.id,
            serverId: AuthStore.shared.serverURL,
            userId: AccountStore.currentAccountId ?? "",
            cover: cover,
            title: displayItem.title,
            author: displayItem.authorName,
            narrator: displayItem.narratorName,
            quote: nil,
            chapter: nil,
            progress: progressData,
            completion: completion,
            statistics: stats,
            isFinished: resolvedFinished
        )
        shareSession = ShareSession(context: ctx)
    }

    // MARK: - Header

    /// Design-direction pass (17 Aug 2026), point 6: reworked to read more like a book
    /// jacket — larger artwork, and title/author/narrator/series-position/progress all
    /// clustered together as one block, so this screen answers "what is this and where
    /// am I in it" before the description/metadata below. Two concrete changes from the
    /// prior version: the cover is bigger (200pt → 220pt, the same restrained bump as
    /// the Home hero card's), and a compact progress line now lives in this cluster —
    /// previously the *only* place progress showed on this whole screen was the pinned
    /// bar at the very bottom, so glancing at the jacket itself told you nothing about
    /// where you were in the book.
    private var headerSection: some View {
        VStack(spacing: 16) {
            // P-4 (REVIEW_2026-09-14_DESIGN.md): 220pt was itself a bump from an even
            // smaller original (see the doc comment above), but between it, the title
            // block, and the old full-width download button beneath it, nothing
            // actionable landed inside one 6.1"-phone screen at default text size.
            // Trimmed to 160pt — still clearly the "hero" element on the screen, just
            // not spending a whole screen's height to be one — and the download
            // control moved out of its own block into the compact icon beside the
            // duration/chapter line below, which is the bigger space saving of the two.
            // V3 / IC-1 + IC-2: `CoverImageView` clips at `Radius.card` for this size; `fit`
            // shows a non-square cover whole over a blurred backdrop instead of cropping it.
            // HL-5 (V5): the jacket is about 58% of the width (≈230 pt on a 402 pt phone),
            // capped at 300 pt for landscape and iPad.
            CachedCover(url: shelfCoverURL(itemId: displayItem.id, width: 700), fit: true)
                .aspectRatio(1, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.58, 300) }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                // Critique 2026-10-05 (Book Detail): exactly one hairline edge per DESIGN.md.
                // `shelfElevation` below draws the Light border (and a shadow, no edge, in
                // Dark), so the extra cream stroke is Dark-only.
                .overlay {
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1)
                    }
                }
                // D4 (design brief 2026-08-12): was a flat `.shadow(...)` in both themes
                // — a heavy dark shadow under a cover sitting on Light theme's warm
                // paper reads as grime rather than elevation. `shelfElevation` keeps the
                // shadow in Dark and swaps to a hairline border in Light.
                .shelfElevation(.card, in: RoundedRectangle(cornerRadius: Radius.card))
                // Critique 2026-10-05 (Book Detail): decorative next to the title below, so
                // VoiceOver doesn't stop on an unlabelled image.
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                // Critique 2026-10-05 (Book Detail): was `.title.weight(.bold)` (28pt), which ran
                // to three lines on an iPhone SE and pushed progress, duration and download
                // below the fold. A 22pt rounded bold title (scales with Title 2) keeps the
                // hero-title character (rounded, bold) at a size the first viewport can afford;
                // `Typo.heroTitle` itself (17pt) is sized for a card, not a full screen's title.
                // A series suffix the capsule below already states is trimmed from the title.
                Text(Self.titleRemovingSeriesSuffix(displayItem.title, series: displayItem.seriesName))
                    .scaledFont(22, weight: .bold, design: .rounded, relativeTo: .title2)
                    .foregroundStyle(Color.shelfCream)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
                    .accessibilityAddTraits(.isHeader)

                // Batch 490 (REVIEW 2026-11-11 L9): the server's subtitle, when there is one.
                if let subtitle = Self.displaySubtitle(displayItem.media?.metadata?.subtitle) {
                    Typo.metadata(Text(verbatim: subtitle))
                        .foregroundStyle(Color.shelfMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                }

                // Design-direction pass, point 8: author is descriptive metadata, not
                // an action or current state — was amber, which per that point should
                // be reserved for Play/Resume, selected controls, and progress. Muted
                // like every other secondary detail here now.
                // Critique 2026-10-05 (Book Detail): a link now, like the narrator below.
                // Batch 490 (REVIEW 2026-11-11 L9): was a compare against the English fallback
                // "Unknown Author", which misses the localised fallback (zh-Hans), so there a
                // book without an author linked to an author page for the fallback text. Checks
                // the metadata instead.
                if Self.hasAuthor(displayItem.media?.metadata?.authorName) {
                    NavigationLink(destination: AuthorLinkDestination(name: displayItem.authorName)) {
                        Typo.metadata(Text(displayItem.authorName))
                            .foregroundStyle(Color.shelfMuted)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("By \(displayItem.authorName). Browse this author.")
                } else {
                    Typo.metadata(Text(displayItem.authorName))
                        .foregroundStyle(Color.shelfMuted)
                }

                if let narrator = displayItem.narratorName {
                    NavigationLink(destination: NarratorBooksView(narrator: narrator)) {
                        Typo.supporting(Text("Narrated by \(narrator)"))
                            .foregroundStyle(Color.shelfMuted)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Narrated by \(narrator). Browse this narrator.")
                }

                if let series = displayItem.seriesName {
                    // Design-direction pass, point 6: "series position" clustered in
                    // with the rest of the jacket, not just the series name alone —
                    // whole-number sequences only (a "Book 2.5" novella reads oddly as
                    // a position label), matching `missingSequenceGap`'s own existing
                    // whole-number-only convention for this data.
                    let sequence = displayItem.sequence(inSeriesNamed: series)
                    let wholeSequence = sequence.flatMap { $0.truncatingRemainder(dividingBy: 1) == 0 ? Int($0) : nil }
                    // F6 (REVIEW_2026-09-04_UI.md): only append the position when the
                    // series display name doesn't already carry it — Audiobookshelf
                    // names commonly end in "#15", which made this chip read
                    // "The Primal Hunter #15 · Book 15".
                    let positionSuffix = wholeSequence.flatMap { n -> String? in
                        MediaMetadata.seriesName(series, alreadyStates: n) ? nil : String(localized: " · Book \(String(n))", comment: "Suffix after a series name; %@ is the book number in the series (never digit-grouped)")
                    } ?? ""
                    // Critique 2026-10-05 (Book Detail): the capsule is a link to the series
                    // page. Styling stays neutral (ID-4: teal is "finished", amber is
                    // actions/live state): `shelfSurface` fill, cream text, and a small chevron
                    // as the only affordance.
                    NavigationLink(destination: SeriesLinkDestination(
                        seriesName: displayItem.media?.metadata?.series?.first?.name ?? series)) {
                        HStack(spacing: 4) {
                            Typo.supporting(Text(series + positionSuffix), weight: .medium)
                                .foregroundStyle(Color.shelfCream)
                            Typo.fine(Image(systemName: "chevron.right"), weight: .semibold)
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.shelfSurface)
                        .clipShape(Capsule())
                        // 44 pt hit area without growing the jacket (~28 pt visible capsule);
                        // an outset content shape extends hit-testing past the bounds (shown
                        // in the simulator in Batch 369).
                        .contentShape(VerticalOutsetRect(amount: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Series: \(series + positionSuffix)")
                    .accessibilityHint("Opens the series")
                }

                HStack(spacing: 16) {
                    if displayItem.duration > 0 {
                        Typo.supporting(Label(displayItem.duration.formattedDuration, systemImage: "clock"))
                            .foregroundStyle(Color.shelfMuted)
                    }

                    if !displayChapters.isEmpty {
                        Typo.supporting(Label("\(displayChapters.count) chapters", systemImage: "list.bullet"))
                            .foregroundStyle(Color.shelfMuted)
                    }

                    // P-4 (REVIEW_2026-09-14_DESIGN.md): the download action, moved here
                    // from its own full-width block below the jacket (see the comment in
                    // `body` at the old call site). Podcasts/ebook-only items keep their
                    // own entry points (`episodesSection`/`ebookReadSection`) instead —
                    // same gating `body` already used for the old block.
                    if !displayItem.isPodcast && !displayItem.isEbookOnly {
                        BookDetailDownloadSection(
                            item: displayItem,
                            onRemoveTapped: { showRemoveDownloadConfirm = true }
                        )
                    }
                }
                .padding(.top, 4)

                // Polish pass (DL-4): the failure reason was only the accessibility value of
                // the warning icon's menu, so sighted users never saw why. One short line,
                // next to the control that offers Retry.
                if !displayItem.isPodcast, !displayItem.isEbookOnly,
                   !DownloadManager.shared.isDownloaded(itemId: displayItem.id),
                   !DownloadManager.shared.isDownloading(itemId: displayItem.id),
                   let failure = DownloadManager.shared.failedDownloads[displayItem.id] {
                    Typo.supporting(Text(failure.message))
                        .foregroundStyle(Color.shelfOrangeInk)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true) // the warning button already speaks it
                }

                // Progress, clustered here (not just in the pinned bar below) so the
                // jacket itself answers "where am I" at a glance. Amber fill is
                // deliberate — real progress state, the one thing point 8 explicitly
                // allows amber for outside Play/Resume itself.
                if resolvedProgress > 0 && !resolvedFinished {
                    HStack(spacing: 8) {
                        // Critique 2026-10-05 (Book Detail): was a fixed 120pt bar; it now
                        // flexes up to 160pt so it doesn't crowd the percentage at large sizes.
                        BookProgressBar(progress: resolvedProgress)
                            .frame(maxWidth: 160)
                            .frame(height: 4)
                        Typo.supporting(Text("\(Int(resolvedProgress * 100))%"), weight: .semibold)
                            .foregroundStyle(Color.shelfAmberText)
                        // Critique 2026-10-05 (Book Detail, 2nd): the live equalizer now lives only
                        // in the pinned bar's readout (nearest the action); this header had a
                        // duplicate.
                    }
                    .padding(.top, 2)
                } else if resolvedFinished {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Typo.supporting(Text("Finished"), weight: .medium)
                    }
                    // Finding 21 (code review, 26 August 2026): raw `.green` was
                    // inconsistent with LibraryView's `shelfAccent`/`shelfCream` tokens
                    // for this same "finished" state, and failed WCAG AA (~1.9:1) in
                    // Light theme. `shelfAccentText` is the text-safe variant of the
                    // same accent used elsewhere for this state.
                    .foregroundStyle(Color.shelfAccentText)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Action Buttons

    // MARK: - Pinned Play Bar (design review, 14 Aug 2026, item 4)

    /// Play/Resume + a compact progress readout, pinned to the bottom of the screen via
    /// `.safeAreaInset(edge: .bottom)` in `body` instead of living inline in the scroll
    /// content (where it used to be `actionButtons`, competing with the description's
    /// "Show more" and the genre chip row for attention purely by scroll position).
    ///
    /// Bug fix (17 Aug 2026): this previously had a hardcoded `.padding(.bottom, 90)`
    /// meant to "clear the mini player," but `.safeAreaInset(edge: .bottom)` (see
    /// `body`) already reserves exactly this view's own height above whatever's
    /// really at the bottom — tab bar, home indicator, or an actual floating
    /// mini-player, which is a separate overlay this view was never actually
    /// coordinating with anyway. The 90pt was pure dead space: a large empty gray
    /// bar rendered between the Play button and the tab bar on every book detail
    /// screen. Reduced to a small fixed inset just past the button's tap target.
    private var pinnedPlayBar: some View {
        // Critique 2026-10-05 (Book Detail): the bar has four modes (see `PinnedBarMode`).
        // Reading `isPlaying` here re-renders only on play/pause; the per-tick chapter and
        // time-left readout lives in `NowPlayingReadout`, which reads the player itself.
        let loadedId = playerViewModel.currentBook?.id
        let mode = Self.pinnedBarMode(
            isThisBookLoaded: loadedId == displayItem.id,
            isPlaying: playerViewModel.isPlaying,
            anotherBookLoaded: loadedId != nil && loadedId != displayItem.id)
        return pinnedBarChrome {
            pinnedBarRow {
                pinnedStatusLine(mode)
            } action: {
                pinnedPrimaryRow(mode)
            }
        }
    }

    /// Batch 434 (user: the full-width button was "ugly and obnoxious"): one row, status on the
    /// left and a compact capsule on the right (`shelfCompactButtonStyle`). At accessibility
    /// text sizes the two stack, so neither the status nor the label is squeezed.
    private func pinnedBarRow<Status: View, Action: View>(
        @ViewBuilder status: () -> Status, @ViewBuilder action: () -> Action
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            status()
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
                .layoutPriority(1)
        }
    }

    /// Critique 2026-10-05 (Book Detail): what the pinned bar is for, given what the player
    /// holds. Pure and `static` so it can be pinned by `BookDetailStateTests`.
    enum PinnedBarMode: Equatable {
        /// This book is loaded and playing: the amber button pauses ("Pause · Chapter 9");
        /// a quieter neutral control opens the player.
        case nowPlaying
        /// This book is loaded but paused: the amber button resumes ("Resume · Chapter 9").
        case pausedHere
        /// A different book is loaded: starting this one replaces it ("Play This Book Instead").
        case playInstead
        /// Nothing (or only this book's saved progress) is loaded: Start / Continue / Listen Again.
        case startOrContinue
    }

    static func pinnedBarMode(isThisBookLoaded: Bool, isPlaying: Bool, anotherBookLoaded: Bool) -> PinnedBarMode {
        if isThisBookLoaded { return isPlaying ? .nowPlaying : .pausedHere }
        return anotherBookLoaded ? .playInstead : .startOrContinue
    }

    /// The pinned primary button's label for a mode. `progress`/`isFinished` only matter
    /// for `.startOrContinue`.
    /// `detail` is the loaded-state suffix (chapter, else time left; see `pinnedLoadedDetail`).
    static func pinnedPrimaryLabel(mode: PinnedBarMode, progress: Double, isFinished: Bool,
                                   detail: String? = nil) -> String {
        switch mode {
        case .nowPlaying: return joinedLabel(String(localized: "Pause", comment: "Verb: button that pauses playback"), detail)
        case .pausedHere: return joinedLabel(String(localized: "Resume", comment: "Verb: button that resumes playback"), detail)
        case .playInstead: return String(localized: "Play This Book Instead")
        case .startOrContinue:
            if isFinished { return String(localized: "Listen Again") }
            return progress > 0 ? String(localized: "Continue Listening") : String(localized: "Start Listening")
        }
    }

    private static func joinedLabel(_ verb: String, _ detail: String?) -> String {
        guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return verb }
        return String(localized: "\(verb) · \(d)", comment: "Primary button label: %1$@ is a verb (Pause or Resume), %2$@ is a chapter title or time-left text")
    }

    /// What follows "Resume"/"Pause" on the loaded-state button: the current chapter (already
    /// display-formatted) when the book has one, else the time left, else nothing.
    static func pinnedLoadedDetail(chapterTitle: String?, remaining: Double, speed: Double) -> String? {
        if let t = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let text = nowPlayingReadoutText(remaining: remaining, speed: speed, hasChapter: true)
        return text.isEmpty ? nil : text
    }

    /// Live line beside the equalizer for the loaded book: "≈3h 20m left in book" (speed-adjusted,
    /// the same figure as the unloaded state's summary). Empty when under a minute remains, or
    /// when the book has no chapter so the button already carries the time (`hasChapter` false).
    static func nowPlayingReadoutText(remaining: Double, speed: Double, hasChapter: Bool) -> String {
        guard hasChapter, remaining > 60 else { return "" }
        return String(localized: "≈\((remaining / max(speed, 0.1)).formattedDuration) left in book", comment: "Time left in a book; %@ is a duration like 3h 20m")
    }

    // MARK: Chapter / bookmark taps (Critique 2026-10-05, Book Detail, 2nd, P1)

    enum ChapterTapAction: Equatable {
        /// This book is already live: just move within it (through the undo-offering seek path)
        /// and show the player. No new session.
        case seekThenOpenPlayer
        /// Another book (or nothing, or a restored-but-not-yet-resumed session) is loaded: start
        /// this book, then seek only if that start really made it the loaded book.
        case startThenSeek
    }

    static func chapterTapAction(isThisBookLoaded: Bool, isAwaitingResume: Bool) -> ChapterTapAction {
        (isThisBookLoaded && !isAwaitingResume) ? .seekThenOpenPlayer : .startThenSeek
    }

    /// After `startPlayback` returns: it can return early (cellular off, offline and not
    /// downloaded, single-flight guard) or fail, leaving the OTHER book loaded. Seeking then
    /// would move that book, so only seek when this one is now the live one.
    static func shouldSeekAfterStart(loadedBookId: String?, itemId: String, isAwaitingResume: Bool) -> Bool {
        loadedBookId == itemId && !isAwaitingResume
    }

    /// Sheet footer shown when tapping a row would replace the book that's playing.
    /// `noun` is "episode" on a podcast's pinned bar (Critique 2026-10-06, distill).
    static func playsInsteadNote(otherTitle: String?, noun: String = "book") -> String? {
        guard let t = otherTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return noun == "episode"
            ? String(localized: "Plays this episode instead of \(t).", comment: "Footer note; %@ is the title of the item that is currently playing")
            : String(localized: "Plays this book instead of \(t).", comment: "Footer note; %@ is the title of the book that is currently playing")
    }

    // MARK: Podcast bar labels

    /// The podcast bar's label. `partlyPlayed`: the target episode has progress, so it resumes.
    static func podcastPrimaryLabel(targetIndex: Int?, partlyPlayed: Bool, anotherItemLoaded: Bool) -> String {
        if partlyPlayed {
            return anotherItemLoaded ? String(localized: "Resume Episode Instead") : String(localized: "Resume Episode")
        }
        if targetIndex == nil || targetIndex == 0 {
            return anotherItemLoaded ? String(localized: "Play Latest Episode Instead") : String(localized: "Play Latest Episode")
        }
        return anotherItemLoaded ? String(localized: "Play Next Unheard Episode Instead") : String(localized: "Play Next Unheard Episode")
    }

    /// "42% · ≈3h 20m left at 1.5×" for an in-progress book; nil when unstarted or finished.
    static func progressSummary(progress: Double, timeLeft: String?) -> String? {
        guard progress > 0 else { return nil }
        let pct = "\(Int(min(progress, 1) * 100))%"
        guard let timeLeft else { return pct }
        return String(localized: "\(pct) · \(timeLeft)", comment: "Progress summary: %1$@ is a percentage like 42%, %2$@ is time left text")
    }

    /// Index of the episode the podcast bar plays: the newest one not yet finished, else the
    /// newest. `finished` is in the same newest-first order as the episode list.
    static func podcastTargetIndex(finished: [Bool]) -> Int? {
        guard !finished.isEmpty else { return nil }
        return finished.firstIndex(of: false) ?? 0
    }

    /// Drops a trailing series marker from a title when the series capsule already states it:
    /// "Title (Series #3)", "Title - Series, Book 3", "Title: Series". Returns the title
    /// unchanged if nothing matches or stripping would leave it empty.
    static func titleRemovingSeriesSuffix(_ title: String, series: String?) -> String {
        guard let series else { return title }
        var base = series.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = #"(?:#\s*\d+(?:\.\d+)?|book\s+\d+(?:\.\d+)?)"#
        if let r = base.range(of: #"\s*[,:\-–—]?\s*"# + marker + #"\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            base.removeSubrange(r)
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.count >= 3 else { return title }
        let escaped = NSRegularExpression.escapedPattern(for: base)
        let joiner = #"\s*[,:\-–—]?\s*"#
        // Critique 2026-10-05 (Book Detail, 2nd): a bracketed tail may be the bare series name
        // ("Title (Series)"), but an unbracketed one is also an ordinary subtitle ("Star Wars:
        // Thrawn" in series "Thrawn"), so it must carry a #n / "Book n" marker, and a hyphen
        // must have spaces on both sides (en/em dashes and colons may not).
        let separator = #"(?:\s*:\s*|\s+-\s+|\s*[–—]\s*)"#
        let patterns = [
            #"\s*[\(\[]\s*"# + escaped + "(?:" + joiner + marker + ")?" + #"\s*[\)\]]\s*$"#,
            separator + escaped + joiner + marker + #"\s*$"#,
        ]
        for pattern in patterns {
            if let r = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let stripped = title[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { return stripped }
            }
        }
        return title
    }

    /// Progress and time left, or the live readout, above the pinned button.
    @ViewBuilder
    private func pinnedStatusLine(_ mode: PinnedBarMode) -> some View {
        switch mode {
        case .nowPlaying, .pausedHere:
            NowPlayingReadout()
        case .playInstead, .startOrContinue:
            // Critique 2026-10-06 (distill): with the mini player hidden on this screen, the
            // pinned bar is the one place that says which book is loaded, so Play Instead names it.
            if mode == .playInstead, let note = playsInsteadNote {
                VStack(alignment: .leading, spacing: 4) {
                    pinnedPlaysInsteadLine(note)
                    pinnedProgressStatus
                }
            } else {
                pinnedProgressStatus
            }
        }
    }

    /// "Plays this book instead of X." in the pinned bar (Play Instead and the podcast bar).
    private func pinnedPlaysInsteadLine(_ note: String) -> some View {
        Typo.fine(Text(note))
            .foregroundStyle(Color.shelfMuted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Percent and time left, or Finished, for a book that isn't the loaded one.
    @ViewBuilder
    private var pinnedProgressStatus: some View {
        // Critique 2026-10-05 (Book Detail): percent and time left stay visible at every
        // Dynamic Type size (they wrap instead of being dropped at accessibility sizes).
        if let summary = Self.progressSummary(progress: resolvedFinished ? 0 : resolvedProgress,
                                              timeLeft: listeningTimeLeftText) {
            // Listening time left at this book's resolved speed (no finish clock
            // here — it isn't actively playing, so a projected time would mislead).
            Typo.fine(Text(summary))
                .foregroundStyle(Color.shelfMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if resolvedFinished {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.shelfAccentText)
                Typo.supporting(Text("Finished"), weight: .medium)
                    .foregroundStyle(Color.shelfAccentText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func pinnedPrimaryRow(_ mode: PinnedBarMode) -> some View {
        switch mode {
        case .nowPlaying, .pausedHere:
            // Critique 2026-10-05 (Book Detail, 2nd, user decision): one row. The amber button is
            // the action ("Resume · Chapter 9" / "Pause · Chapter 9"); opening the player is the
            // quieter neutral control beside it. Its own view so the per-tick chapter read
            // doesn't re-render this whole screen.
            PinnedLoadedRow(mode: mode) {
                Haptics.impact(.medium)
                closeSheetIfModal()
                playerViewModel.showFullPlayer = true
            }
        case .playInstead, .startOrContinue:
            Button {
                Haptics.impact(.medium)
                // UI-10: `startPlayback(for:)` defaults to `openPlayer: true`, which
                // sets `showFullPlayer = true` internally — the exact same
                // sheet-vs-overlay hazard as the bookmarks section above.
                closeSheetIfModal()
                Task {
                    // Critique 2026-10-06 (harden): Play This Book Instead offers
                    // "Playing instead of … Undo", like B-side.
                    await playerViewModel.startPlaybackOfferingUndo(for: displayItem)
                }
            } label: {
                // LS-12 (docs/design-review.md, Round 2): `startPlayback` can resolve
                // in well under 250 ms against a fast server, so swapping straight to
                // a bare spinner the instant `isLoadingSession` flips true read as a
                // flash rather than useful feedback. `DelayedProgressView` keeps the
                // normal Play label on screen for the first 250 ms of a continuous
                // load and only then reveals the tinted spinner.
                Group {
                    if playerViewModel.isLoadingSession {
                        DelayedProgressView(delay: .milliseconds(250)) {
                            ProgressView()
                                .tint(Color.onAccent)
                                .accessibilityLabel("Loading")
                        } placeholder: {
                            playLabel(mode)
                        }
                    } else {
                        playLabel(mode)
                    }
                }
                .shelfCompactButtonStyle()
            }
            .disabled(playerViewModel.isLoadingSession)
            // Batch 490 (REVIEW 2026-11-11 A1): this button always starts audio, so VoiceOver
            // stays quiet after activating it instead of talking over the book.
            .accessibilityAddTraits(.startsMediaSession)
        }
    }

    /// Critique 2026-10-05 (Book Detail): podcasts get a pinned primary action too, consistent
    /// with the audiobook layout. Plays the newest unfinished episode (see `podcastTargetIndex`).
    private var pinnedPodcastBar: some View {
        let episodes = (displayItem.media?.episodes ?? []).sorted {
            ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0)
        }
        let finished = episodes.map { libraryViewModel.progressFor(episodeId: $0.id)?.isFinished ?? false }
        let target = Self.podcastTargetIndex(finished: finished)
        let targetProgress = target.flatMap { libraryViewModel.progressFor(episodeId: episodes[$0].id)?.progress } ?? 0
        let partlyPlayed = targetProgress > 0 && targetProgress < 0.99
        let loadedId = playerViewModel.currentBook?.id
        // Critique 2026-10-05 (Book Detail, 2nd): `PlaybackSession` carries no episode id, so the
        // player can't say WHICH episode of a show is loaded (see `reopenPlaybackSession`'s note).
        // When this show is the loaded item the bar therefore stays out of the way: it
        // resumes/pauses what is playing and opens the player (the same loaded row as books)
        // rather than restarting a session; the episode rows below still start a specific one.
        let showLoaded = loadedId == displayItem.id && !playerViewModel.isAwaitingResume
        let anotherLoaded = loadedId != nil && loadedId != displayItem.id
        return pinnedBarChrome {
            if showLoaded {
                pinnedBarRow {
                    NowPlayingReadout()
                } action: {
                    PinnedLoadedRow(mode: playerViewModel.isPlaying ? .nowPlaying : .pausedHere) {
                        Haptics.impact(.medium)
                        closeSheetIfModal()
                        playerViewModel.showFullPlayer = true
                    }
                }
            } else {
                // Critique 2026-10-06 (distill): name the loaded item here too, since the mini
                // player is hidden on this screen. Batch 434: otherwise the left side names the
                // episode the button plays.
                pinnedBarRow {
                    if anotherLoaded, let note = playsInsteadNote {
                        pinnedPlaysInsteadLine(note)
                    } else if let target, let title = episodes[target].title, !title.isEmpty {
                        Typo.fine(Text(verbatim: title))
                            .foregroundStyle(Color.shelfMuted)
                            .lineLimit(2)
                    }
                } action: {
                    Button {
                        guard let target else { return }
                        Haptics.impact(.medium)
                        let episode = episodes[target]
                        // UI-10: the player is an overlay; close a presenting sheet first.
                        closeSheetIfModal()
                        // Critique 2026-10-06 (harden): undoable when it replaced a book.
                        Task { await playerViewModel.startPlaybackOfferingUndo(for: displayItem, episode: episode) }
                    } label: {
                        let label = HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text(Self.podcastPrimaryLabel(targetIndex: target, partlyPlayed: partlyPlayed,
                                                          anotherItemLoaded: anotherLoaded))
                        }
                        // Same delayed spinner as the audiobook bar (LS-12).
                        Group {
                            if playerViewModel.isLoadingSession {
                                DelayedProgressView(delay: .milliseconds(250)) {
                                    ProgressView()
                                        .tint(Color.onAccent)
                                        .accessibilityLabel("Loading")
                                } placeholder: {
                                    label
                                }
                            } else {
                                label
                            }
                        }
                        .shelfCompactButtonStyle()
                    }
                    .disabled(target == nil || playerViewModel.isLoadingSession)
                    .accessibilityAddTraits(.startsMediaSession)   // Batch 490 (REVIEW 2026-11-11 A1)
                }
            }
        }
    }

    /// Critique 2026-10-05 (Book Detail): "Read" pinned like Play (was an inline button).
    private var pinnedEbookBar: some View {
        pinnedBarChrome {
            Button {
                Haptics.impact(.medium)
                showEbookReader = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                    Text("Read")
                }
                .shelfCompactButtonStyle()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var pinnedBar: some View {
        if displayItem.isPodcast {
            pinnedPodcastBar
        } else if displayItem.isEbookOnly {
            pinnedEbookBar
        } else {
            pinnedPlayBar
        }
    }

    /// Shared padding and (iOS 17–25) material for every pinned bar variant.
    private func pinnedBarChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
        .padding(.horizontal, Space.pageH)
        .padding(.top, 10)
        .padding(.bottom, 10)   // see doc comment above — was a hardcoded 90 causing dead space
        // Batch 218 (R10.3): `.background(.bar)` is a system-grey material — the one
        // surface on this screen not following the app's own espresso/paper palette
        // (every other card here uses `Color.shelfCard`/`shelfCardStyle()`). Swapped
        // for the app's own card color plus `shelfElevation`, the same theme-aware
        // "soft shadow in Dark, hairline border in Light" treatment every other
        // raised surface in the app uses — replacing both the fill AND the plain
        // `Divider()` this bar used to draw for itself.
        //
        // F9 (REVIEW_2026-09-04_UI.md) keeps that decision and fixes its finish. Fully
        // opaque, `Color.shelfCard` is `#FFFFFF` in Light: a hard-edged white slab across
        // the screen that guillotined whatever scrolled under it mid-word (the "GENRES"
        // header was sliced in half on the running app). The bottom *inset* was never the
        // problem — `safeAreaInset(edge: .bottom)` reserves real space, verified before
        // changing anything here. Tinting the app's own card colour over a blur keeps the
        // palette Batch 218 asked for while letting content dissolve under the bar the way
        // an iOS 26 bottom surface should, and the rounded top edge stops it reading as a
        // slab. Bottom corners stay square — this runs to the screen edge.
        //
        // LG-1 (Round V2): that slab is now the iOS 17–25 path only. On iOS 26+ the bar
        // is a `safeAreaBar` with no background of its own (HIG Materials: reduce custom
        // backgrounds on Liquid Glass), so the system scroll-edge effect sits behind the
        // caption and button. See `LegacyPinnedBarChrome`.
        .modifier(LegacyPinnedBarChrome(shape: Self.pinnedBarShape))
    }

    private static let pinnedBarShape = UnevenRoundedRectangle(
        topLeadingRadius: Radius.hero, bottomLeadingRadius: 0,
        bottomTrailingRadius: 0, topTrailingRadius: Radius.hero)

    /// The Play button's normal (not-loading) label — icon plus the mode's label. Pulled
    /// out so it can double as the `placeholder` for the LS-12 `DelayedProgressView` swap
    /// above without duplicating the markup.
    private func playLabel(_ mode: PinnedBarMode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
            Text(Self.pinnedPrimaryLabel(mode: mode, progress: resolvedProgress, isFinished: resolvedFinished))
        }
    }

    // MARK: - Ebook Reading

    /// Critique 2026-10-05 (Book Detail): the Read button moved to `pinnedEbookBar`; what is
    /// left inline is the note for formats the in-app reader can't render.
    /// Other formats show a clear in-reader message rather than pretending to support them.
    private var ebookFormatNote: String? {
        Self.ebookFormatNote(ext: displayItem.media?.ebookFile?.metadata?.ext)
    }

    /// Critique 2026-10-05 (Book Detail, 2nd): `EbookReaderView` renders PDF (PDFKit) and
    /// EPUB/CBZ (Quick Look); the old note claimed everything but PDF was unsupported, which
    /// was false for the other two. Only formats it truly can't show (MOBI, AZW3, ...) get it.
    static func ebookFormatNote(ext: String?) -> String? {
        // ABS reports the extension with a leading dot (".epub").
        guard let ext = ext?.lowercased().drop(while: { $0 == "." }).description, !ext.isEmpty else { return nil }
        guard !["pdf", "epub", "cbz"].contains(ext) else { return nil }
        return String(localized: "\(ext.uppercased()) files aren't rendered in-app yet — you'll see a message when you tap Read.", comment: "%@ is a file extension such as MOBI")
    }

    // MARK: - Details Section

    // Stage 5 (REDESIGN_PROPOSAL_2026-08-26.md §6.2): About/Details/Genres used to
    // each be their own `.shelfCardStyle()` box — a card fill for what's really just
    // prose and a short metadata list, the exact "card inside a surface" pattern
    // point 2 (`DESIGN_DIRECTION.md`) already named and fixed elsewhere (Home,
    // Settings). Un-carded here too: content now sits directly on the background,
    // grouped by `RetroSectionHeader` instead of a fill, matching every other
    // migrated section's header language on this screen at once (About/Details/
    // Genres previously used a fourth, bare `.headline` spelling nowhere else in the
    // app used for a section header). This also makes the jacket header the only
    // elevated/carded thing above the pinned play bar, which is the right hierarchy
    // for a screen whose job is "decide, then play" — the cover is the one object,
    // everything beneath it is reference material.
    /// Batch 428: whether to offer the on-device "Previously On…" (iOS 26+, a book with transcript
    /// text, away ≥ 3 days, not already offered since that last listen).
    private func updateRecapOffer(for detailed: LibraryItem) {
        guard #available(iOS 26.0, *), !detailed.isPodcast,
              PlayerView.hasSearchableTranscript(TranscriptionCenter.shared.state(for: detailed.id)),
              let record = detailed.mediaProgress, let ms = record.lastUpdate else { return }
        let lastListened = Date(timeIntervalSince1970: Double(ms) / 1000)
        recapOfferShown = RecapPlanner.shouldOffer(
            lastListened: lastListened, now: Date(),
            frontier: TranscriptionCenter.shared.frontier(for: detailed.id),
            lastOfferedAt: BookIntelligence.lastOfferedAt(itemId: detailed.id))
    }

    /// "Where you left off" recap — a template sentence shown instantly, upgraded
    /// in place to an on-device FoundationModels rewrite if/when one lands (see
    /// `RecapGenerator`). Hidden entirely for podcasts and books with no progress.
    private var recapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // TY-2 (V4): a panel title inside a card, so `cardTitle` with no glyph.
            Typo.cardTitle(Text("Where you left off"))
                .foregroundStyle(Color.shelfCream)

            if let recapText {
                Text(recapText)
                    .font(.body)
                    .foregroundStyle(Color.shelfCream)
                    .contentTransition(.opacity)
            }

            if recapIsGenerated {
                Typo.fine(Text("Written on device"))
                    .foregroundStyle(Color.shelfMuted)
                    .transition(.opacity)
            }

            // Batch 428: back after a few days, with a transcript: offer the on-device recap.
            if recapOfferShown {
                Button {
                    Haptics.selection()
                    showIntelligenceRecap = true
                } label: {
                    Label("Previously On\u{2026}", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.shelfAmberTextOnSurface)
                .onAppear { BookIntelligence.markOffered(itemId: displayItem.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .shelfCardStyle()
        // AN-7 (docs/design-review.md, Round 6): the template sentence is upgraded
        // to an on-device model rewrite up to ~10s after this card first appears
        // (see the `.task` above). Without this, the swap is a hard cut and the
        // card's height jump reads as a glitch. Scoped to `recapText` alone so the
        // first template assignment — which only *inserts* this card, it doesn't
        // change `recapText` on an already-mounted card — isn't animated; only the
        // later upgrade is. `.shelfAnimation` already folds in the Reduce Motion
        // check, so no local `@Environment(\.accessibilityReduceMotion)` is needed.
        .shelfAnimation(.easeInOut(duration: 0.3), value: recapText)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if recapText != nil {
                recapCard
            }

            // Pass 3 item 5 (REVIEW_2026-09-04_UI.md): `!isEmpty` was enough to let a
            // scrap of server metadata become a whole About section — one real library
            // rendered the heading with the words "Chapter 84" under it and nothing
            // else. `MediaMetadata.isMeaningfulDescription` (a plain 20-character floor)
            // fixed the general case; P-4 (REVIEW_2026-09-14_DESIGN.md) tightens this
            // screen's own gate further — see `shouldShowDescription` below — applied to
            // the HTML-stripped text so markup can't pad a short description over the
            // line.
            if Self.shouldShowDescription(strippedDescription) {
                VStack(alignment: .leading, spacing: 8) {
                    RetroSectionHeader(title: LocalizedStringResource("bookDetail.about", defaultValue: "About", comment: "Book detail section header above the book\u{2019}s description (not the app\u{2019}s About page)"))

                    Text(strippedDescription)
                        .font(.body)
                        .foregroundStyle(Color.shelfMuted)
                        .lineLimit(descriptionExpanded ? nil : 6)
                        .shelfAnimation(.easeInOut(duration: 0.2), value: descriptionExpanded)

                    // Offer expand/collapse only for long synopses (avoids a pointless
                    // toggle on a one-line description).
                    if strippedDescription.count > 280 {
                        Button {
                            descriptionExpanded.toggle()
                        } label: {
                            // Critique 2026-10-05 (Book Detail, 2nd): the `Typo.rowTitle` role itself
                            // (the comment here claimed it, the code spelled the numbers out).
                            // Amber stays because this is an action; 44pt target.
                            Typo.rowTitle(descriptionExpanded ? Text("Show less") : Text("Show more"))
                                .foregroundStyle(Color.shelfAmberText)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Genre chips (tap to browse the library by that genre)
            if let genres = displayItem.media?.metadata?.genres, !genres.isEmpty {
                genresSection(genres)
            }

            // Metadata grid
            let metadata = buildMetadata()
            if !metadata.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    RetroSectionHeader(title: LocalizedStringResource("Details", comment: "Book detail section header for metadata"))

                    ForEach(metadata, id: \.0) { label, value in
                        // HIG audit 2026-09-17 M5: the fixed 80pt label column crowded and
                        // truncated at accessibility Dynamic Type sizes. Mirrors the house
                        // pattern for size-conditional layout (`dynamicTypeSize.isAccessibilitySize`,
                        // e.g. `LibraryView.smartFilterChip`) — stack label above value instead
                        // of forcing them into one fixed-width row.
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 2) {
                                Typo.supporting(Text(label))
                                    .foregroundStyle(Color.shelfMuted)
                                Typo.supporting(Text(value))
                                    .foregroundStyle(Color.shelfCream)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack {
                                Typo.supporting(Text(label))
                                    .foregroundStyle(Color.shelfMuted)
                                    .frame(width: 80, alignment: .leading)
                                Typo.supporting(Text(value))
                                    .foregroundStyle(Color.shelfCream)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// P-4 (REVIEW_2026-09-14_DESIGN.md): whether the About section is worth showing.
    /// Stricter than the general-purpose `MediaMetadata.isMeaningfulDescription` (a
    /// flat 20-character floor, still used elsewhere) — real servers were seen putting
    /// a bare chapter heading into the description field (e.g. "Chapter 84"), and this
    /// screen specifically wants that junk gone even when it happens to clear the
    /// lower floor. Pure and `static` (no `self`, no I/O) so it can be unit-tested
    /// directly — this project's established pattern for a fix that needs a
    /// regression test (see `DownloadManager.shouldReclaimOrphanDirectory`); see
    /// `BookDetailDescriptionTests`.
    static func shouldShowDescription(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        if trimmed.range(of: "^chapter\\s+\\d+$", options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        // The plain "Chapter N" case above only matters once digits/whitespace push
        // the trimmed string to 40+ characters; the far more common short form is
        // already caught by the length floor. Kept as its own explicit check (rather
        // than folded away as "redundant") because it's exactly what the review named.
        return true
    }

    private func buildMetadata() -> [(String, String)] {
        var metadata: [(String, String)] = []
        if let year = displayItem.media?.metadata?.publishedYear, !year.isEmpty {
            metadata.append((String(localized: "Year", comment: "Book detail metadata label: year published"), year))
        }
        if let publisher = displayItem.media?.metadata?.publisher, !publisher.isEmpty {
            metadata.append((String(localized: "Publisher", comment: "Book detail metadata label"), publisher))
        }
        // Genres are rendered as tappable chips (genresSection), not a text row.
        if let language = displayItem.media?.metadata?.language, !language.isEmpty {
            metadata.append((String(localized: "Language", comment: "Book detail metadata label"), language.capitalized))
        }
        // Batch 490 (REVIEW 2026-11-11 L9): size on the server and the number of audio files.
        if let size = Self.sizeText(bytes: displayItem.size) {
            metadata.append((String(localized: "Size", comment: "Book detail metadata label: size of the book on the server"), size))
        }
        if let files = Self.audioFileCountText(displayItem.media?.numAudioFiles ?? displayItem.media?.audioFiles?.count) {
            metadata.append((String(localized: "Files", comment: "Book detail metadata label: number of audio files"), files))
        }
        return metadata
    }

    /// Batch 490 (REVIEW 2026-11-11 F19): the intent the Siri tip shows, for this book.
    static func playIntent(for item: LibraryItem) -> PlayAudiobookIntent {
        let intent = PlayAudiobookIntent()
        intent.book = AudiobookEntity(from: item)
        return intent
    }

    /// Batch 490 (REVIEW 2026-11-11 L9): pure. A trimmed, non-empty subtitle, or nil.
    static func displaySubtitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Batch 490 (REVIEW 2026-11-11 L9): pure. Whether the book has a real author to link to,
    /// judged on the metadata rather than on the (localised) "Unknown Author" fallback.
    static func hasAuthor(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Batch 490 (REVIEW 2026-11-11 L9): pure. "1.2 GB", or nil for a missing or zero size.
    static func sizeText(bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Batch 490 (REVIEW 2026-11-11 L9): pure. A formatted count ("12", "1,024"), or nil for
    /// none. Formatted here so no raw Int goes into a localised string.
    static func audioFileCountText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count.formatted()
    }

    // MARK: - Genre chips

    private func genresSection(_ genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RetroSectionHeader(title: LocalizedStringResource("Genres"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        NavigationLink(destination: GenreBooksView(genre: genre)) {
                            Typo.supporting(Text(genre), weight: .medium)
                                // Critique 2026-10-05 (Book Detail): neutral (Deck Well fill, cream
                                // text) — amber is reserved for actions and live state here.
                                .foregroundStyle(Color.shelfCream)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.shelfSurface, in: Capsule())
                                // ~35 pt chip → 44 pt hit area, vertically only so neighbours
                                // in the row don't steal each other's taps.
                                .contentShape(VerticalOutsetRect(amount: 5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse \(genre)")
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chapters Section

    // MARK: - Podcast Episodes Section

    /// A podcast show's episode list, in place of the book Play/download/chapters UI —
    /// each episode is its own independent listen (own audio file, own progress),
    /// started via `PlayerViewModel.startEpisodePlayback`. Streaming-only for now; see
    /// the scope note in `CHANGES_IMPLEMENTED.md`'s podcast-support entry for why
    /// per-episode downloads aren't part of this pass.
    private var episodesSection: some View {
        let episodes = (displayItem.media?.episodes ?? []).sorted {
            ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Typo.cardTitle(Text("Episodes (\(episodes.count))"))
                .foregroundStyle(Color.shelfCream)

            if episodes.isEmpty {
                Typo.metadata(Text("No episodes found for this podcast."))
                    .foregroundStyle(Color.shelfMuted)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        PodcastEpisodeRow(
                            episode: episode,
                            progress: libraryViewModel.progressFor(episodeId: episode.id)
                        ) {
                            Haptics.selection()
                            // Critique 2026-10-06 (harden): an episode tap that replaces the
                            // loaded book (or another episode) offers "Playing instead of …
                            // Undo"; the pinned bar already names what it replaces.
                            Task { await playerViewModel.startPlaybackOfferingUndo(for: displayItem, episode: episode) }
                        }
                        if episode.id != episodes.last?.id {
                            Divider().background(Color.shelfSurface)
                        }
                    }
                }
            }
        }
        .padding(16)
        .shelfCardStyle()
    }

    // MARK: - Chapters (design review, 14 Aug 2026, item 4)

    /// Batch 450: one row of `bookToolsList`. What each row is, in order.
    enum BookToolRow: Hashable {
        case chapters, bookmarks, bookmarksFailed, transcript, xray, ask, ebook, bookClub
    }

    /// Pure: which rows the grouped list shows, in order. Pinned by `BookDetailToolRowsTests`.
    static func bookToolRows(isPodcast: Bool, chapterCount: Int, bookmarkCount: Int,
                             bookmarksLoadFailed: Bool, showsTranscript: Bool,
                             hasSearchableTranscript: Bool, hasCompanionEbook: Bool,
                             inHousehold: Bool = false) -> [BookToolRow] {
        var rows: [BookToolRow] = []
        if chapterCount > 0 { rows.append(.chapters) }
        if bookmarkCount > 0 { rows.append(.bookmarks) } else if bookmarksLoadFailed { rows.append(.bookmarksFailed) }
        if !isPodcast {
            if showsTranscript { rows.append(.transcript) }
            if hasSearchableTranscript { rows += [.xray, .ask] }
            if hasCompanionEbook { rows.append(.ebook) }
            // Batch 455: Book Club, for a household member.
            if inHousehold { rows.append(.bookClub) }
        }
        return rows
    }

    private var bookToolRows: [BookToolRow] {
        let hasSearchable: Bool
        if #available(iOS 26.0, *) {
            hasSearchable = PlayerView.hasSearchableTranscript(TranscriptionCenter.shared.state(for: displayItem.id))
        } else {
            hasSearchable = false
        }
        return Self.bookToolRows(
            isPodcast: displayItem.isPodcast,
            chapterCount: displayChapters.count,
            bookmarkCount: bookmarks.count,
            bookmarksLoadFailed: bookmarksLoadFailed,
            showsTranscript: BookTranscriptRow.isVisible(itemId: displayItem.id, transcriptsEnabled: transcriptsEnabled),
            hasSearchableTranscript: hasSearchable,
            hasCompanionEbook: !displayItem.isEbookOnly && displayItem.media?.ebookFile != nil,
            inHousehold: householdStore.isSocialAvailable)
    }

    /// Chapters, Bookmarks, Transcript, X-Ray, Ask the Book and Read the Book as one card of
    /// rows with hairlines between them. Each row opens what its old card or row opened.
    @ViewBuilder private var bookToolsList: some View {
        let rows = bookToolRows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    if index > 0 {
                        Divider()
                            .background(Color.shelfSurface)
                            .padding(.leading, 52)
                    }
                    bookToolRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shelfCardStyle()
        }
    }

    @ViewBuilder private func bookToolRow(_ row: BookToolRow) -> some View {
        switch row {
        case .chapters:
            navigationRow(title: "Chapters", systemImage: "list.bullet", count: displayChapters.count) {
                showChaptersSheet = true
            }
            .accessibilityHint("Opens the chapter list")
        case .bookmarks:
            navigationRow(title: "Bookmarks", systemImage: "bookmark", count: bookmarks.count) {
                showBookmarksSheet = true
            }
            .accessibilityHint("Opens the bookmark list")
        case .bookmarksFailed:
            bookmarksLoadFailedRow
        case .transcript:
            BookTranscriptRow(itemId: displayItem.id, title: displayItem.title,
                              language: displayItem.media?.metadata?.language,
                              onSearch: { showTranscriptSearch = true })
        case .xray:
            navigationRow(title: "X-Ray", systemImage: "person.2") { showXRay = true }
        case .ask:
            navigationRow(title: "Ask the Book", systemImage: "questionmark.circle") { showAskBook = true }
        case .ebook:
            navigationRow(title: "Read the Book", systemImage: "book") { showEbookReader = true }
        case .bookClub:
            navigationRow(title: "Book Club", systemImage: "person.3") { showBookClub = true }
        }
    }

    /// A tappable row: glyph, title, optional count, chevron. The whole row is the hit target.
    private func navigationRow(title: LocalizedStringResource, systemImage: String, count: Int? = nil,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Typo.rowTitle(Text(title))
                    .foregroundStyle(Color.shelfCream)
                Spacer(minLength: 8)
                if let count {
                    Typo.supporting(Text(count, format: .number))
                        .foregroundStyle(Color.shelfMuted)
                }
                Typo.supporting(Image(systemName: "chevron.right")
                    .foregroundStyle(Color.shelfMuted))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            // Same fix as the old Chapters row: the Spacer draws nothing, so without this only
            // the text and chevron were tappable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Plays this book instead of X." when another book is the loaded one.
    private var playsInsteadNote: String? {
        guard let loaded = playerViewModel.currentBook, loaded.id != displayItem.id else { return nil }
        return Self.playsInsteadNote(otherTitle: loaded.title, noun: displayItem.isPodcast ? "episode" : "book")
    }

    /// Critique 2026-10-05 (Book Detail, 2nd, P1): the shared path for a chapter or bookmark tap.
    /// Used to be `await startPlayback(for:)` then seek, always: that restarted the session of
    /// the already-loaded book, silently replaced another book, and, when `startPlayback`
    /// returned early or failed, moved the OTHER book that was still loaded. Now the mode is
    /// decided first (`chapterTapAction`), and the seek after a start is conditional.
    /// UI-10 still applies: close any presenting sheet before the player is shown.
    private func jumpFromSheet(seek: @escaping () -> Void) {
        let action = Self.chapterTapAction(
            isThisBookLoaded: playerViewModel.currentBook?.id == displayItem.id,
            isAwaitingResume: playerViewModel.isAwaitingResume)
        closeSheetIfModal()
        switch action {
        case .seekThenOpenPlayer:
            seek()
            playerViewModel.showFullPlayer = true
        case .startThenSeek:
            Task {
                await playerViewModel.startPlayback(for: displayItem)
                if Self.shouldSeekAfterStart(loadedBookId: playerViewModel.currentBook?.id,
                                             itemId: displayItem.id,
                                             isAwaitingResume: playerViewModel.isAwaitingResume) {
                    seek()
                }
            }
        }
    }

    /// Batch 431: Listen from Here in the ebook reader. Seeks (starting playback first when
    /// this book isn't loaded) without dismissing the reader.
    private func listenFromReader(at time: Double) {
        if playerViewModel.currentBook?.id == displayItem.id, !playerViewModel.isAwaitingResume {
            playerViewModel.seek(to: time, reason: .readAlong)
            return
        }
        Task {
            await playerViewModel.startPlayback(for: displayItem, openPlayer: false)
            if Self.shouldSeekAfterStart(loadedBookId: playerViewModel.currentBook?.id,
                                         itemId: displayItem.id,
                                         isAwaitingResume: playerViewModel.isAwaitingResume) {
                playerViewModel.seek(to: time, reason: .readAlong)
            }
        }
    }

    /// The chapter list itself, presented as a sheet from `body`.
    private var chaptersSheetContent: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(displayChapters) { chapter in
                        ChapterRow(chapter: chapter, currentPosition: chapterProgressPosition) {
                            showChaptersSheet = false
                            jumpFromSheet { playerViewModel.seekToChapter(chapter) }
                        }
                        .listRowBackground(Color.shelfCard)
                    }
                } footer: {
                    // Critique 2026-10-05 (Book Detail, 2nd): say so when a tap replaces the book
                    // that is playing.
                    if let note = playsInsteadNote {
                        Typo.supporting(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }

                // Item 11: the note about chapters that couldn't be read, as the last
                // row of the list it describes. Plain caption styling, matching the
                // secondary captions elsewhere on this screen (`.caption` +
                // `shelfMuted`); no alert, no toast.
                if let note = Chapter.droppedChapterNote(count: displayDroppedChapterCount) {
                    Typo.supporting(Text(note))
                        .foregroundStyle(Color.shelfMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showChaptersSheet = false }   // LG-3
                        .monochromeToolbarItem()
                }
            }
        }
    }

    // MARK: - Bookmarks (design review, 14 Aug 2026, item 4)

    /// The bookmark list itself, presented as a sheet from `body`.
    private var bookmarksSheetContent: some View {
        NavigationStack {
            List {
                Section {
                ForEach(bookmarks) { bookmark in
                    Button {
                        Haptics.selection()
                        // UI-10: dismiss this sheet, and the presenting one if this
                        // whole screen is itself sheet-presented, *before* the full
                        // player is asked to show itself (see `jumpFromSheet`).
                        showBookmarksSheet = false
                        jumpFromSheet { playerViewModel.seekToBookmark(bookmark) }
                    } label: {
                        HStack(spacing: 12) {
                            Typo.supporting(Image(systemName: "bookmark.fill")
                                .foregroundStyle(Color.shelfAmberText))
                            VStack(alignment: .leading, spacing: 2) {
                                Typo.rowTitle(Text(bookmark.title))
                                    .foregroundStyle(Color.shelfCream)
                                    .lineLimit(1)
                                if let note = notesStore.note(for: bookmark), !note.isEmpty {
                                    Typo.supporting(Text(note))
                                        .foregroundStyle(Color.shelfMuted)
                                        .lineLimit(2)
                                }
                                Typo.figure(Text(bookmark.time.formattedTime))
                                    .foregroundStyle(Color.shelfMuted)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .foregroundStyle(Color.shelfMuted)
                        }
                        .padding(.vertical, 4)
                    }
                    .contextMenu {
                        Button {
                            editingBookmark = bookmark
                            editNoteText = bookmark.title
                            editNoteBody = notesStore.note(for: bookmark) ?? ""
                        } label: { Label(BookDetailView.editBookmarkTitle, systemImage: "pencil") }
                        Button(role: .destructive) {
                            deleteBookmark(bookmark)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    // Critique 2026-10-06 (harden): the same swipe as the player's sheet and
                    // All Bookmarks, with no full swipe.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteBookmark(bookmark)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    .listRowBackground(Color.shelfCard)
                }
                } footer: {
                    if let note = playsInsteadNote {
                        Typo.supporting(Text(note))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // Critique 2026-10-06 (harden): deleting the last bookmark used to leave an empty
            // sheet. The Undo toast below still offers it back.
            .overlay {
                if bookmarks.isEmpty {
                    EmptyStateView(icon: "bookmark",
                                   title: .verbatim(BookDetailView.bookmarksEmptyTitle),
                                   subtitle: .verbatim(BookDetailView.bookmarksEmptyMessage))
                }
            }
            .background(Color.shelfBackground.ignoresSafeArea())
            // Critique 2026-10-06 (harden): Undo for a deleted bookmark, inside the sheet so
            // it shows above it. 6 s, and it persists under VoiceOver (`toast(action:)`).
            .bookmarkUndoToast(bookmarkUndo) { await reloadBookmarks() }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exportBookmarksMarkdown()
                    } label: { Label("Export bookmarks", systemImage: "square.and.arrow.up") }
                        .monochromeToolbarItem()
                        .disabled(bookmarks.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showBookmarksSheet = false }   // LG-3
                        .monochromeToolbarItem()
                }
            }
            .sheet(item: $exportPayload) { payload in ActivityView(items: [payload.url]) }
            // Extended to a two-field sheet: an alert can't comfortably hold both the
            // server title and a longer local note.
            .sheet(item: $editingBookmark) { bookmark in
                NavigationStack {
                    Form {
                        Section("Title") {
                            TextField("Title", text: $editNoteText)
                        }
                        Section("Note") {
                            TextEditor(text: $editNoteBody)
                                .frame(minHeight: 100)
                        }
                        if let editSaveError {
                            Section {
                                Label {
                                    Typo.supporting(Text(editSaveError))
                                        .foregroundStyle(Color.shelfCream)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.shelfOrange)
                                }
                            }
                        }
                    }
                    .navigationTitle("Edit Bookmark")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { editingBookmark = nil }
                                .monochromeToolbarItem()
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            SheetConfirmButton(title: "Save") { saveEdit(bookmark) }
                                .disabled(isSavingEdit)
                        }
                    }
                }
                .onDisappear { editSaveError = nil; isSavingEdit = false }
            }
        }
    }

    /// Critique 2026-10-06 (harden): delete, then offer Undo, through the shared
    /// `BookmarkDeleteUndo`. A delete made offline is queued by `BookmarkSyncService`, and
    /// so is the Undo's re-create, in order.
    private func deleteBookmark(_ bookmark: AudioBookmark) {
        bookmarkUndo.delete(bookmark) { await reloadBookmarks() }
    }

    private func reloadBookmarks() async {
        await reloadBookmarks(itemId: displayItem.id)
    }

    /// Critique 2026-10-06 (harden): a failed fetch keeps whatever list was showing and sets
    /// `bookmarksLoadFailed`, instead of blanking the list as if there were none.
    private func reloadBookmarks(itemId: String) async {
        do {
            bookmarks = try await AudiobookshelfAPI.shared.getBookmarks(itemId: itemId)
            bookmarksLoadFailed = false
        } catch {
            bookmarksLoadFailed = true
        }
    }

    /// "Couldn't load bookmarks · Retry", in place of the Bookmarks row after a failed fetch
    /// (Batch 450: a row of `bookToolsList`).
    private var bookmarksLoadFailedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark")
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 24)
                .accessibilityHidden(true)
            Typo.supporting(Text(BookDetailView.bookmarksLoadFailedText))
                .foregroundStyle(Color.shelfMuted)
            Spacer(minLength: Space.s)
            Button {
                Haptics.selection()
                Task { await reloadBookmarks() }
            } label: {
                Typo.supporting(Text("Retry"), weight: .semibold)
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading bookmarks")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
    }

    static var bookmarksLoadFailedText: String { String(localized: "Couldn\u{2019}t load bookmarks") }
    /// Empty state for the bookmark sheet once the last one is deleted.
    static var bookmarksEmptyTitle: String { String(localized: "No Bookmarks") }
    static var bookmarksEmptyMessage: String { String(localized: "Add a bookmark from the player to save a moment in this book.") }
    /// Critique 2026-10-06 (clarify): one name for editing a bookmark (title and note) on every
    /// entry point; was "Edit Note" in the long-press menu and "Edit" on the swipe.
    static var editBookmarkTitle: String { String(localized: "Edit Bookmark") }

    /// Critique 2026-10-06 (harden): Save used to close the sheet before the edit was sent and
    /// never said if it failed. It now goes through `PlayerViewModel.updateBookmark` (the same
    /// path as the player's sheet) and closes only on a synced or queued save.
    private func saveEdit(_ bookmark: AudioBookmark) {
        let title = editNoteText
        let noteBody = editNoteBody
        isSavingEdit = true
        editSaveError = nil
        Task {
            let result = await playerViewModel.updateBookmark(bookmark, note: title)
            isSavingEdit = false
            if BookmarkEditFeedback.shouldClose(after: result) {
                notesStore.setNote(noteBody, for: bookmark)
                Haptics.success()
                editingBookmark = nil
                await reloadBookmarks()
            } else {
                Haptics.impact(.heavy)
                editSaveError = BookmarkEditFeedback.failureMessage
                // Critique 2026-10-06 (polish): the message appears below the editor, out
                // of VoiceOver focus (the Save button keeps it), so it's announced too.
                AccessibilityNotification.Announcement(BookmarkEditFeedback.failureMessage).post()
            }
        }
    }

    /// Pure copy for the ••• menu's series notes, pinned by `BookDetailHardenTests`.
    /// `nextInSeries` returns nil both for "no next book" and for a lookup that failed, so
    /// the wording covers both.
    static var noNextInSeriesNotice: String { String(localized: "Couldn\u{2019}t find a next book in this series.") }

    /// Kept for `HardenCopyTests`; the copy lives on `BookmarkDeleteUndo`.
    static func bookmarkDeletedMessage(title: String, time: Double) -> String {
        BookmarkDeleteUndo.message(title: title, time: time)
    }

    private func exportBookmarksMarkdown() {
        let notes = notesStore.notes(forItemId: displayItem.id)
        let markdown = BookmarkMarkdownExporter.markdown(
            bookTitle: displayItem.title,
            author: displayItem.authorName,
            chapters: displayChapters,
            bookmarks: bookmarks,
            notes: notes)
        guard let url = BookmarkMarkdownExporter.writeExportFile(
            markdown: markdown, filenameStem: displayItem.title) else { return }
        exportPayload = SharePayload(url: url)
    }
}

// MARK: - Pinned bar placement (LG-1, visual review Round V2)

/// Pins `bar` to the bottom edge: `safeAreaBar` on iOS 26+ (availability iOS 26.0, Apple
/// docs `View/safeAreaBar(edge:alignment:spacing:content:)`), which insets the safe area
/// like `safeAreaInset` and also extends the scroll views' edge effect under the bar; plain
/// `safeAreaInset` on iOS 17–25.
private struct PinnedBottomBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar() }
        } else {
            content.safeAreaInset(edge: .bottom) { bar() }
        }
    }
}

/// The pinned bar's own card-tinted material, rounded top and elevation, for iOS 17–25
/// only. On iOS 26+ the bar has no chrome of its own; `PinnedBottomBar`'s `safeAreaBar`
/// supplies the scroll-edge effect instead.
private struct LegacyPinnedBarChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .background {
                    Color.shelfCard.opacity(0.75).background(.ultraThinMaterial)
                }
                .clipShape(shape)
                .shelfElevation(.card, in: shape)
        }
    }
}

// MARK: - Now Playing readout and link destinations (Critique 2026-10-05, Book Detail)

/// Live time left for the book that is loaded in the player, with an equalizer that moves
/// only while it plays (the one equalizer on this screen). Its own view so the per-tick
/// `currentTime` read invalidates only this line, not the whole detail screen.
private struct NowPlayingReadout: View {
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        // Batch 434: the button now says only Pause/Resume, so the chapter it used to name
        // ("Pause · Chapter 9") sits here, above the time left.
        let chapter = playerViewModel.currentChapter.map { PlayerView.displayChapterTitle($0.title) }
        let text = BookDetailView.nowPlayingReadoutText(
            remaining: max(playerViewModel.duration - playerViewModel.currentTime, 0),
            speed: Double(playerViewModel.playbackRate),
            hasChapter: true)
        HStack(spacing: 8) {
            EqualizerBadge(animating: playerViewModel.isPlaying, color: Color.shelfAmber)
            VStack(alignment: .leading, spacing: 2) {
                if let chapter, !chapter.isEmpty {
                    Typo.fine(Text(verbatim: chapter), weight: .medium)
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(1)
                }
                Typo.fine(text.isEmpty ? (playerViewModel.isPlaying ? Text("Playing") : Text("Paused")) : Text(verbatim: text))
                    .foregroundStyle(Color.shelfMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Critique 2026-10-05 (Book Detail, 2nd): the pinned bar's primary row when this item is the
/// loaded one. Amber button = the action it names ("Resume · Chapter 9" / "Pause · Chapter 9");
/// the quieter neutral control opens the full player. Reads the player itself so the chapter
/// name stays live without re-rendering the detail screen.
private struct PinnedLoadedRow: View {
    let mode: BookDetailView.PinnedBarMode
    let openPlayer: () -> Void
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        // Batch 434: a compact capsule ("Pause"/"Resume" only; the chapter and time left moved
        // into `NowPlayingReadout` beside it) plus a 44 pt round "open player" control.
        let label = BookDetailView.pinnedPrimaryLabel(mode: mode, progress: 0, isFinished: false)
        HStack(spacing: 8) {
            Button {
                Haptics.impact(.light)
                playerViewModel.togglePlayPause()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mode == .nowPlaying ? "pause.fill" : "play.fill")
                    Text(label)
                }
                .shelfCompactButtonStyle()
            }
            .accessibilityLabel(label)
            // Batch 490 (REVIEW 2026-11-11 A1): Resume starts audio (Pause doesn't), as Driving
            // Mode's Play does.
            .accessibilityAddTraits(mode == .nowPlaying ? [] : .startsMediaSession)

            Button(action: openPlayer) {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.shelfCream)
                    .frame(width: 44, height: 44)
                    .background(Color.shelfSurface, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Open player")
        }
    }
}

/// Resolves a series name to its `Series` (the series page needs the book list) and shows
/// `SeriesDetailView`. Uses the cached series list when it already has the series.
private struct SeriesLinkDestination: View {
    let seriesName: String
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var series: Series?
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    /// Critique 2026-10-05 (Book Detail, 2nd): "not found" (the series list was read and the
    /// series isn't in it) is a different message from "couldn't load" (no library, or the
    /// request failed), and only the second is worth a Retry. `try?` used to merge them.
    private enum Phase { case loading, notFound, failed }

    var body: some View {
        Group {
            if let series {
                SeriesDetailView(series: series)
            } else {
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    switch phase {
                    case .loading:
                        ProgressView().shelfSpinner()
                    case .notFound:
                        EmptyStateView(icon: "books.vertical", title: LocalizedStringResource("Series not found"),
                                       subtitle: LocalizedStringResource("This series isn’t in the library’s series list. It may have been renamed or removed."),
                                       actionTitle: LocalizedStringResource("Go Back")) {
                            // Polish pass (J3-5): a dead end gets one way out.
                            dismiss()
                        }
                    case .failed:
                        EmptyStateView(icon: "wifi.exclamationmark", title: LocalizedStringResource("Couldn’t load this series"),
                                       subtitle: LocalizedStringResource("Check your connection and try again."),
                                       actionTitle: LocalizedStringResource("Retry")) {
                            phase = .loading
                            attempt += 1
                        }
                    }
                }
                .navigationTitle(seriesName)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: attempt) { await resolve() }
    }

    private func resolve() async {
        if let cached = libraryViewModel.seriesList.first(where: { $0.name == seriesName || $0.displayName == seriesName }) {
            series = cached
            return
        }
        guard let libraryId = libraryViewModel.selectedLibrary?.id else { phase = .failed; return }
        do {
            // maxPages 10 (1,000 series), not the default 50: this runs on a tap of a tiny
            // capsule, and a missing series would otherwise cost up to 50 sequential requests.
            if let found = try await AudiobookshelfAPI.shared.findSeries(
                libraryId: libraryId, matching: seriesName, maxPages: 10) {
                series = found
            } else {
                phase = .notFound
            }
        } catch {
            if Task.isCancelled { return }
            phase = .failed
        }
    }
}

/// Resolves an author's display name to the `NamedEntity` the author page filters by
/// (library filter data), then shows `AuthorBooksView`. A multi-author string ("A, B")
/// resolves to the first author that matches.
private struct AuthorLinkDestination: View {
    let name: String
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var author: NamedEntity?
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    /// Same split as `SeriesLinkDestination`: `filterData` still nil after a load means the
    /// load failed (retryable); loaded but no match means the author isn't listed.
    private enum Phase { case loading, notFound, failed }

    var body: some View {
        Group {
            if let author {
                AuthorBooksView(author: author)
            } else {
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    switch phase {
                    case .loading:
                        ProgressView().shelfSpinner()
                    case .notFound:
                        EmptyStateView(icon: "person.slash", title: LocalizedStringResource("Author not found"),
                                       subtitle: LocalizedStringResource("This author isn’t in the library’s author list. It may have been renamed or removed."),
                                       actionTitle: LocalizedStringResource("Go Back")) {
                            // Polish pass (J3-5): a dead end gets one way out.
                            dismiss()
                        }
                    case .failed:
                        EmptyStateView(icon: "wifi.exclamationmark", title: LocalizedStringResource("Couldn’t load this author"),
                                       subtitle: LocalizedStringResource("Check your connection and try again."),
                                       actionTitle: LocalizedStringResource("Retry")) {
                            phase = .loading
                            attempt += 1
                        }
                    }
                }
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: attempt) { await resolve() }
    }

    private func resolve() async {
        if libraryViewModel.filterData == nil { await libraryViewModel.loadFilterData() }
        if Task.isCancelled { return }
        guard let authors = libraryViewModel.filterData?.authors else { phase = .failed; return }
        let candidates = [name] + name.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for candidate in candidates {
            if let hit = authors.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                author = hit
                return
            }
        }
        phase = .notFound
    }
}

// MARK: - Book Detail download section

/// The download control on Book Detail — now a single compact icon button living in
/// `headerSection`'s metadata row (duration/chapter-count line), not a full-width block
/// of its own beneath the jacket.
///
/// P-4 (REVIEW_2026-09-14_DESIGN.md): the old full-width "Download for Offline" button
/// (and its downloaded/downloading full-width cards) were the first thing under the
/// cover, ahead of About/Genres — outranking the actual primary action
/// ("Continue Listening"/"Start Listening" in `pinnedPlayBar`) just by being first in
/// the scroll. Collapsed to one 44×44 icon control here; every prior state is kept,
/// plus a fourth (failed, previously not represented on this screen at all — only
/// `DownloadsView`'s `FailedDownloadRow` showed it): not downloaded, downloading
/// (paused or not, with a thin progress ring instead of a full-width bar), downloaded,
/// and failed-with-retry. Downloading/failed use a `Menu` so pause/resume/cancel or
/// retry/remove stay reachable without a second control each.
///
/// Item 10 (REVIEW-2026-09-09.md): stays its own view, not a computed property of
/// `BookDetailView`, so the only reads of `DownloadManager.activeDownloads` /
/// `failedDownloads` on this screen happen inside the one control that displays them —
/// both are rewritten on every progress callback, and this scopes that invalidation to
/// this small view instead of re-running the whole detail screen's body.
///
/// `onRemoveTapped` raises the caller's own remove-download confirmation dialog for the
/// *already-downloaded* case, which stays on `BookDetailView` (presented from the
/// screen, not from this control) — matches the confirmation the old full-width trash
/// button used. Cancelling an in-flight download and discarding a failed record are not
/// confirmed, matching `DownloadsView`'s `ActiveDownloadRow`/`FailedDownloadRow`.
private struct BookDetailDownloadSection: View {
    let item: LibraryItem
    let onRemoveTapped: () -> Void

    @State private var downloadManager = DownloadManager.shared
    // Critique 2026-10-05 (Book Detail, 2nd): the glyphs are text-style fonts (.title3 /
    // .callout) with Dynamic Type capped at accessibility1, so they scale but still sit inside
    // the 44pt tap frame. No bare `.font(.system(size:))` (DESIGN.md Token-Only Rule).
    // The ring's centre glyph is the one exception, see `ringSize`.
    // Ring diameter: scales with Dynamic Type, capped at 30pt so it fits the 44pt frame.
    @ScaledMetric(relativeTo: .body) private var ringBase: CGFloat = 20
    private var ringSize: CGFloat { min(ringBase, 30) }

    /// AN-5 (docs/design-review.md, Round 3): a small, Equatable key for *which* of the
    /// four button states is showing. Driving `.shelfAnimation` off this instead of the
    /// raw progress fraction means the ring's per-tick progress updates (already animated
    /// on their own, see `downloadingButton`) don't retrigger the state-swap transition.
    private enum ButtonState: Equatable {
        case notDownloaded
        case downloading
        case downloaded
        case failed
    }

    private var buttonState: ButtonState {
        if downloadManager.isDownloaded(itemId: item.id) {
            return .downloaded
        } else if downloadManager.isDownloading(itemId: item.id) {
            return .downloading
        } else if downloadManager.failedDownloads[item.id] != nil {
            return .failed
        } else {
            return .notDownloaded
        }
    }

    var body: some View {
        // AN-5: the four branches below are different view types (Button<Image> vs.
        // Menu<ZStack>/Menu<Image>), so a plain `.contentTransition` can't cover the
        // swap between them — cross-fade with `.transition(.opacity)` per branch instead,
        // gated by `buttonState` so a progress tick alone never animates the swap. Each
        // branch already fixes its own 44x44 frame, so nothing around the button shifts.
        Group {
            if downloadManager.isDownloaded(itemId: item.id) {
                downloadedButton
                    .transition(.opacity)
            } else if downloadManager.isDownloading(itemId: item.id) {
                downloadingButton
                    .transition(.opacity)
            } else if let failure = downloadManager.failedDownloads[item.id] {
                failedButton(failure)
                    .transition(.opacity)
            } else {
                notDownloadedButton
                    .transition(.opacity)
            }
        }
        .shelfAnimation(.easeInOut(duration: 0.2), value: buttonState)
    }

    private var notDownloadedButton: some View {
        Button {
            Haptics.impact(.light)
            downloadManager.downloadBook(item)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Color.shelfAmberText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Download for offline")
        .accessibilityHint("Downloads this book so it can play without a connection")
    }

    // Critique 2026-10-06 (harden): was the same teal checkmark as the header's "Finished",
    // so "downloaded" and "finished" looked identical. Teal means finished only (DESIGN.md);
    // a download is the muted `arrow.down.circle.fill` Library's rows already use.
    private var downloadedButton: some View {
        Button(action: onRemoveTapped) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Color.shelfMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Downloaded, available offline")
        .accessibilityHint("Double tap to remove the download")
    }

    private var downloadingButton: some View {
        let task = downloadManager.activeDownloads[item.id]
        let progress = task?.progress ?? 0
        let paused = task?.isPaused ?? false
        return Menu {
            Button {
                if paused {
                    downloadManager.resumeDownload(itemId: item.id)
                } else {
                    downloadManager.pauseDownload(itemId: item.id)
                }
            } label: {
                Label {
                    paused ? Text("Resume Download") : Text("Pause Download")
                } icon: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
            }
            Button(role: .destructive) {
                downloadManager.cancelDownload(itemId: item.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark")
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.shelfMuted.opacity(0.3), lineWidth: 2.5)
                // A sliver always shows (the `max`) so a just-started 0%-progress
                // download still reads as "a ring", not an empty circle.
                Circle()
                    .trim(from: 0, to: max(progress, 0.03))
                    .stroke(Color.shelfAmber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shelfAnimation(.linear(duration: 0.3), value: progress)
                // AN-5: pause/play is a same-`Image` symbol swap, so `.contentTransition`
                // (not `.transition`) is the right tool — morphs the glyph instead of
                // a hard cut on tap.
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    // Hardware-glyph exception (DESIGN.md Token-Only Rule): it has to sit inside
                    // the ring, so it is a fixed fraction of the (scaled, capped) ring size.
                    .font(.system(size: ringSize * 0.45, weight: .bold))
                    .foregroundStyle(Color.shelfAmberText)
                    .contentTransition(.symbolEffect(.replace))
                    .shelfAnimation(.easeInOut(duration: 0.2), value: paused)
            }
            .frame(width: ringSize, height: ringSize)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(paused ? Text("Download paused") : Text("Downloading"))
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityHint("Opens pause, resume, and cancel options")
    }

    private func failedButton(_ failure: DownloadManager.DownloadFailure) -> some View {
        Menu {
            Button {
                Task { await downloadManager.retryFailedDownload(itemId: item.id) }
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                downloadManager.removeFailedDownload(itemId: item.id)
            } label: {
                Label("Remove Failed Download", systemImage: "trash")
            }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Color.shelfOrange)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Download failed")
        .accessibilityValue(failure.message)
        .accessibilityHint("Opens retry and remove options")
    }
}

// MARK: - Chapter Row

struct ChapterRow: View {
    let chapter: Chapter
    /// P-5 (REVIEW_2026-09-14_DESIGN.md): the book's current position, in seconds —
    /// live playback position when this chapter's book is the one actually playing,
    /// otherwise the book's last-saved progress translated into seconds (see
    /// `BookDetailView.chapterProgressPosition`). Used only to shade this row as
    /// finished / in-progress; it drives no playback decision here.
    let currentPosition: Double
    let onTap: () -> Void

    private var chapterDuration: Double { max(chapter.end - chapter.start, 0) }

    /// Fraction of *this chapter* already heard, 0...1.
    private var chapterProgress: Double {
        guard chapterDuration > 0 else { return 0 }
        return min(max((currentPosition - chapter.start) / chapterDuration, 0), 1)
    }

    private var isFinished: Bool { currentPosition >= chapter.end }
    private var isInProgress: Bool { currentPosition > chapter.start && currentPosition < chapter.end }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // P-5: a finished tick / thin in-progress bar so this list answers
                // "where am I" per chapter without opening one to find out.
                chapterStatusIndicator
                    .frame(width: 16)

                Typo.rowTitle(Text(chapter.title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)

                Spacer()

                // P-5: duration ("15m") is the trailing column now — the useful figure
                // at a glance. The absolute book-clock timestamp that used to sit here
                // (e.g. "15:51:32" on a long book) added nothing actionable visually;
                // it's kept in the accessibility value below instead.
                Typo.figure(Text(chapterDuration.formattedDuration))
                    .foregroundStyle(Color.shelfMuted)
            }
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapter.title)
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("Plays from this chapter")
    }

    @ViewBuilder
    private var chapterStatusIndicator: some View {
        if isFinished {
            Typo.supporting(Image(systemName: "checkmark.circle.fill"))
                .foregroundStyle(Color.shelfAccentText)
        } else if isInProgress {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.shelfMuted.opacity(0.3))
                    .frame(width: 16, height: 4)
                Capsule()
                    .fill(Color.shelfAmber)
                    .frame(width: 16 * chapterProgress, height: 4)
            }
        } else {
            Color.clear.frame(width: 16, height: 4)
        }
    }

    /// Same base wording this accessibility value always had ("Starts at …, … long") —
    /// P-5 keeps the absolute timestamp here even though it's off the visual row, plus
    /// an explicit finished/in-progress callout matching the tick/bar shown visually.
    private var accessibilityValueText: String {
        var parts = [String(localized: "Starts at \(chapter.start.formattedTime)", comment: "VoiceOver: chapter start time; %@ is a timestamp"), String(localized: "\(chapterDuration.formattedDuration) long", comment: "VoiceOver: chapter length; %@ is a duration")]
        if isFinished {
            parts.append(String(localized: "Finished", comment: "VoiceOver: chapter or episode status"))
        } else if isInProgress {
            parts.append(String(localized: "\(Int(chapterProgress * 100)) percent played", comment: "VoiceOver: %lld is a percentage"))
        }
        return parts.joined(separator: ", ")
    }
}

//// One row in a podcast's episode list — title, published date, duration, and a
/// progress bar when the episode has been started. Tapping plays it.
struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    let progress: MediaProgress?
    let onTap: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: (progress?.isFinished ?? false) ? "checkmark.circle.fill" : "play.circle")
                    .foregroundStyle((progress?.isFinished ?? false) ? Color.shelfMuted : Color.shelfAmberText)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Typo.rowTitle(episode.title.map { Text(verbatim: $0) } ?? Text("Untitled episode"))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(2)
                    Typo.fine(HStack(spacing: 6) {
                        if let date = episode.publishedDate {
                            Text(Self.dateFormatter.string(from: date))
                        }
                        if let duration = episode.duration, duration > 0 {
                            Text("·")
                            Text(duration.formattedDuration)
                        }
                    })
                    .foregroundStyle(Color.shelfMuted)
                    if let pct = progress?.progress, pct > 0, pct < 0.99 {
                        ProgressView(value: min(pct, 1))
                            .tint(Color.shelfAmber)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .ignore)
        // Critique 2026-10-06 (harden): VoiceOver heard only the title; the date, length and
        // played state the row shows are read too.
        .accessibilityLabel(Self.accessibilityLabel(
            title: episode.title, date: episode.publishedDate.map { Self.dateFormatter.string(from: $0) },
            duration: episode.duration, progress: progress?.progress, isFinished: progress?.isFinished ?? false))
        .accessibilityHint("Plays this episode")
    }

    /// "Title, 3 Oct 2026, 42 minutes, 30 percent played" / "…, Finished". Pure, pinned by
    /// `BookDetailHardenTests`.
    static func accessibilityLabel(title: String?, date: String?, duration: Double?,
                                   progress: Double?, isFinished: Bool) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [(name?.isEmpty == false ? name! : String(localized: "Untitled episode"))]
        if let date, !date.isEmpty { parts.append(date) }
        if let duration, duration.isFinite, duration > 0 { parts.append(spokenDuration(duration)) }
        if isFinished {
            parts.append(String(localized: "Finished", comment: "VoiceOver: chapter or episode status"))
        } else if let progress, progress > 0, progress < 0.99 {
            parts.append(String(localized: "\(max(1, Int(progress * 100))) percent played", comment: "VoiceOver: %lld is a percentage"))
        }
        return parts.joined(separator: ", ")
    }

    /// "1 hour 5 minutes" rather than "1h 5m", spelled out for VoiceOver as Home's hero label is.
    static func spokenDuration(_ seconds: Double) -> String {
        let total = seconds.safeSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? String(localized: "1 hour") : String(localized: "\(hours) hours")) }
        if minutes > 0 { parts.append(minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes")) }
        return parts.isEmpty ? String(localized: "less than a minute") : parts.joined(separator: " ")
    }
}

// MARK: - String HTML Stripping

extension String {
    /// Review Low (description paragraphs, 30 October 2026): true when the text has a tag or an
    /// entity, i.e. it needs the HTML parser. Plain text goes through the parser otherwise and
    /// loses its newlines (HTML collapses them).
    nonisolated var looksLikeHTML: Bool {
        range(of: "<[A-Za-z/!]", options: .regularExpression) != nil
            || range(of: "&#?[A-Za-z0-9]+;", options: .regularExpression) != nil
    }

    var strippingHTML: String {
        guard looksLikeHTML else { return trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let data = self.data(using: .utf8) else { return self }
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return self }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    NavigationStack {
        BookDetailView(item: LibraryItem(
            id: "test",
            ino: nil,
            libraryId: nil,
            mediaType: "book",
            media: nil,
            numFiles: nil,
            size: nil,
            addedAt: nil,
            updatedAt: nil,
            mediaProgress: nil
        ))
    }
    .environment(PlayerViewModel())
    .environment(LibraryViewModel())
}

/// A rectangle grown by `amount` above and below its bounds only — a taller hit area for
/// chips that sit side by side (critique 2026-10-05, Book Detail).
private struct VerticalOutsetRect: Shape {
    let amount: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -amount))
    }
}
