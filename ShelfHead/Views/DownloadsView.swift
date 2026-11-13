import SwiftUI
import UIKit

// Batch 266 (29 August 2026): merges what used to be two separate root-menu Settings
// rows — "Downloads & Notifications" (auto-download/Wi-Fi/notification preferences,
// formerly `DownloadsNotificationsSettingsView.swift`, now deleted) and "Downloads &
// Storage" (this file's prior content: active/failed transfers + storage total) — into
// one screen, reachable via a single "Downloads" row. User-reported problem: the two
// rows read as accidental duplicates sitting back-to-back on the Settings root menu.
//
// Also adds a genuinely new "Downloaded Books" section (cover, title, author,
// progress, tappable into Book Detail, with a play/resume swipe action — see the
// SB-5a note below) that didn't exist anywhere in the main app outside
// three-taps-deep Diagnostics → Download Health — restoring an actual central place
// to see what's on this device now that the old Downloads *tab* (which had its own
// completed-downloads browsing list) is gone; see the Stage 3 doc comment below for
// that history. Sources each item from `DownloadManager.downloadedLibraryItems()`,
// which itself walks each item's on-disk manifest (`DownloadManager.manifest(for:)`,
// same source `DownloadHealthView` already uses), so this list works fully offline
// and doesn't depend on `LibraryViewModel` having loaded anything from the server —
// only on a `LibraryViewModel` existing in the environment for `LibraryListRow`'s own
// (optional, offline-safe-fallback) progress lookup.
//
// Deliberately does NOT duplicate `DownloadHealthView`'s own "Downloaded Books"
// section — that one exists to run Verify/Repair against each file's on-disk
// integrity, a diagnostic action, not a preference or "what do I have downloaded"
// browsing concern.
//
// SB-5a (REVIEW_2026-09-14_DESIGN.md): the paragraph this replaces argued rows here
// couldn't be tappable into `BookDetailView` because building a full `LibraryItem`
// from a `DownloadedBook` manifest would mean fabricating fields the manifest
// doesn't carry. That reasoning no longer holds — `DownloadedBook.asLibraryItem()`
// already does exactly that reconstruction, and `LibraryViewModel.loadItems()`'s own
// offline fallback (`DownloadManager.downloadedLibraryItems()`, ~lines 384/430) has
// been feeding those same reconstructed items straight into `LibraryView`'s grid/list
// rows and into `BookDetailView` for a while now, fully offline. This section reuses
// that identical path instead of a stripped-down id/title/author summary: each row is
// `LibraryListRow` (the same list-mode row `LibraryView` renders) so it gets a cover,
// progress, and a real tap-through to `BookDetailView`, plus a leading swipe action
// that calls `PlayerViewModel.startPlayback(for:)` — the same entry point Library and
// Book Detail use, which already falls back to `DownloadManager.localSession(for:)`
// when there's no network.
//
// SB-5a follow-up (same review): split into shared, private `Section`-returning
// views so `DownloadsSettingsView(bottomInset:)` — Settings > Downloads: Preferences,
// Notifications, in-flight downloads, the books list, an empty state, then Storage —
// isn't one monolithic body. 16 September 2026: the other consumer of those section
// views, the tab-2 root `DownloadsView()`, is gone with the tab; the split stays
// because it also keeps this file's single screen easier to read in pieces.
//
// Stage 3 (REDESIGN_PROPOSAL_2026-08-26.md §2.1): this file used to be the Downloads
// *tab*'s root — a mix of download management (progress, retries, storage) and a
// browsable list of completed downloads. The completed-downloads browsing half was
// removed entirely back then: it was always just a duplicate, less capable render of
// what Library's existing `downloadedOnly` filter chip already shows (search, sort,
// list/grid, swipe actions), so it needed no new code, just deletion. What's below is
// a different thing from that old browsing list — informational/manageable, not a
// full library browse — re-added specifically because Settings had no "what's
// downloaded" view left at all after the tab was removed.
//
// Kept as the same file/type-location history as before (no Xcode project-file
// surgery for this file) — only the struct's name, content, and presentation context
// changed.

/// T10 (REVIEW_2026-09-04_UI.md): single source of truth for the destructive
/// "remove all downloads" confirmation, shared by Settings > Downloads and
/// Settings > Diagnostics > Download Health so the same action reads the same way.
enum RemoveAllDownloadsCopy {
    /// Critique 2026-10-06 (clarify): title case, like every other alert title here.
    static var title: String { String(localized: "Remove All Downloads?") }
    static var confirm: String { String(localized: "Remove All", comment: "Destructive confirmation button: remove every download") }

    /// `storageUsed` is the formatted size (e.g. "1.2 GB"), or nil when unknown.
    static func message(storageUsed: String?) -> String {
        let frees: String
        if let storageUsed {
            frees = String(localized: "This frees \(storageUsed) for the current account.", comment: "%@ is a size such as 1.2 GB")
        } else {
            frees = String(localized: "This removes the current account's downloaded files.")
        }
        return String(localized: "\(frees) Books stay in your library and can be re-downloaded; your listening progress isn't affected.", comment: "%@ is the preceding sentence about what is freed or removed")
    }
}

/// Critique 2026-10-06 (clarify): "1 books" on the Storage row. Pure, pinned by
/// `DownloadsCopyTests`.
enum DownloadCountCopy {
    static func books(_ count: Int) -> String {
        count == 1 ? String(localized: "1 book") : String(localized: "\(count) books")
    }
}

/// Batch 496 (REVIEW 2026-11-11 D5): copy for removing several downloads at once from the
/// Downloads page. Pure, pinned by `Batch496DownloadsSelectionTests`.
enum DownloadsRemovalCopy {
    /// Sum of the cached sizes of the selected books; nil when none of them is known yet.
    static func totalBytes(of ids: Set<String>, sizes: [String: Int64]) -> Int64? {
        let known = ids.compactMap { sizes[$0] }.filter { $0 > 0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// "Remove (3) · 2.1 GB"; "Remove (3)" while sizes are unknown; "Remove" with nothing selected.
    static func buttonTitle(count: Int, bytes: Int64?) -> String {
        guard count > 0 else { return String(localized: "Remove", comment: "Downloads select mode: remove button with nothing selected") }
        let number = count.formatted()
        guard let bytes, bytes > 0 else {
            return String(localized: "Remove (\(number))", comment: "Downloads select mode: remove button. %@ is how many books are selected")
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "Remove (\(number)) \u{00B7} \(size)",
                      comment: "Downloads select mode: remove button. First %@ is how many books are selected, second the space freed, e.g. 2.1 GB")
    }

    static func confirmationTitle(count: Int) -> String {
        guard count != 1 else { return String(localized: "Remove This Download?") }
        let number = count.formatted()
        return String(localized: "Remove \(number) Downloads?", comment: "Confirmation title. %@ is a number of books (2 or more)")
    }

    static func confirmButton(count: Int) -> String {
        guard count != 1 else { return String(localized: "Remove Download") }
        let number = count.formatted()
        return String(localized: "Remove \(number) Downloads", comment: "Destructive confirmation button. %@ is a number of books (2 or more)")
    }

    static func message(count: Int) -> String {
        count == 1
            ? String(localized: "The downloaded audio will be deleted from this device. Your progress is kept.")
            : String(localized: "The downloaded audio for these books will be deleted from this device. Your progress is kept.")
    }
}

/// Batch 496 (REVIEW 2026-11-11 D4): the Storage section's bar, modelled on Settings › General ›
/// iPhone Storage: one proportional strip, then a labelled row per segment so nothing is told
/// apart by colour alone. Pure, pinned by `Batch496DownloadsStorageTests`.
enum DownloadStorageBreakdown {
    enum Kind: CaseIterable, Equatable {
        case thisAccount, otherAccounts, signedOut, transcripts, covers, free
    }

    struct Segment: Equatable {
        let kind: Kind
        let bytes: Int64
    }

    /// The segments to draw, in order, skipping empty and unknown ones. `otherAccounts` is the
    /// saved accounts' share only: signed-out servers are their own segment.
    static func segments(thisAccount: Int64, otherAccounts: Int64, signedOut: Int64,
                         transcripts: Int64?, covers: Int64?, free: Int64?) -> [Segment] {
        let all: [(Kind, Int64?)] = [(.thisAccount, thisAccount), (.otherAccounts, otherAccounts),
                                     (.signedOut, signedOut), (.transcripts, transcripts),
                                     (.covers, covers), (.free, free)]
        return all.compactMap { kind, bytes in
            guard let bytes, bytes > 0 else { return nil }
            return Segment(kind: kind, bytes: bytes)
        }
    }

    /// Each segment's share of the bar's width. A non-empty segment never shrinks below
    /// `minimumFraction`, so a small cache still shows; the rest are scaled to fit.
    static func fractions(_ segments: [Segment], minimumFraction: Double = 0.02) -> [Double] {
        let total = Double(segments.reduce(Int64(0)) { $0 + $1.bytes })
        guard total > 0 else { return segments.map { _ in 0 } }
        let raw = segments.map { Double($0.bytes) / total }
        let floor = min(minimumFraction, 1 / Double(max(segments.count, 1)))
        let lifted = raw.map { max($0, floor) }
        let liftedTotal = lifted.reduce(0, +)
        let bumpedExtra = liftedTotal - 1
        guard bumpedExtra > 0 else { return lifted }
        // Take the extra back from the segments above the floor, in proportion to their size.
        let reducible = zip(lifted, raw).filter { $0.1 > floor }.reduce(0) { $0 + $1.0 }
        guard reducible > 0 else { return lifted.map { $0 / liftedTotal } }
        return zip(lifted, raw).map { value, original in
            original > floor ? value - bumpedExtra * (value / reducible) : value
        }
    }

    static func label(for kind: Kind) -> String {
        switch kind {
        case .thisAccount: return String(localized: "This account’s downloads", comment: "Storage row and bar segment")
        case .otherAccounts: return String(localized: "Other accounts", comment: "Storage row and bar segment: downloads of other saved accounts")
        case .signedOut: return String(localized: "Signed-out servers", comment: "Storage row and bar segment: downloads kept for servers the user signed out of")
        case .transcripts: return String(localized: "Transcripts and ebooks", comment: "Storage row and bar segment")
        case .covers: return String(localized: "Cover cache", comment: "Storage row and bar segment")
        case .free: return String(localized: "Free on this iPhone", comment: "Storage row and bar segment: free space on the device")
        }
    }

    /// What VoiceOver reads for the bar: every segment by name and size, in order.
    static func accessibilitySummary(_ segments: [Segment]) -> String {
        let parts = segments.map { segment in
            let size = ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file)
            return String(localized: "\(label(for: segment.kind)), \(size)",
                          comment: "Storage bar, spoken. First %@ is a segment name, second its size")
        }
        return parts.isEmpty ? String(localized: "No storage figures yet", comment: "Storage bar, spoken, before sizes are known")
                             : parts.joined(separator: "; ")
    }
}

/// Critique 2026-10-06 (distill): the Downloads page's sort menu.
enum DownloadsSortOrder: String, CaseIterable, Identifiable {
    case title, recentlyDownloaded, size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return String(localized: "Title", comment: "Sort option")
        case .recentlyDownloaded: return String(localized: "Recently Downloaded", comment: "Sort option")
        case .size: return String(localized: "Size", comment: "Sort option: file size")
        }
    }
}

/// Critique 2026-10-06 (distill): the Downloads page's sort orders, pure so they're
/// pinned by `DownloadsCopyTests`. Title keeps the page's existing comparator
/// (`DownloadedBookSummary.isOrderedBeforeByTitle`). Recently downloaded is newest
/// first and size is largest first; a book with no date or size yet goes last, and ties
/// fall back to title.
enum DownloadsSort {
    struct Key: Equatable {
        let id: String
        let title: String
        var downloadedAt: Date? = nil
        var bytes: Int64? = nil
    }

    static func orderedIDs(_ keys: [Key], by order: DownloadsSortOrder) -> [String] {
        func byTitle(_ a: Key, _ b: Key) -> Bool {
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        let sorted: [Key]
        switch order {
        case .title:
            sorted = keys.sorted(by: byTitle)
        case .recentlyDownloaded:
            sorted = keys.sorted { a, b in
                switch (a.downloadedAt, b.downloadedAt) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byTitle(a, b)
                }
            }
        case .size:
            sorted = keys.sorted { a, b in
                let x = a.bytes.flatMap { $0 > 0 ? $0 : nil }
                let y = b.bytes.flatMap { $0 > 0 ? $0 : nil }
                switch (x, y) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byTitle(a, b)
                }
            }
        }
        return sorted.map(\.id)
    }
}

/// SB-5a follow-up: true only when there is nothing downloaded and nothing in
/// flight — `DownloadsSettingsView`'s "show the empty state" check. A `private
/// extension` here rather than a change to `Services/DownloadManager.swift`, which
/// this batch doesn't own.
private extension DownloadManager {
    var hasNoDownloadsAtAll: Bool {
        activeDownloads.isEmpty && failedDownloads.isEmpty && downloadedItems.isEmpty
    }
}

// MARK: - Settings > Downloads (full screen)

struct DownloadsSettingsView: View {
    var bottomInset: CGFloat = 0
    /// Critique 2026-10-06 (clarify): the `SettingsRow` a search result opened, if any.
    var focusRow: String? = nil
    /// False when reached from the Downloads page's own gear, so the link back to that
    /// page doesn't stack a second copy of it.
    var showsDownloadedBooksLink: Bool = true
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerViewModel.self) private var playerViewModel

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    // MARK: - Downloaded Books (new)

    /// A plain `(id:title:author:)` tuple isn't usable as `ForEach`'s `id:` key path —
    /// Swift key paths can't refer to tuple elements — so this needs a real
    /// `Identifiable` struct, same reason `DownloadHealthView` has its own.
    ///
    /// Not `private`: `DownloadsViewSortTests` references this type directly to pin
    /// `isOrderedBeforeByTitle` below (Item 34). Also referenced by
    /// `DownloadedBooksSection` below (a sibling type in this file) to sort the full
    /// `LibraryItem` list it renders.
    struct DownloadedBookSummary: Identifiable, Equatable {
        let id: String
        let title: String
        let author: String

        /// Item 34 (perf review): this screen's own row list used to redo its own
        /// `manifest(for:)` walk over every downloaded id on each `body` evaluation —
        /// entirely bypassing `DownloadManager.downloadedLibraryItems()`'s own cache of
        /// that exact same walk. That cache couldn't be used directly, though: it sorts
        /// with `localizedStandardCompare` (numeric-aware — "Book 2" before "Book 10"),
        /// while this screen has always sorted with `localizedCaseInsensitiveCompare`,
        /// so swapping in the cached array as-is would silently reorder rows. Extracted
        /// here as a pure, static comparator so `DownloadedBooksSection`'s own
        /// `downloadedDisplayItems` can consume the cached list and re-sort with
        /// today's rule on top, and so the exact ordering rule is pinned by a test
        /// independent of `DownloadManager`'s own cache.
        static func isOrderedBeforeByTitle(_ lhs: DownloadedBookSummary, _ rhs: DownloadedBookSummary) -> Bool {
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            // Critique 2026-10-06 (distill): Settings > Downloads listed every downloaded
            // book (and the transfers) above Storage, so on a big library Storage was a
            // long scroll away. It's preferences and storage only now; the books and
            // transfers are on the Downloads page, one tap away through this link.
            SettingsAnchoredList(focusRow: focusRow) {
                if showsDownloadedBooksLink {
                    Section {
                        LibraryRouteLink(.downloads, bottomInset: bottomInset) {
                            DownloadedBooksLinkLabel()
                        }
                        .settingsRowAnchor(SettingsRow.downloadedBooksLink)
                    }
                }
                DownloadPreferencesSection()
                DownloadStorageSection()
            }
            // Per-item-size-at-launch fix: this used to live on `DownloadStorageSection`
            // alone, at the bottom of this list — on a long downloads list that section
            // never scrolled into view, so `itemStorageBytes`/`totalStorageBytes` never
            // got their first walk from this screen at all. Moved to the list root so
            // simply opening Settings > Downloads (regardless of scroll position)
            // triggers exactly one walk; `refreshStorageUsed()`'s own throttle absorbs a
            // walk that already just ran (e.g. from `bootstrapIfNeeded()` at launch).
            .task {
                downloadManager.refreshStorageUsed()
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

// MARK: - Shared section views
//
// SB-5a follow-up: extracted so `DownloadsSettingsView` composes each piece rather
// than carrying one monolithic body. Each is self-contained — its own `@State`/
// `@Environment` — the same pattern `ActiveDownloadRow`/`FailedDownloadRow`/
// `LibraryView`'s `LibraryGridTile` already use for a reusable row/section that reads
// `DownloadManager.shared` on its own rather than being handed it.

/// The "Downloading" and "Couldn't Download" sections — exactly what "in flight"
/// means to a user checking on a download.
/// The dedicated Downloads page (16 September 2026, user request) — reached from the
/// Downloads button at the top-left of Library. Books first: what's downloading, what's
/// failed, and every downloaded book, playable from here. Preferences and storage live
/// on `DownloadsSettingsView` (Settings > Downloads), one tap away via the gear, so this
/// screen stays a browse surface rather than a settings form.
struct DownloadsView: View {
    var bottomInset: CGFloat = 0
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Critique 2026-10-06 (distill): the sort menu's choice, remembered on this device.
    @AppStorage("downloadsPageSortOrder") private var sortOrderRaw = DownloadsSortOrder.title.rawValue
    /// When each book's download folder was created — "Recently Downloaded" order. The
    /// manifest carries no download date, so this reads the folder's creation date once
    /// per change to the downloaded set, off the main thread.
    @State private var downloadedDates: [String: Date] = [:]
    /// Batch 496 (REVIEW 2026-11-11 D5): standard list editing to remove several downloads.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var confirmingRemoval = false

    private var isSelecting: Bool { editMode.isEditing }

    /// Only downloaded books can be selected; ids that stopped being downloaded drop out.
    private var selectedDownloads: Set<String> {
        selection.intersection(downloadManager.downloadedItems)
    }

    private var sortOrder: DownloadsSortOrder {
        DownloadsSortOrder(rawValue: sortOrderRaw) ?? .title
    }

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()

            if downloadManager.hasNoDownloadsAtAll {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: LocalizedStringResource("No downloads yet"),
                    subtitle: LocalizedStringResource("Download a book from its detail page to listen to it here, fully offline.")
                )
            } else {
                // Batch 496 (D5): while selecting, only the downloaded books are listed, so
                // only they can be selected.
                List(selection: $selection) {
                    if !isSelecting {
                        DownloadsStorageSummarySection()
                        DownloadsInFlightSections()
                    }
                    DownloadedBooksSection(sortOrder: sortOrder, downloadedDates: downloadedDates,
                                           isSelecting: isSelecting)
                }
                .environment(\.editMode, $editMode)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if isSelecting { removeSelectionBar }
                Color.clear.frame(height: bottomClearance)
            }
        }
        .onChange(of: downloadManager.downloadedItems.isEmpty) { _, isEmpty in
            if isEmpty { endSelecting() }
        }
        .confirmationDialog(DownloadsRemovalCopy.confirmationTitle(count: selectedDownloads.count),
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(DownloadsRemovalCopy.confirmButton(count: selectedDownloads.count), role: .destructive) {
                downloadManager.removeDownloads(itemIds: Array(selectedDownloads))
                Haptics.impact(.medium)
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DownloadsRemovalCopy.message(count: selectedDownloads.count))
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        // Storage figures for the summary header and the Size order.
        .task { downloadManager.refreshStorageUsed() }
        .task(id: downloadManager.downloadedItems) {
            let folders = downloadManager.downloadedItems.map { ($0, downloadManager.downloadDirectory(for: $0)) }
            downloadedDates = await Task.detached(priority: .utility) {
                var dates: [String: Date] = [:]
                for (id, url) in folders {
                    if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date {
                        dates[id] = date
                    }
                }
                return dates
            }.value
        }
        // HIG audit 2026-09-17 L17: monochrome toolbar icons (see View.monochromeToolbarItem)
        .toolbar {
            // Batch 496 (REVIEW 2026-11-11 D5): Select / Done, the standard list-editing entry.
            if !downloadManager.downloadedItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isSelecting { endSelecting() } else { withAnimation { editMode = .active } }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                            .fontWeight(isSelecting ? .semibold : .regular)
                    }
                    .accessibilityHint(isSelecting ? Text("Stops selecting") : Text("Select downloads to remove several at once"))
                }
            }
            if !downloadManager.downloadedItems.isEmpty && !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    // Critique 2026-10-06 (distill): Downloads had no sort.
                    Menu {
                        Picker("Sort By", selection: $sortOrderRaw) {
                            ForEach(DownloadsSortOrder.allCases) { order in
                                Text(order.label).tag(order.rawValue)
                            }
                        }
                    } label: {
                        Label("Sort downloads", systemImage: "arrow.up.arrow.down") // iPhone Duo (§2)
                    }
                    .monochromeToolbarItem()
                    .accessibilityValue(sortOrder.label)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                LibraryRouteLink(.downloadsSettings(showsDownloadedBooksLink: false), bottomInset: bottomInset) {
                    Label("Download settings", systemImage: "gearshape")
                }
                .monochromeToolbarItem()
                .accessibilityHint("Preferences and storage")
            }
        }
        .reexpandsTabBarOnAppear()
    }

    private func endSelecting() {
        withAnimation { editMode = .inactive }
        selection.removeAll()
    }

    /// Batch 496 (D5): "Remove (3) · 2.1 GB", pinned above the tab bar / mini player while
    /// selecting. Disabled until something is selected.
    private var removeSelectionBar: some View {
        let ids = selectedDownloads
        let title = DownloadsRemovalCopy.buttonTitle(
            count: ids.count, bytes: DownloadsRemovalCopy.totalBytes(of: ids, sizes: downloadManager.itemStorageBytes))
        return Button(role: .destructive) {
            confirmingRemoval = true
        } label: {
            // DESIGN.md: orange is a fill, with `shelfOrangeInk` drawn on it (no orange text).
            Label(title, systemImage: "trash")
                .foregroundStyle(Color.shelfOrangeInk)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.shelfOrange)
        .disabled(ids.isEmpty)
        .padding(.horizontal, Space.pageH)
        .padding(.vertical, Space.s)
        .background(Color.shelfBackground)
    }
}

/// Critique 2026-10-06 (distill): the Downloads page's storage summary — how many books
/// and how much space, at the top, with the full storage controls behind the gear.
private struct DownloadsStorageSummarySection: View {
    @State private var downloadManager = DownloadManager.shared

    var body: some View {
        if !downloadManager.downloadedItems.isEmpty {
            Section {
                HStack(spacing: Space.m) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DownloadCountCopy.books(downloadManager.downloadedItems.count)) on this device")
                            .foregroundStyle(Color.shelfCream)
                        Typo.figure(Text("\(downloadManager.formattedStorageUsed) used"))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.shelfCard)
        }
    }
}

/// Critique 2026-10-06 (distill): Settings > Downloads' link to the Downloads page —
/// "Downloaded books (N)", plus what's transferring when anything is.
private struct DownloadedBooksLinkLabel: View {
    @State private var downloadManager = DownloadManager.shared

    private var transferSummary: String? {
        // Batch 496 (REVIEW 2026-11-11 D2): books waiting their turn are counted on their own.
        let queued = downloadManager.activeDownloads.values.filter(\.isQueued).count
        let active = downloadManager.activeDownloads.count - queued
        let failed = downloadManager.failedDownloads.count
        var parts: [String] = []
        if active > 0 { parts.append(String(localized: "\(active) downloading", comment: "%lld is a number of active downloads")) }
        if queued > 0 {
            let count = queued.formatted()
            parts.append(String(localized: "\(count) queued", comment: "%@ is a number of downloads waiting their turn"))
        }
        if failed > 0 { parts.append(String(localized: "\(failed) couldn\u{2019}t download", comment: "%lld is a number of failed downloads")) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingRow("books.vertical", "Downloaded books (\(downloadManager.downloadedItems.count))")
            if let transferSummary {
                Typo.supporting(Text(transferSummary))
                    .foregroundStyle(Color.shelfMuted)
                    .padding(.leading, 32)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DownloadsInFlightSections: View {
    @State private var downloadManager = DownloadManager.shared
    /// D1: the waiting download the user is confirming "Download Now on Mobile Data" for.
    @State private var cellularConfirmation: DownloadTask?
    /// Batch 496 (REVIEW 2026-11-11 D2): Cancel All is waiting on its confirmation.
    @State private var confirmingCancelAll = false

    /// D1: whether this row is waiting for Wi-Fi right now (and so offers "Download Now").
    private func isWaitingForWiFi(_ task: DownloadTask) -> Bool {
        !task.isPaused && NetworkMonitor.shared.isConnected && DownloadPolicyStatus.waitsForWiFi(
            wifiOnly: SettingsStore.wifiOnlyDownloads, onWiFi: NetworkMonitor.shared.isOnWiFi,
            cellularOverridden: task.cellularOverride)
    }

    private func downloadNowSize(_ task: DownloadTask) -> Int64 {
        task.bytesExpected > 0 ? task.bytesExpected : task.knownSizeBytes
    }

    var body: some View {
        // Polish pass (DL-3): automatic downloads held back by Wi-Fi-only / charging-only used
        // to fail silently. One line; `currentAutoDownloadDeferral` re-checks the live gates,
        // so it clears when Wi-Fi/power returns (the stored reason is observable, and the
        // next auto-download pass resets it).
        if let deferral = downloadManager.currentAutoDownloadDeferral {
            Section {
                Typo.supporting(Text(deferral.message))
                    .foregroundStyle(Color.shelfMuted)
                    .listRowBackground(Color.clear)
            }
        }
        if !downloadManager.activeDownloads.isEmpty {
            Section {
                // Batch 496 (REVIEW 2026-11-11 D2): queue order (transferring, then waiting in
                // the order they'll start), not alphabetical.
                ForEach(downloadManager.orderedActiveDownloads) { task in
                    let position = downloadManager.queuePosition(of: task.id)
                    ActiveDownloadRow(task: task, onCancel: {
                        downloadManager.cancelDownload(itemId: task.id)
                    }, onPauseResume: {
                        if task.isPaused {
                            downloadManager.resumeDownload(itemId: task.id)
                        } else {
                            downloadManager.pauseDownload(itemId: task.id)
                        }
                    }, queuePosition: position)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    // D1 (REVIEW 2026-11-11): a download waiting for Wi-Fi can be sent over
                    // mobile data for this one book. Swipe and touch-and-hold both offer it.
                    // Batch 496 (D2): a waiting book that isn't first also offers Download Next.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isWaitingForWiFi(task) {
                            Button {
                                cellularConfirmation = task
                            } label: {
                                Label(DownloadPolicyStatus.downloadNowTitle(bytes: downloadNowSize(task)), systemImage: "antenna.radiowaves.left.and.right")
                            }
                            .tint(Color.shelfAmber)
                        }
                        if let position, position > 1 {
                            Button {
                                downloadManager.downloadNext(itemId: task.id)
                            } label: {
                                Label("Download Next", systemImage: "arrow.up.to.line")
                            }
                            .tint(Color.shelfAmberDark)
                        }
                    }
                    .contextMenu {
                        if let position, position > 1 {
                            Button {
                                downloadManager.downloadNext(itemId: task.id)
                            } label: {
                                Label("Download Next", systemImage: "arrow.up.to.line")
                            }
                        }
                        if isWaitingForWiFi(task) {
                            Button {
                                cellularConfirmation = task
                            } label: {
                                Label(DownloadPolicyStatus.downloadNowTitle(bytes: downloadNowSize(task)), systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                    }
                    .accessibilityActions {
                        if let position, position > 1 {
                            Button("Download Next") { downloadManager.downloadNext(itemId: task.id) }
                        }
                    }
                }
            } header: {
                // Batch 496 (D2): Pause All / Resume All / Cancel All for the whole queue, in one
                // menu so the header stays one line at large text sizes.
                HStack(spacing: Space.s) {
                    RetroSectionHeader(title: LocalizedStringResource("Downloading", comment: "Downloads section header"))
                    Menu {
                        Button {
                            downloadManager.pauseAllDownloads()
                        } label: {
                            Label("Pause All", systemImage: "pause.circle")
                        }
                        .disabled(!downloadManager.canPauseAll)
                        Button {
                            downloadManager.resumeAllDownloads()
                        } label: {
                            Label("Resume All", systemImage: "arrow.down.circle")
                        }
                        .disabled(!downloadManager.canResumeAll)
                        Button(role: .destructive) {
                            confirmingCancelAll = true
                        } label: {
                            Label("Cancel All", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(Color.shelfAmberText)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Download actions")
                }
            }
            .confirmationDialog(
                "Cancel All Downloads?",
                isPresented: $confirmingCancelAll,
                titleVisibility: .visible
            ) {
                Button("Cancel All Downloads", role: .destructive) {
                    downloadManager.cancelAllQueuedDownloads()
                    Haptics.impact(.medium)
                }
                Button("Keep Downloading", role: .cancel) {}
            } message: {
                Text("Books still downloading or waiting will stop, and what they’ve downloaded so far will be deleted.")
            }
            .confirmationDialog(
                cellularConfirmation.map { DownloadPolicyStatus.downloadNowTitle(bytes: downloadNowSize($0)) } ?? "",
                isPresented: Binding(get: { cellularConfirmation != nil }, set: { if !$0 { cellularConfirmation = nil } }),
                titleVisibility: .visible,
                presenting: cellularConfirmation
            ) { task in
                Button(DownloadPolicyStatus.downloadNowTitle(bytes: downloadNowSize(task))) {
                    downloadManager.downloadNowOnCellular(itemId: task.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                Text(DownloadPolicyStatus.downloadNowMessage(title: task.title, bytes: downloadNowSize(task)))
            }
        }

        // Failed downloads (ARCH-5) — previously these vanished entirely: dropped
        // from `activeDownloads` and never added to `downloadedItems`, so neither
        // section here could show them, with no way to retry or free the bytes they
        // still occupied on disk.
        if !downloadManager.failedDownloads.isEmpty {
            Section {
                ForEach(downloadManager.failedDownloads.values.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }) { failure in
                    FailedDownloadRow(
                        failure: failure,
                        onRetry: { Task { await downloadManager.retryFailedDownload(itemId: failure.itemId) } },
                        onRemove: { downloadManager.removeFailedDownload(itemId: failure.itemId) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } header: {
                RetroSectionHeader(title: LocalizedStringResource("Couldn't Download", comment: "Downloads section header for failed downloads"))
            }
        }
    }
}

/// Batch 317 follow-up (deferred item, `CHANGES_IMPLEMENTED.md`): the pure formatter
/// behind `DownloadedBooksSection`'s per-row detail line, pulled out to a standalone
/// type so `DownloadRowDetailTests` can pin it independent of the view's own body.
///
/// Batch 318 follow-up: now also takes an optional on-disk byte count, producing
/// "8h 12m · 412 MB". This was originally duration-only because `DownloadManager` only
/// cached a *total* across every downloaded book, and computing a per-row size here
/// would have meant a fresh `FileManager` enumeration of that book's directory on every
/// row, on every `body` re-run this section already gets at download-progress callback
/// frequency — exactly the per-row filesystem walk that note said not to add.
/// `DownloadManager.itemStorageBytes` now caches that figure per item (populated by the
/// same recursive walk `refreshStorageUsed()` already did, not a second one — see that
/// property's doc comment), so this formatter can take the cached byte count as a
/// plain `Int64?` with no I/O of its own. `bytes` defaults to `nil` so existing
/// single-argument call sites (`DownloadRowDetailTests`) keep compiling unchanged.
enum DownloadRowDetail {
    /// `nil` duration when the manifest carries no usable duration (a manifest written
    /// before duration was recorded, or a corrupted/zero value) — matches
    /// `LibraryListRow`'s own `detail: String? = nil` convention of omitting the line
    /// entirely rather than showing a misleading "0h 0m". `nil`/non-positive `bytes`
    /// (size not yet cached — e.g. before the first post-launch storage walk lands)
    /// falls back to duration-only rather than showing a size of zero. Both `nil`
    /// yields `nil` (no detail line at all), matching the previous duration-only
    /// behavior exactly.
    static func text(forDuration duration: Double, bytes: Int64? = nil) -> String? {
        let durationText: String? = (duration.isFinite && duration > 0) ? duration.formattedDuration : nil
        var sizeText: String?
        if let bytes, bytes > 0 {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        switch (durationText, sizeText) {
        case let (duration?, size?): return String(localized: "\(duration) · \(size)", comment: "Duration and file size separated by a dot; %1$@ is a duration, %2$@ a size")
        case let (duration?, nil): return duration
        case let (nil, size?): return size
        case (nil, nil): return nil
        }
    }
}

/// The "Downloaded Books" section — a real central place to see what's downloaded,
/// restored after the old Downloads tab's own browsing list was removed in Stage 3.
///
/// SB-5a: each row is `LibraryListRow` — the same list-mode row `LibraryView` renders
/// — reused as-is rather than inventing a third look, so it already carries a cover
/// (`CoverImageView`, auth-routed and cached the same way Library loads it), title,
/// author, a finished checkmark or progress ring, a downloaded badge, a now-playing
/// indicator, its own combined VoiceOver label, and a tap-through `NavigationLink` to
/// the real `BookDetailView(item:)` — all sourced from the full reconstructed
/// `LibraryItem` (see the file header comment), which works fully offline.
/// `LibraryListRow` has no built-in play control, so a leading swipe action adds one
/// here, exposed to VoiceOver as a custom action on the row.
///
/// Batch 317 follow-up: `LibraryListRow` now takes an optional `detail` — each row
/// here passes a "duration · size" string built by
/// `DownloadRowDetail.text(forDuration:bytes:)`, the size coming from
/// `DownloadManager.itemStorageBytes` (Batch 318 follow-up — see that property's and
/// the formatter's own doc comments for why this doesn't cost a per-row filesystem
/// walk).
private struct DownloadedBooksSection: View {
    /// Critique 2026-10-06 (distill): the Downloads page's chosen order.
    var sortOrder: DownloadsSortOrder = .title
    /// Folder creation dates, for `.recentlyDownloaded`.
    var downloadedDates: [String: Date] = [:]
    /// Batch 496 (REVIEW 2026-11-11 D5): true while the page is in Select mode; the list's
    /// edit mode owns the tap, so rows don't navigate and the swipe actions are off.
    var isSelecting = false
    /// The book whose swipe-Remove is waiting on the "Remove this download?" confirmation.
    @State private var pendingRemoval: LibraryItem?
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerViewModel.self) private var playerViewModel
    /// iPhone Duo (§3): set only in the split view's sidebar column; a tap then opens the
    /// book in the detail column instead of pushing Book Detail inside the sidebar.
    @Environment(\.libraryDetailSelection) private var detailSelection

    /// Item 10/Item 34 (REVIEW-2026-09-09.md / perf review): bound to a local once per
    /// `body` pass (below) rather than read twice (`isEmpty` + `ForEach`) — it walks
    /// every downloaded manifest via `DownloadManager.downloadedLibraryItems()` plus a
    /// locale-aware sort, and this section's `body` re-runs on every download progress
    /// callback, so paying for that work twice per pass for one identical result was
    /// the original bug this precedent fixes.
    ///
    /// `downloadedLibraryItems()` caches its own `localizedStandardCompare`
    /// (numeric-aware) sort; this screen has always sorted with
    /// `localizedCaseInsensitiveCompare` instead (see
    /// `DownloadsSettingsView.DownloadedBookSummary.isOrderedBeforeByTitle`'s doc
    /// comment and `DownloadsViewSortTests`), so pair each item with its summary
    /// purely to re-sort with that pinned comparator, then discard the summary.
    private var downloadedDisplayItems: [LibraryItem] {
        let items = downloadManager.downloadedLibraryItems()
        guard sortOrder != .title else {
            return items
                .map { (item: $0, summary: DownloadsSettingsView.DownloadedBookSummary(id: $0.id, title: $0.title, author: $0.authorName)) }
                .sorted { DownloadsSettingsView.DownloadedBookSummary.isOrderedBeforeByTitle($0.summary, $1.summary) }
                .map { $0.item }
        }
        // Critique 2026-10-06 (distill): the other two orders, through the pure
        // `DownloadsSort` (sizes come from the cached `itemStorageBytes`, no extra walk).
        let keys = items.map {
            DownloadsSort.Key(id: $0.id, title: $0.title,
                              downloadedAt: downloadedDates[$0.id],
                              bytes: downloadManager.itemStorageBytes[$0.id])
        }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DownloadsSort.orderedIDs(keys, by: sortOrder).compactMap { byId[$0] }
    }

    /// Whether `item` is the book currently loaded in the player (any transport state).
    private func isCurrentBook(_ item: LibraryItem) -> Bool {
        playerViewModel.isCurrentBook(item)
    }

    /// The leading swipe action's tap handler — resumes/starts `item` through the same
    /// `PlayerViewModel` entry point Library/Book Detail use (already falls back to a
    /// fully offline `DownloadManager.localSession(for:)` when there's no network), or
    /// toggles play/pause if it's already the loaded book rather than restarting it.
    ///
    /// UX-1 (docs/design-review.md, Round 3): this logic (and the two label helpers
    /// below) used to live only here; it's now `PlayerViewModel.quickPlayOrPause(_:)`
    /// in `Extensions.swift`, shared with `BookContextMenu`'s new Play/Resume item.
    /// These three helpers now just forward to it, keeping this file's own call sites
    /// (and, reading `item.isFinished`/`item.progressPercent` directly rather than
    /// `LibraryViewModel.progressFor(itemId:)`, this screen's behaviour) unchanged.
    private func playOrPause(_ item: LibraryItem) {
        playerViewModel.quickPlayOrPause(item)
    }

    private func playActionLabel(for item: LibraryItem) -> String {
        playerViewModel.quickPlayActionLabel(for: item, finished: item.isFinished, progressPercent: item.progressPercent)
    }

    private func playActionSystemImage(for item: LibraryItem) -> String {
        playerViewModel.quickPlayActionSystemImage(for: item)
    }

    var body: some View {
        let items = downloadedDisplayItems
        Group {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.id) { item in
                    LibraryListRow(
                        item: item,
                        detail: DownloadRowDetail.text(forDuration: item.duration, bytes: downloadManager.itemStorageBytes[item.id]),
                        navigates: !isSelecting,
                        onOpen: detailSelection.map { selection in { selection.wrappedValue = $0 } }
                    )
                        // Batch 490 (REVIEW 2026-11-11 D7): the same touch-and-hold menu as
                        // every other book row (Home, Library, Series), which this list lacked.
                        .bookContextMenu(item)
                        // Batch 496 (D5): no swipe actions while selecting (an empty builder adds none).
                        .swipeActions(edge: .leading) {
                            if !isSelecting {
                                Button {
                                    playOrPause(item)
                                } label: {
                                    Label(playActionLabel(for: item), systemImage: playActionSystemImage(for: item))
                                }
                                .tint(Color.shelfAmber)
                                .accessibilityLabel(playActionLabel(for: item))
                            }
                        }
                        // Follow-up (30 September 2026): Book Detail asks "Remove this download?"
                        // first; this swipe deleted at once. Same confirmation and copy now, and
                        // no full-swipe so one long swipe can't delete by accident.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    pendingRemoval = item
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            } header: {
                RetroSectionHeader(title: LocalizedStringResource("Downloaded Books", comment: "Downloads section header"))
            } footer: {
                // Critique 2026-10-06 (distill): one line.
                Typo.supporting(isSelecting
                                ? Text("Select the books to remove.")
                                : Text("Swipe right to play, or left to remove. Works offline."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        }
        // Critique 2026-10-06 (clarify): title case, like the other alert titles.
        .confirmationDialog("Remove This Download?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { item in
            Button("Remove Download", role: .destructive) {
                downloadManager.removeDownload(itemId: item.id)
                Haptics.impact(.medium)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The downloaded audio will be deleted from this device. Your progress is kept.")
        }
        .systemChromeTint()
    }
}

/// Preferences — formerly `DownloadsNotificationsSettingsView`, one screen's worth of
/// toggles. Extracted so `DownloadsSettingsView` doesn't carry this whole section inline.
///
/// Critique 2026-10-06 (distill): "Stream on cellular" moved to Playback (it governs
/// streaming, not downloads) and "Daily listening reminder" to System & Privacy; the
/// download-complete notification, the one download-specific notification, joined this
/// section. Keys, defaults and side effects are unchanged.
private struct DownloadPreferencesSection: View {
    @AppStorage(SettingsKeys.autoDownloadContinueListening) private var autoDownload = false
    @AppStorage(SettingsKeys.wifiOnlyDownloads) private var wifiOnlyDownloads = true
    @AppStorage(SettingsKeys.downloadWhileCharging) private var downloadWhileCharging = false
    @AppStorage(SettingsKeys.autoDeleteFinished) private var autoDeleteFinished = false

    /// Only used on this section, computed here (`.task` below) rather than in the
    /// root `SettingsView`, which doesn't need to know it exists.
    @State private var cacheSizeText = ""
    /// Batch 495 (D6): how many series have auto-download on; re-read when this list reappears.
    @State private var seriesAutoDownloadCount = 0

    var body: some View {
        Section {
            Toggle(isOn: $autoDownload) {
                // Critique 2026-10-06 (colorize): teal is for finished/complete only; these
                // two rows route through `settingRow` (muted glyph) like their neighbours.
                settingRow("arrow.down.circle.fill", "Auto-download Continue Listening")
            }
            .settingsRowAnchor(SettingsRow.autoDownload)

            Toggle(isOn: $wifiOnlyDownloads) {
                settingRow("wifi", "Download on Wi-Fi only")
            }
            .settingsRowAnchor(SettingsRow.wifiOnly)

            // T4 (REVIEW_2026-09-04_UI.md): this only gates automatic downloads
            // (see `DownloadManager.autoDownloadPolicyAllows` — manual downloads
            // bypass it), but the toggle was always enabled with no indication
            // it's a no-op when auto-download is off. Disable it and explain.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $downloadWhileCharging) {
                    settingRow("bolt.fill", "Auto-download only while charging")
                }
                .disabled(!autoDownload)
                SettingsCaption(text: "Needs Auto-download Continue Listening.")
            }
            // Batch 490 (REVIEW 2026-11-11 N3): searchable, so it gets an anchor.
            .settingsRowAnchor(SettingsRow.chargingOnly)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $autoDeleteFinished) {
                    settingRow("trash.fill", "Auto-delete finished downloads")
                }
                // Critique 2026-10-06 (distill): one line, detail behind the ⓘ.
                SettingsCaption(text: "Frees space once a book is finished.",
                                topic: "Auto-delete finished downloads",
                                detail: "Removes a book\u{2019}s downloaded audio from this device once it\u{2019}s marked finished. To listen again offline, download it again.")
            }
            .settingsRowAnchor(SettingsRow.autoDeleteFinished)

            // Batch 495 (REVIEW 2026-11-11 Y1): "Notify when downloads finish" moved to
            // System & Privacy › Notifications (same key), the one list of notification switches.

            // Batch 495 (REVIEW 2026-11-11 D6): series turned on from a series page's menu had no
            // overview anywhere; this lists them and lets each be turned off.
            NavigationLink {
                SeriesAutoDownloadListView()
            } label: {
                HStack {
                    settingRow("square.stack.3d.down.right", "Auto-download series")
                    Spacer()
                    Typo.supporting(Text(verbatim: seriesAutoDownloadCount.formatted()))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            .settingsRowAnchor(SettingsRow.seriesAutoDownload)

            Button {
                CoverImageCache.shared.removeAllObjects()
                URLCache.shared.removeAllCachedResponses()
                // T9 (REVIEW_2026-09-04_UI.md): was hardcoded to "0 KB", which is
                // wrong as soon as anything repopulates the cache before the view
                // reappears (`.task` only runs once per view lifetime). Re-measure
                // instead of assuming.
                // Batch 490 (REVIEW 2026-11-11 D3): the on-disk cover tier
                // (`Caches/covers/`, up to 200 MB) was never cleared here and never
                // counted, so the row showed a few KB and freed almost nothing. It is
                // cleared off the main thread, then the total is re-measured.
                // `CoverVersions.reset()` (which sign-out pairs with this) is left out on
                // purpose: it only matters across accounts, and resetting it within one
                // account would drop the `?ts=` stamp and fetch each cover twice.
                Task {
                    await Task.detached(priority: .userInitiated) { DiskCoverCache.clear() }.value
                    await refreshCacheSize()
                    // Batch 497: the Storage section's cover-cache row, bar and free space follow.
                    DownloadManager.shared.noteCoverCacheCleared()
                }
            } label: {
                HStack {
                    settingRow("photo.stack", "Clear cover cache")
                    Spacer()
                    Typo.supporting(Text(cacheSizeText)).foregroundStyle(Color.shelfMuted)
                }
            }
            .settingsRowAnchor(SettingsRow.imageCache)
        } header: {
            RetroSectionHeader(title: LocalizedStringResource("Preferences", comment: "Settings > Downloads section header"))
        }
        .listRowBackground(Color.shelfCard)
        .task {
            await refreshCacheSize()
        }
        .onAppear {
            seriesAutoDownloadCount = SeriesAutoDownloadList.names(from: SeriesAutoDownloadList.stored()).count
        }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
    }

    // T9 (REVIEW_2026-09-04_UI.md): extracted from `.task` so the "Clear image cache"
    // action can re-measure afterward instead of hardcoding "0 KB".
    // Batch 490 (REVIEW 2026-11-11 D3): counts the cover folder as well as `URLCache`,
    // walked off the main thread (it lists up to a few thousand files).
    private func refreshCacheSize() async {
        let bytes = await Task.detached(priority: .utility) {
            DiskCoverCache.totalBytes() + Int64(URLCache.shared.currentDiskUsage)
        }.value
        cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Batch 495 (REVIEW 2026-11-11 D6): which series have auto-download on. Pure so the
/// filtering and order are pinned by a test.
enum SeriesAutoDownloadList {
    /// Series names whose flag is on, in a stable, case-insensitive alphabetical order.
    static func names(from stored: [String: Bool]) -> [String] {
        stored.filter { $0.value && !$0.key.isEmpty }.map(\.key).sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }

    /// What `SettingsStore.setSeriesAutoDownload` has written.
    static func stored() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.seriesAutoDownload) as? [String: Bool]) ?? [:]
    }
}

/// Batch 495 (REVIEW 2026-11-11 D6): Settings › Downloads › Auto-download series. The list is
/// read once when the page opens, so a series switched off stays on screen and can be switched
/// back on during the same visit.
private struct SeriesAutoDownloadListView: View {
    @State private var names: [String] = []
    @State private var enabled: Set<String> = []

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            List {
                Section {
                    if names.isEmpty {
                        Typo.supporting(Text("No series yet. Turn on \u{201C}Auto-download next\u{201D} in a series\u{2019} menu."))
                            .foregroundStyle(Color.shelfMuted)
                    } else {
                        ForEach(names, id: \.self) { name in
                            Toggle(isOn: binding(for: name)) {
                                Text(verbatim: name)
                            }
                        }
                    }
                } footer: {
                    Text("Near the end of a book in one of these series, the next unfinished book downloads, following your download preferences.")
                }
                .listRowBackground(Color.shelfCard)
            }
            .scrollContentBackground(.hidden)
            .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        }
        .navigationTitle("Auto-download Series")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard names.isEmpty else { return }
            names = SeriesAutoDownloadList.names(from: SeriesAutoDownloadList.stored())
            enabled = Set(names)
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(name) },
            set: { on in
                if on { enabled.insert(name) } else { enabled.remove(name) }
                SettingsStore.setSeriesAutoDownload(on, for: name)
            }
        )
    }
}

/// Critique 2026-10-06 (harden): how Settings › Downloads splits "Other accounts" from the signed-out
/// servers' row. Pure so the split is pinned by a test.
enum SignedOutStorage {
    /// Other saved accounts' downloads, excluding the signed-out servers' share. The two
    /// figures come from separate walks, so a stale signed-out figure can exceed the total.
    static func savedAccountsShare(otherScopes: Int64, signedOut: Int64) -> Int64 {
        max(0, otherScopes - signedOut)
    }

    static var removeTitle: String { String(localized: "Remove Downloads from Signed-Out Servers?") }

    /// Critique 2026-10-06 (clarify): the confirmation states how much it frees.
    static func removeMessage(size: String?) -> String {
        let lead = size.map { String(localized: "Frees \($0) by removing downloads kept for servers you\u{2019}ve signed out of.", comment: "%@ is a size such as 1.2 GB") }
            ?? String(localized: "Removes downloads kept for servers you\u{2019}ve signed out of.")
        return String(localized: "\(lead) Signing in to one of them again starts without them. Your listening progress on those servers isn\u{2019}t affected.", comment: "%@ is the preceding sentence about what is freed or removed")
    }

    /// Critique 2026-10-06 (clarify): the outcome shown under the row (and announced)
    /// after removal, which used to give no sign it had happened.
    static func removalOutcome(serverCount: Int, freed: String?) -> String {
        guard serverCount > 0 else { return String(localized: "Nothing to remove \u{2014} those downloads were already gone.") }
        let servers = serverCount == 1 ? String(localized: "1 server") : String(localized: "\(serverCount) servers")
        if let freed {
            return String(localized: "Removed downloads from \(servers), freeing \(freed).", comment: "%1$@ is a count of servers (e.g. 2 servers), %2$@ is a size such as 1.2 GB")
        }
        return String(localized: "Removed downloads from \(servers).", comment: "%@ is a count of servers (e.g. 2 servers)")
    }
}

/// Storage total + remove-all, extracted the same way `DownloadPreferencesSection` is.
///
/// Per-item-size-at-launch fix: this section no longer triggers its own storage walk
/// on appear — see the `.task` on `DownloadsSettingsView`'s root `List` instead, plus
/// `DownloadManager.bootstrapIfNeeded()` for the launch-time walk. This section still
/// only *reads* `totalStorageBytes`/`otherScopesStorageBytes`.
private struct DownloadStorageSection: View {
    @State private var downloadManager = DownloadManager.shared
    @State private var showRemoveAllConfirmation = false
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var showRemoveSignedOutConfirmation = false
    /// Critique 2026-10-06 (clarify): what the last signed-out removal did, shown under
    /// the Storage rows.
    @State private var signedOutRemovalOutcome: String?
    /// Batch 496 (REVIEW 2026-11-11 D4): figures this section measures itself, off the main
    /// thread (nil until measured). The download figures come from `DownloadManager`.
    @State private var transcriptBytes: Int64?
    @State private var coverCacheBytes: Int64?
    @State private var freeBytes: Int64?

    private struct StorageMeasureKey: Hashable {
        let total: Int64
        let coverRevision: Int
    }

    private var savedAccountsBytes: Int64 {
        SignedOutStorage.savedAccountsShare(otherScopes: downloadManager.otherScopesStorageBytes,
                                            signedOut: downloadManager.signedOutScopesStorageBytes)
    }

    private var segments: [DownloadStorageBreakdown.Segment] {
        DownloadStorageBreakdown.segments(thisAccount: downloadManager.totalStorageBytes,
                                          otherAccounts: savedAccountsBytes,
                                          signedOut: downloadManager.signedOutScopesStorageBytes,
                                          transcripts: transcriptBytes, covers: coverCacheBytes, free: freeBytes)
    }

    /// Each segment's colour, from the theme tokens. Never the only cue: every segment has a
    /// labelled row below with the same swatch.
    static func color(for kind: DownloadStorageBreakdown.Kind) -> Color {
        switch kind {
        case .thisAccount: return Color.shelfAmber
        case .otherAccounts: return Color.shelfAmberDark
        case .signedOut: return Color.shelfOrange
        case .transcripts: return Color.shelfCream
        case .covers: return Color.shelfMuted
        case .free: return Color.shelfMuted.opacity(0.3)
        }
    }

    private func swatch(_ kind: DownloadStorageBreakdown.Kind) -> some View {
        RoundedRectangle(cornerRadius: Radius.chip / 2)
            .fill(Self.color(for: kind))
            .frame(width: 12, height: 12)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// One labelled breakdown row: swatch, name, optional caption, size.
    private func breakdownRow(_ kind: DownloadStorageBreakdown.Kind, caption: LocalizedStringKey? = nil,
                              value: String) -> some View {
        HStack {
            swatch(kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(DownloadStorageBreakdown.label(for: kind))
                    .foregroundStyle(Color.shelfCream)
                if let caption {
                    Typo.fine(Text(caption))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            Spacer()
            Typo.figure(Text(value))
                .foregroundStyle(Color.shelfMuted)
        }
        .accessibilityElement(children: .combine)
    }

    /// Transcripts and ebooks, the cover cache and free space, measured off the main thread.
    /// The two cache walks are the same ones Settings already ran (`TranscriptStore`, the
    /// Preferences section's cover-cache figure); free space is one volume query.
    private func measureOtherFigures() async {
        let manager = downloadManager
        let figures = await Task.detached(priority: .utility) {
            (TranscriptStore.totalStorageBytes(),
             DiskCoverCache.totalBytes() + Int64(URLCache.shared.currentDiskUsage),
             manager.volumeAvailableBytes())
        }.value
        guard !Task.isCancelled else { return }   // Batch 497: a newer measurement owns the figures
        transcriptBytes = figures.0
        coverCacheBytes = figures.1
        freeBytes = figures.2
    }

    var body: some View {
        Section {
            // Batch 496 (REVIEW 2026-11-11 D4): one proportional bar, like Settings › General ›
            // iPhone Storage, read by VoiceOver as one summary of every segment.
            DownloadStorageBar(segments: segments, colors: segments.map { Self.color(for: $0.kind) })
                .padding(.vertical, Space.s)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Storage"))
                .accessibilityValue(Text(DownloadStorageBreakdown.accessibilitySummary(segments)))

            HStack {
                swatch(.thisAccount)
                Text(DownloadStorageBreakdown.label(for: .thisAccount))
                    .foregroundStyle(Color.shelfCream)
                Spacer()
                // Critique 2026-10-06 (clarify): "1 books" → `DownloadCountCopy`.
                Typo.figure(Text("\(DownloadCountCopy.books(downloadManager.downloadedItems.count)) \u{00B7} \(downloadManager.formattedStorageUsed)"))
                    .foregroundStyle(Color.shelfMuted)
            }
            .accessibilityElement(children: .combine)
            .settingsRowAnchor(SettingsRow.storage)

            // REVIEW-2026-09-09 fix plan item 5 follow-up: downloads belonging to
            // *other* saved accounts used to be invisible here — the figure above
            // only ever counted the active account's scope, so gigabytes left
            // behind by a removed or dormant account had no row anywhere in the
            // app. `otherScopesStorageBytes` is now measured alongside
            // `totalStorageBytes` (see `DownloadManager.refreshStorageUsed()`);
            // this row only appears when there is something to report. Removing
            // a saved account under Settings › Servers reclaims that account's
            // scope, which is why the caption points there rather than adding a
            // second destructive button to this section.
            if savedAccountsBytes > 0 {
                breakdownRow(.otherAccounts, caption: "Remove a saved server to free its downloads",
                             value: sizeText(savedAccountsBytes))
            }

            // Critique 2026-10-06 (harden): downloads kept for servers the user signed out of (Batch 382
            // keeps them so a sign-in to the same server brings them back). Until now
            // they were counted under "Other accounts" with no way to free them.
            // Batch 496 (D4): the figure is its own labelled row; the button below only acts.
            if downloadManager.signedOutScopesStorageBytes > 0 {
                breakdownRow(.signedOut, caption: "Kept in case you sign in to them again",
                             value: downloadManager.formattedSignedOutScopesStorage)
                Button(role: .destructive) {
                    showRemoveSignedOutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .frame(width: 24)
                        Text("Remove Downloads from Signed-Out Servers")
                    }
                }
            }

            breakdownRow(.transcripts, value: sizeText(transcriptBytes))
            breakdownRow(.covers, caption: "Clear it under Preferences", value: sizeText(coverCacheBytes))
            breakdownRow(.free, value: sizeText(freeBytes))

            if let signedOutRemovalOutcome {
                Typo.supporting(Label {
                    Text(signedOutRemovalOutcome)
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color.shelfMuted)
                })
                .foregroundStyle(Color.shelfMuted)
            }

            if !downloadManager.downloadedItems.isEmpty {
                Button(role: .destructive) {
                    showRemoveAllConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .frame(width: 24)
                        Text("Remove All Downloads")
                    }
                }
            }
        } header: {
            RetroSectionHeader(title: LocalizedStringResource("Storage", comment: "Settings > Downloads section header"))
        } footer: {
            Typo.supporting(Text("Removing downloads only frees space on this device. Books stay in your library."))
                .foregroundStyle(Color.shelfMuted)
        }
        .listRowBackground(Color.shelfCard)
        // Per-item-size-at-launch fix: the walk this section used to trigger itself
        // (`.task { downloadManager.refreshStorageUsed() }`) moved to the root `List` of
        // `DownloadsSettingsView` instead — this section sits at the bottom of that
        // list, so its own `.task` only ran once scrolled into view, which a long
        // downloads list could delay indefinitely.
        // T10 (REVIEW_2026-09-04_UI.md): shared wording/order with DownloadHealthView's
        // "Remove all downloads" action — see `RemoveAllDownloadsCopy`.
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .task(id: downloadManager.otherScopesStorageBytes) {
            downloadManager.measureSignedOutScopes(authViewModel.signedOutServerScopeKeys)
        }
        // Batch 496 (D4): re-measured whenever the downloads total changes (a removal frees space).
        // Batch 497: also after Clear image cache (`coverCacheRevision`). `.task(id:)` cancels the
        // older measurement; `measureOtherFigures` drops a result that was cancelled.
        .task(id: StorageMeasureKey(total: downloadManager.totalStorageBytes,
                                    coverRevision: downloadManager.coverCacheRevision)) {
            await measureOtherFigures()
        }
        .confirmationDialog(SignedOutStorage.removeTitle, isPresented: $showRemoveSignedOutConfirmation, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) {
                // The figure on screen when the user confirmed is what this frees.
                let freed = downloadManager.signedOutScopesStorageBytes > 0
                    ? downloadManager.formattedSignedOutScopesStorage : nil
                Task {
                    let removed = await authViewModel.removeDownloadsFromSignedOutServers()
                    downloadManager.measureSignedOutScopes(authViewModel.signedOutServerScopeKeys)
                    downloadManager.refreshStorageUsed(force: true)
                    let outcome = SignedOutStorage.removalOutcome(serverCount: removed,
                                                                  freed: removed > 0 ? freed : nil)
                    signedOutRemovalOutcome = outcome
                    // The row this came from disappears, so say what happened.
                    AccessibilityNotification.Announcement(outcome).post()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SignedOutStorage.removeMessage(size: downloadManager.signedOutScopesStorageBytes > 0
                ? downloadManager.formattedSignedOutScopesStorage : nil))
        }
        .confirmationDialog(RemoveAllDownloadsCopy.title, isPresented: $showRemoveAllConfirmation, titleVisibility: .visible) {
            Button(RemoveAllDownloadsCopy.confirm, role: .destructive) {
                downloadManager.removeAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RemoveAllDownloadsCopy.message(storageUsed: downloadManager.formattedStorageUsed))
        }
        .systemChromeTint()
    }
}

/// Batch 496 (REVIEW 2026-11-11 D4): the proportional strip at the top of Settings › Downloads ›
/// Storage. Purely visual; the caller gives it one accessibility summary.
private struct DownloadStorageBar: View {
    let segments: [DownloadStorageBreakdown.Segment]
    /// One colour per segment, same order.
    let colors: [Color]

    var body: some View {
        GeometryReader { geo in
            let fractions = DownloadStorageBreakdown.fractions(segments)
            // 1 pt gaps between segments, taken out of the width before it's shared.
            let gaps = CGFloat(max(segments.count - 1, 0))
            let width = max(geo.size.width - gaps, 0)
            HStack(spacing: 1) {
                if segments.isEmpty {
                    Rectangle().fill(Color.shelfMuted.opacity(0.3))
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Rectangle()
                            .fill(index < colors.count ? colors[index] : Color.shelfMuted)
                            .frame(width: width * CGFloat(fractions[index]))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip / 2))
        }
        .frame(height: 14)
    }
}

// MARK: - Polish pass (DL-1, DL-2): row status + progress copy

/// Polish pass (DL-1): what an active download row's status line says. Pure so the choice
/// is pinned by `PolishDownloadsTests`.
enum ActiveDownloadStatus: Equatable {
    case downloading, paused, waitingForWiFi, waitingForNetwork

    static func choose(isPaused: Bool, wifiOnly: Bool, isConnected: Bool, isOnWiFi: Bool,
                       cellularOverridden: Bool = false) -> ActiveDownloadStatus {
        if isPaused { return .paused }
        switch DownloadPolicyStatus.waitReason(isPaused: false, wifiOnly: wifiOnly, isConnected: isConnected, isOnWiFi: isOnWiFi,
                                               cellularOverridden: cellularOverridden) {
        case .wifi: return .waitingForWiFi
        case .network: return .waitingForNetwork
        case nil: return .downloading
        }
    }

    var text: String {
        switch self {
        case .downloading: return String(localized: "Downloading\u{2026}")
        case .paused: return String(localized: "Paused")
        case .waitingForWiFi: return String(localized: "Waiting for Wi\u{2011}Fi", comment: "Download row: Wi-Fi-only is on and the device isn't on Wi-Fi")
        case .waitingForNetwork: return String(localized: "Waiting for network", comment: "Download row: the device is offline")
        }
    }
}

enum DownloadProgressCopy {
    // One formatter for every row and every progress tick (never built inside a view body).
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// "120 MB of 1.4 GB", plus " · about 4 min left" once the smoothed speed is trustworthy.
    /// nil while the total isn't known yet.
    static func detail(written: Int64, expected: Int64, etaSeconds: TimeInterval?) -> String? {
        guard expected > 0, written > 0 else { return nil }
        let done = byteFormatter.string(fromByteCount: min(written, expected))
        let total = byteFormatter.string(fromByteCount: expected)
        let base = String(localized: "\(done) of \(total)", comment: "Download row; first %@ is bytes downloaded, second is the total size, e.g. '120 MB of 1.4 GB'")
        guard let etaSeconds, let eta = etaText(seconds: etaSeconds) else { return base }
        return base + " \u{00B7} " + eta
    }

    /// Coarse on purpose: "less than a minute left", "about 4 min left", "about 1 h 20 min left".
    static func etaText(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 60 { return String(localized: "less than a minute left", comment: "Download row time estimate") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return String(localized: "about \(minutes) min left", comment: "Download row time estimate; %lld is minutes") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0
            ? String(localized: "about \(hours) h left", comment: "Download row time estimate; %lld is hours")
            : String(localized: "about \(hours) h \(rest) min left", comment: "Download row time estimate; first %lld is hours, second minutes")
    }
}

// MARK: - Active Download Row

struct ActiveDownloadRow: View {
    let task: DownloadTask
    let onCancel: () -> Void
    var onPauseResume: () -> Void = {}
    /// Batch 496 (REVIEW 2026-11-11 D2): place among the waiting books, when this one is waiting.
    var queuePosition: Int? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                CoverImageView(itemId: task.id, width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Typo.rowTitle(Text(task.title))
                        .foregroundStyle(Color.shelfCream)
                        .lineLimit(1)

                    // Batch 496 (D2): a waiting book says where it is in line ("Queued · 2nd")
                    // rather than a network state that doesn't apply to it yet.
                    if task.isQueued {
                        Typo.supporting(Text(queuePosition.map { DownloadQueuePlan.queuedLabel(position: $0) }
                                             ?? String(localized: "Queued", comment: "Download row status for a book waiting its turn")))
                            .foregroundStyle(Color.shelfMuted)
                    } else {
                    // Polish pass (DL-1): `NetworkMonitor` isn't observable, so re-read it on
                    // a slow timeline; with Wi-Fi-only on and no Wi-Fi the row says it is
                    // waiting rather than "Downloading… 37%".
                    TimelineView(.periodic(from: .now, by: 3)) { _ in
                        Typo.supporting(Text(ActiveDownloadStatus.choose(
                            isPaused: task.isPaused, wifiOnly: SettingsStore.wifiOnlyDownloads,
                            isConnected: NetworkMonitor.shared.isConnected,
                            isOnWiFi: NetworkMonitor.shared.isOnWiFi,
                            cellularOverridden: task.cellularOverride).text))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    }
                    // Polish pass (DL-2): "120 MB of 1.4 GB · about 4 min left" — sign of life
                    // for a multi-GB book still at a few percent. Published with the progress
                    // number, so it shares its 0.25 s throttle.
                    if let detail = DownloadProgressCopy.detail(written: task.bytesWritten, expected: task.bytesExpected,
                                                                etaSeconds: task.etaSeconds) {
                        Typo.supporting(Text(detail))
                            .foregroundStyle(Color.shelfMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Text("\(Int(task.progress * 100))%")
                    // VD-7 (docs/design-review.md, Round 4): sits in the same row as the
                    // title/status `VStack` beside it — scale with the status line
                    // (`.caption`) rather than staying fixed while its neighbours grow.
                    .scaledFont(13, weight: .bold, design: .monospaced, relativeTo: .caption)
                    .foregroundStyle(Color.shelfAmberText)
                    // HIG audit 2026-09-17 L10: this row isn't `.combine`d, so this
                    // Text and the progress bar below would be two separate VoiceOver
                    // stops speaking the same percentage. The bar below now carries
                    // the single spoken value; hide this visual-only duplicate.
                    .accessibilityHidden(true)

                // Code review fix (26 August 2026): two buttons in the same `List` row
                // with no `.buttonStyle` collapse into one row-wide tap target under
                // SwiftUI's default `List` row button behavior — a tap on either glyph
                // could dispatch both closures. `.buttonStyle(.borderless)` restores
                // each button as its own independent tap target (kept over `.plain`
                // since it preserves the pressed-state tint these glyph buttons get).
                Button(action: onPauseResume) {
                    Image(systemName: task.isPaused ? "arrow.down.circle.fill" : "pause.circle.fill")
                        .downloadControlGlyph()
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(task.isPaused ? Text("Resume download") : Text("Pause download"))

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .downloadControlGlyph()
                        .foregroundStyle(Color.shelfMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
            }

            // Full-width progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.shelfMuted.opacity(0.3))
                        .frame(height: 6)

                    Capsule()
                        .fill(Color.shelfAmber)
                        .frame(width: geo.size.width * task.progress, height: 6)
                        .shelfAnimation(.linear(duration: 0.3), value: task.progress)
                }
            }
            .frame(height: 6)
            // HIG audit 2026-09-17 L10: expose the two-Capsule bar as one
            // accessibility element (not one per Capsule) carrying the progress
            // value, since it updates continuously as the download proceeds.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int(task.progress * 100)) percent")
            .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(14)
        .background(Color.shelfCard)
        // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 12pt radius → `Radius.card`.
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, Space.pageH)
    }
}

// MARK: - Failed Download Row (ARCH-5)

struct FailedDownloadRow: View {
    let failure: DownloadManager.DownloadFailure
    let onRetry: () -> Void
    let onRemove: () -> Void

    // VD-7 (docs/design-review.md, Round 4): this leading glyph sits directly beside
    // the title/message `VStack` in the same row — capped (like `AppLockView`'s AX-5
    // fix) since it lives in a fixed 50x50 slot and shouldn't outgrow it.
    @ScaledMetric(relativeTo: .subheadline) private var failureIconSize: CGFloat = 20
    private var cappedFailureIconSize: CGFloat { min(failureIconSize, 20 * 1.5) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: cappedFailureIconSize))
                .foregroundStyle(Color.shelfOrange)
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Typo.rowTitle(Text(failure.title))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(1)

                Typo.supporting(Text(failure.message))
                    .foregroundStyle(Color.shelfMuted)
                    // VD-5 (docs/design-review.md, Round 6): was `.lineLimit(2)`, which
                    // clipped long server errors with "…" and no way to read the rest —
                    // and the clipped tail is usually the part that explains the failure.
                    // The row grows instead; List rows size to their content.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Code review fix (26 August 2026): same fix as `ActiveDownloadRow` above —
            // without `.buttonStyle`, a tap on either glyph in this `List` row could
            // dispatch both closures, so tapping Retry could also permanently remove
            // the failed download.
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .downloadControlGlyph()
                    .foregroundStyle(Color.shelfAmberText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry download")

            Button(action: onRemove) {
                Image(systemName: "trash.circle.fill")
                    .downloadControlGlyph()
                    .foregroundStyle(Color.shelfMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove failed download")
        }
        .padding(14)
        .background(Color.shelfCard)
        // U10 (REVIEW_2026-08-20_UI_SECURITY.md): raw 12pt radius → `Radius.card`.
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, Space.pageH)
    }
}

/// Critique 2026-10-06 (colorize): the 18pt row-control glyphs scale with Dynamic Type,
/// capped at xxxLarge so they stay inside their fixed 44pt target.
private extension View {
    func downloadControlGlyph() -> some View {
        scaledFont(18, relativeTo: .body)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

#Preview("Settings > Downloads") {
    NavigationStack {
        DownloadsSettingsView()
    }
    .environment(PlayerViewModel())
    // LibraryListRow (SB-5a) reads LibraryViewModel from the environment too.
    .environment(LibraryViewModel())
    // The Storage section reads the signed-out servers' scopes (Critique 2026-10-06).
    .environment(AuthViewModel())
}
