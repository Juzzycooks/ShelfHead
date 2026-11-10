import Foundation
import CarPlay
import CoreMedia
import UIKit
import Observation

// =============================================================================
// ShelfHead • CarPlayCoordinator
// =============================================================================
//
// Owns the CarPlay template graph and translates taps into ShelfHead service
// calls. One instance lives per CarPlay connection.
//
// IMPORTANT: MPNowPlayingInfoCenter + MPRemoteCommandCenter are already fully
// wired in AudioPlayerService (play/pause, skip 15/30, next/prev→chapter, seek,
// artwork). CarPlay's CPNowPlayingTemplate reads from that automatically, so
// this file MUST NOT touch those APIs — it only builds browse templates and
// starts playback through AudioPlayerService.
// =============================================================================

@MainActor
final class CarPlayCoordinator: NSObject {

    private let interfaceController: CPInterfaceController

    // Root tabs. Kept as references so async loads can call `updateSections`.
    private let homeTemplate = CPListTemplate(title: String(localized: "Home"), sections: [])
    private let libraryTemplate = CPListTemplate(title: String(localized: "Library"), sections: [])
    private let downloadsTemplate = CPListTemplate(title: String(localized: "Downloads"), sections: [])
    /// C6 (REVIEW_2026-09-04_UI.md Pass 4): was a local `let` inside `start()` — built
    /// once from `SetupTemplateBuilder.make()` and never referenced again, so nothing
    /// could ever rebuild its rows. Kept as a property, same pattern as the three
    /// templates above, so `reloadSetup()` can call `updateSections` on the SAME
    /// instance that's already installed in the tab bar. `SetupTemplateBuilder.make()`
    /// still owns the initial build (title/tabTitle/tabImage), which this file isn't
    /// touching — `reloadSetup()` (called once from `start()` and again on every
    /// relevant state change) immediately replaces its section content with the live,
    /// honestly-interactive version before the stale one is ever visible.
    private let setupTemplate = SetupTemplateBuilder.make()

    /// WATCH-5 (REVIEW_2026-08-12.md): these were previously just a comment's promise
    /// ("CarPlay also enforces its own maximum") with no actual call to
    /// `CPListTemplate.maximumItemCount` anywhere — `reloadHome()` could build up to 50
    /// items across 5 uncapped sections with nothing stopping it. `Limit.browseList`
    /// now doubles as the value actually pushed into `maximumItemCount` on every list
    /// template this file creates (see `capItemCount(_:)`), so the two can't drift
    /// apart the way the asserted-but-unenforced comment and the real cap already had.
    private enum Limit {
        static let homeSection = 10
        static let browseList = 24
    }

    // Live-sync bookkeeping (see MARK: Live playback sync).
    private var trackedRows: [WeakBookRow] = []
    private var trackedChapterRows: [WeakChapterRow] = []
    private var lastPlaybackSignature = ""
    /// Batch 327: the `CPListTemplateDetailsHeader` on the Chapters list, if one is open
    /// (iOS 26.4+), so `refreshNowPlayingIndicators` can keep its progress indicator,
    /// subtitle and play/pause glyph in step with playback the same way the rows are.
    ///
    /// Typed `AnyObject?` on purpose: a stored property cannot be marked
    /// `@available(iOS 26.4, *)` ("stored properties cannot be marked potentially
    /// unavailable"), and this class has to keep compiling for the iOS 17.6 deployment
    /// target. Every use casts it back inside an availability-gated block. `weak` for the
    /// same reason `WeakBookRow`/`WeakChapterRow` are: CarPlay owns the header through the
    /// template, and once that template is popped this must not be what keeps it alive.
    private weak var chaptersHeaderObject: AnyObject?

    /// WATCH-4 (REVIEW_2026-08-12.md): `CPNowPlayingTemplate.shared` is a process-wide
    /// singleton, and `add(_:)` does not de-duplicate observers — `presentNowPlaying()`
    /// used to call it on every `play(book:)`, so after N plays there were N stacked
    /// observers, and a single Up Next tap fired `nowPlayingTemplateUpNextButtonTapped`
    /// N times, pushing N stacked Chapters templates. This flag makes the add
    /// idempotent; `stop()` removes it so a disconnect doesn't leave a dead
    /// `CarPlayCoordinator` (holding an invalidated `CPInterfaceController`) still
    /// registered against the singleton for the next connection.
    private var isNowPlayingObserverAdded = false
    /// C1 (REVIEW_2026-09-04_UI.md Pass 4): the item id `syncNowPlayingConfiguration()`
    /// last configured `CPNowPlayingTemplate.shared` for. The buttons read
    /// `AudioPlayerService` at tap time and capture nothing per-book, so re-running the
    /// configuration for the SAME book is pointless work that also churns the button row
    /// on screen — the playback observer fires on pause/resume and every chapter
    /// boundary, not just on a book change. `nil` means "not configured in this
    /// connection", which is the correct starting point even when a previous connection
    /// left buttons on the process-wide singleton.
    private var configuredNowPlayingItemId: String?
    /// WATCH-4: guards `playbackDidChange()`'s self-re-arming `startObservingPlayback()`
    /// call — `stop()` sets this so the observation loop actually stops instead of
    /// (per the old comment) relying on the object happening to deallocate soon enough,
    /// which isn't guaranteed to happen promptly relative to a reconnect.
    private var isStopped = false
    /// WATCH-5: cache of the account's libraries — `pushSearch`'s search delegate
    /// re-fetched `/api/libraries` on literally every keystroke before it could even
    /// start searching; this is refreshed on `start()` and account change, not per
    /// keystroke. See `cachedLibraries()`.
    private var librariesCache: [Library]?
    /// Review 6 Medium 9: bumped by `handleAccountChanged`; async loads capture it and drop their result on mismatch.
    private var accountGeneration = 0
    /// Polish pass Phase 2a: the downloaded set Home last reloaded for, so a download's
    /// progress ticks don't refetch Home from the server (CP-4).
    private var homeDownloadedItems: Set<String> = []
    /// Polish pass Phase 2a (CP-2): a book start is in flight; a second tap is ignored.
    private var isStartingPlay = false
    nonisolated static func isStaleGeneration(captured: Int, current: Int) -> Bool { captured != current }

    /// Review 7 Medium 7: a bookmark/chapter row built for one book must not seek another.
    nonisolated static func shouldSeek(builtFor: String?, current: String?) -> Bool { builtFor != nil && builtFor == current }

    /// Review 7 Medium 8: rows per server page, leaving one slot of the cap for "Show more…".
    nonisolated static func filteredPageSize(cap: Int) -> Int { max(cap - 1, 1) }

    /// Review 7 Low (spurious alert): a cancelled/stale load is not a failure worth an alert.
    nonisolated static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
    /// WATCH-5: the in-flight (possibly debounced) search request, so a new keystroke
    /// cancels whatever the previous one was doing — see the search delegate below.
    private var searchTask: Task<Void, Never>?
    /// HIG audit 2026-09-17 M15: `CPNowPlayingImageButton.image` is get-only (the
    /// compiler says so, whatever the DocC section heading implies), so an in-template
    /// bookmark confirmation is done by rebuilding the button row with a filled glyph
    /// via `CPNowPlayingTemplate.updateNowPlayingButtons(_:)` and reverting the same way
    /// — see `applyNowPlayingButtons(bookmarkFilled:)` / `flashBookmarkConfirmation()`.
    /// Cancels a previous flash's revert-after-delay if the driver bookmarks twice in
    /// quick succession, so the glyph doesn't get stuck on "confirmed" or flicker.
    private var bookmarkFlashTask: Task<Void, Never>?
    /// This app is CarPlay-audio-entitled, non-navigation, and never previously
    /// consulted `CPSessionConfiguration` at all — so the Library tab's Search row
    /// (`reloadLibrary()`) pushed a `CPSearchTemplate` unconditionally, even when the
    /// vehicle reports `.keyboard` in `limitedUserInterfaces` (typically while the car
    /// is in motion) and the system refuses to show a keyboard: a dead-end screen the
    /// driver can't type into. Must be *retained* — a released `CPSessionConfiguration`
    /// stops delivering `sessionConfiguration(_:limitedUserInterfacesChanged:)` updates
    /// — so it's owned here exactly like `isNowPlayingObserverAdded` and the other
    /// per-connection state above: created in `start()`, released in `stop()`.
    private var sessionConfiguration: CPSessionConfiguration?
    /// P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): the profile that was active
    /// before `offerOrApplyDrivingProfileIfNeeded()` auto-switched to Driving this
    /// connection — `nil` means no auto-switch happened this connection (declined,
    /// already Driving, or the prompt hasn't been answered yet). `stop()` restores it.
    private var profileBeforeCarPlayAutoDriving: ListeningProfile?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
    }

    #if DEBUG
    /// Item 16 (memory leak): lets a device check confirm this coordinator — and,
    /// transitively, the whole template graph rooted at `homeTemplate`/
    /// `libraryTemplate`/`downloadsTemplate`/`setupTemplate` — actually deallocates on
    /// disconnect (`CarPlaySceneDelegate.didDisconnectInterfaceController` drops its
    /// only strong reference), rather than being kept alive forever by one of the
    /// `template <-> item <-> handler` retain cycles fixed in this batch. `ShelfLog`
    /// is not actor-isolated (a thread-safe `os.Logger` + `NSLock`-protected buffer —
    /// see its own doc comment), so it's safe to call from `deinit`, which is always
    /// `nonisolated` even on an `@MainActor` type like this one.
    deinit {
        ShelfLog.debug(.carplay, "CarPlayCoordinator deallocated")
    }
    #endif

    // MARK: Lifecycle

    func start() {
        isStopped = false
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        configureTabImages()

        let tabs = [
            homeTemplate,
            libraryTemplate,
            downloadsTemplate,
            setupTemplate
        ]
        // HIG audit 2026-09-17 L16a: mirrors the `CPListTemplate.maximumItemCount`/
        // `maximumSectionCount` reads elsewhere in this file (`capItemCount`,
        // `capShelvesToSystemLimit`) — `CPTabBarTemplate.maximumTabCount` is the
        // system's real ceiling on tabs, not something this app sets. Four tabs is
        // static today, so this should never fire; it's a guardrail against a future
        // tab being added without checking the ceiling. Debug-only assert plus a
        // release-mode log, since dropping a tab silently would otherwise be
        // undiagnosable exactly like the item/section caps above.
        assert(tabs.count <= CPTabBarTemplate.maximumTabCount,
               "CarPlay tab bar has \(tabs.count) tabs, over the system's maximumTabCount (\(CPTabBarTemplate.maximumTabCount))")
        if tabs.count > CPTabBarTemplate.maximumTabCount {
            ShelfLog.error(.carplay, "CarPlay tab bar has \(tabs.count) tabs, over the system's maximumTabCount (\(CPTabBarTemplate.maximumTabCount)); CarPlay will drop the overflow itself")
        }
        let tabBar = CPTabBarTemplate(templates: tabs)

        interfaceController.setRootTemplate(tabBar, animated: false) { [weak self] _, error in
            self?.logTemplateResult("setRootTemplate(tabBar)", error: error)
        }

        homeTemplate.emptyViewSubtitleVariants = [String(localized: "Loading your library…")]
        libraryTemplate.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        downloadsTemplate.emptyViewSubtitleVariants = [String(localized: "No downloaded audiobooks yet")]

        // CarPlay can launch without the phone's SwiftUI scene ever running, so the
        // session may not be configured yet. Seed it from the Keychain first, then
        // load — otherwise every server-backed list is empty until the phone app is
        // opened. Downloads are local-only, so they can populate immediately.
        reloadDownloads()
        // C6: Setup has no network dependency at all — every row it shows comes from
        // state already resident in the process (`AuthStore`, `AudioPlayerService`,
        // `DownloadManager`), so it can build its live shape immediately rather than
        // waiting behind `configureFromKeychainIfNeeded()`.
        reloadSetup()
        homeDownloadedItems = DownloadManager.shared.downloadedItems   // CP-4 baseline
        Task {
            await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
            reloadHome()
            reloadLibrary()
        }

        startObservingPlayback()
        startObservingAppState()

        // C1 (REVIEW_2026-09-04_UI.md Pass 4): the single most common flow is "press
        // play at home, walk to the car, plug in" — playback is ALREADY running (in this
        // same process, via `AudioPlayerService`) by the time CarPlay connects, so
        // nothing here would ever have called `play(book:)`, which used to be the only
        // path to `presentNowPlaying()` and therefore to the rate button, the bookmark
        // button, and the Up Next → Chapters observer. Configure from the connect path
        // too; `syncNowPlayingConfiguration()` no-ops when no book is loaded.
        syncNowPlayingConfiguration()

        // P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): purely local state
        // (`ListeningProfileManager`), same reasoning as `reloadSetup()` above — no
        // need to wait on the keychain/network `Task` above.
        offerOrApplyDrivingProfileIfNeeded()
    }

    func stop() {
        // WATCH-4: previously a no-op — MPNowPlayingInfoCenter/MPRemoteCommandCenter
        // genuinely do belong to AudioPlayerService and need no teardown here, but that
        // was true of only HALF of what this file itself owns. `isStopped` breaks the
        // self-re-arming observation loop (`playbackDidChange()`), and removing `self`
        // from `CPNowPlayingTemplate.shared` undoes `presentNowPlaying()`'s `add(self)`
        // — without it, this now-dead coordinator stayed registered against the
        // process-wide singleton across a disconnect/reconnect cycle, and the NEXT
        // connection's fresh coordinator would add itself as a second observer on top.
        isStopped = true
        sessionConfiguration = nil
        if isNowPlayingObserverAdded {
            CPNowPlayingTemplate.shared.remove(self)
            isNowPlayingObserverAdded = false
        }
        // C1: paired with the observer removal above — the next connection gets a fresh
        // coordinator, but clearing this keeps "configured" from outliving the
        // configuration it describes if this instance is ever restarted.
        configuredNowPlayingItemId = nil
        NotificationCenter.default.removeObserver(self, name: .shelfheadAccountChanged, object: nil)
        searchTask?.cancel()
        trackedRows.removeAll()
        trackedChapterRows.removeAll()
        // P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): undoes
        // `offerOrApplyDrivingProfileIfNeeded()`'s auto-switch, restoring whichever
        // profile was active before this connection applied Driving.
        restoreProfileAfterCarPlayIfNeeded()
    }

    private func configureTabImages() {
        homeTemplate.tabTitle = String(localized: "Home")
        homeTemplate.tabImage = UIImage(systemName: "house.fill")
        // PL-14: one-tap Siri row ("Play something"). Selecting it hands off to
        // `ShelfHeadIntents` (an `INPlayMediaIntent` handler); the app gets no callback here.
        // Apple docs: `CPListTemplate.assistantCellConfiguration`, iOS 15.0.
        homeTemplate.assistantCellConfiguration = CPAssistantCellConfiguration(
            position: .top, visibility: .always, assistantAction: .playMedia)

        libraryTemplate.tabTitle = String(localized: "Library")
        libraryTemplate.tabImage = UIImage(systemName: "books.vertical.fill")

        downloadsTemplate.tabTitle = String(localized: "Downloads")
        downloadsTemplate.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        // The Setup tab image is set by SetupTemplateBuilder.
    }

    // MARK: WATCH-5 — system list-size cap + template-result logging

    /// The actual per-list cap this file should build to — `Limit.browseList`/
    /// `.homeSection` are OUR OWN self-imposed limits, but `CPListTemplate
    /// .maximumItemCount` (a `CarPlay`-defined class property, not something this app
    /// sets) is the system's real ceiling and can be lower. Previously only the OWN
    /// limits were applied and `maximumItemCount` was asserted in a comment but never
    /// actually read — this makes the effective cap whichever is smaller.
    private static func capItemCount(_ desired: Int) -> Int {
        min(desired, CPListTemplate.maximumItemCount)
    }

    /// `CPListTemplate.maximumItemCount` is a cap on the TOTAL items in a list template
    /// across every section combined, not per section — `reloadHome()` builds up to 5
    /// independently-capped sections (`Limit.homeSection` each), which could still sum
    /// past the real system limit. Trims deterministically instead of leaving CarPlay to
    /// silently (and unpredictably) drop the overflow itself: earlier sections (higher
    /// up on Home — Continue Listening first) are kept intact; once the running total
    /// hits the limit, later sections are dropped or truncated.
    ///
    /// C9 (REVIEW_2026-09-04_UI.md Pass 4): this was careful about `maximumItemCount`
    /// but never read `CPListTemplate.maximumSectionCount` — a SEPARATE system ceiling.
    /// Small per-section shelves (`Limit.homeSection` = 10 items each) can sum well
    /// under the item budget while still exceeding the section budget, so the
    /// item-only loop used to let CarPlay itself decide which sections survive once the
    /// section count was hit, with no log and no guarantee it would keep the same
    /// earlier-wins order this function exists to enforce. Stops appending once EITHER
    /// ceiling is hit, and logs (mirrors `logTemplateResult`'s pattern — a background
    /// reload, so no `CPAlertTemplate`; see `presentAlert`'s "only for things the
    /// driver just did" rule) when a shelf is actually dropped, so a missing Home shelf
    /// is at least diagnosable instead of silently "whatever CarPlay decided".
    ///
    /// Item 18 (efficiency): this used to run on already-built `CPListSection`s, AFTER
    /// `reloadHome()` had already turned every shelf's entities into `CPListItem`s via
    /// `makeBookRow` — which fires a `CarPlayImageLoader.loadCover` network fetch per
    /// row. A shelf this cap was always going to drop still paid for building every one
    /// of its rows and firing every one of its cover fetches. Reworked to run on the
    /// raw `(header, items)` shelf data BEFORE any row is built, so `reloadHome()` only
    /// ever calls `makeBookRow` for a shelf (and item within it) that will actually be
    /// shown. Generic and `nonisolated` so it's unit-testable with plain arrays —
    /// no live `CPListTemplate`/`CPListItem` needed.
    nonisolated static func capShelvesToSystemLimit<Item>(
        _ shelves: [(header: String, items: [Item])], maxSections: Int, maxItems: Int
    ) -> [(header: String, items: [Item])] {
        var remaining = maxItems
        var result: [(header: String, items: [Item])] = []
        for shelf in shelves {
            guard remaining > 0, result.count < maxSections else { break }
            let items = Array(shelf.items.prefix(remaining))
            guard !items.isEmpty else { break }
            remaining -= items.count
            result.append((shelf.header, items))
        }
        return result
    }

    // MARK: P-10 — Home promotion + alphabetical index rail

    /// P-10 (REVIEW_2026-09-14_DESIGN.md): hoists a shelf literally titled "Continue
    /// Listening" to the front of `shelves`, regardless of which of `reloadHome()`'s
    /// two fetch paths produced it — `getItemsInProgress()` already prepends it when
    /// non-empty, but a server-side "LabelContinueListening" personalized shelf can
    /// land anywhere the server ranked it when that fetch came back empty or failed.
    /// Resuming a book from Home should always be the very first row — one tap —
    /// regardless of which path supplied it. A no-op when no such shelf exists or it's
    /// already first. Pure and `nonisolated` so it's unit-testable without a live
    /// `CPListTemplate`, same shape as `capShelvesToSystemLimit`.
    nonisolated static func promotingContinueListening<Item>(
        _ shelves: [(header: String, items: [Item])]
    ) -> [(header: String, items: [Item])] {
        guard let index = shelves.firstIndex(where: { $0.header == String(localized: "Continue Listening") }), index != 0 else {
            return shelves
        }
        var result = shelves
        let shelf = result.remove(at: index)
        result.insert(shelf, at: 0)
        return result
    }

    /// P-10 (REVIEW_2026-09-14_DESIGN.md): "`Every CPListSection` is built with
    /// `sectionIndexTitle: nil`... Library → Browse → Series → detail → book is four
    /// taps." Buckets `items` by the first character of `titleKey(item)`
    /// (case-insensitively; a leading digit/symbol, or an empty string, collapses into
    /// a trailing "#" bucket, matching Apple Music's own artist/genre index style) so
    /// an alphabetical browse list (Series, Authors, Genres) can render one
    /// `sectionIndexTitle`-per-bucket screen instead of a flat "Show more" page.
    /// Assumes `items` arrives already alphabetically ordered by `titleKey` (the
    /// caller's job — e.g. `getSeries(sort: "name")`'s default, or an explicit
    /// `localizedStandardCompare` sort before calling this): this only groups: it does
    /// not sort within or across buckets. Pure and `nonisolated`, same shape as
    /// `capShelvesToSystemLimit`.
    nonisolated static func alphabeticalBuckets<Item>(
        _ items: [Item], titleKey: (Item) -> String
    ) -> [(header: String, items: [Item])] {
        var buckets: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let key = titleKey(item).trimmingCharacters(in: .whitespacesAndNewlines)
            let letter: String
            if let first = key.first, first.isLetter {
                letter = String(first).uppercased()
            } else {
                letter = "#"
            }
            if buckets[letter] == nil {
                buckets[letter] = []
                order.append(letter)
            }
            buckets[letter]?.append(item)
        }
        let sortedKeys = order.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return sortedKeys.map { (header: $0, items: buckets[$0] ?? []) }
    }

    /// P-10: renders `items` as an alphabetically sectioned, `sectionIndexTitle`-rowed
    /// list — the fix for the browse-depth finding above — instead of
    /// `applyWindowedItems`'s flat "Show more" page. Deliberately does NOT reuse
    /// `Limit.browseList` (that self-imposed 24-item screen cap only existed because a
    /// flat list had no faster way to reach its tail); the real ceiling here is the
    /// system's own `CPListTemplate.maximumItemCount`/`.maximumSectionCount`, via the
    /// same `capShelvesToSystemLimit` `reloadHome()` already uses, so an index-railed
    /// list can show as much as the head unit allows rather than an arbitrary 24. A
    /// bucket dropped by the system cap logs exactly like a dropped Home shelf.
    private func applyIndexedSections<Item>(
        _ items: [Item],
        titleKey: (Item) -> String,
        emptyMessage: String = String(localized: "Nothing here yet"),
        to template: CPListTemplate,
        rowBuilder: (Item) -> CPListItem
    ) {
        let buckets = Self.alphabeticalBuckets(items, titleKey: titleKey)
        let capped = Self.capShelvesToSystemLimit(
            buckets, maxSections: CPListTemplate.maximumSectionCount, maxItems: CPListTemplate.maximumItemCount)
        if capped.count < buckets.count {
            let dropped = buckets[capped.count...].map { $0.header }.joined(separator: ", ")
            ShelfLog.error(.carplay, "CarPlay dropped \(buckets.count - capped.count) indexed section(s) past the system's section/item limit\(dropped.isEmpty ? "" : ": \(dropped)")")
        }
        if items.isEmpty { template.emptyViewSubtitleVariants = [emptyMessage] }
        let sections = capped.map { bucket in
            CPListSection(items: bucket.items.map(rowBuilder), header: bucket.header, sectionIndexTitle: bucket.header)
        }
        template.updateSections(sections)
    }

    // MARK: C2 — windowed browse lists

    /// C2 (REVIEW_2026-09-04_UI.md Pass 4): the windowing decision behind every capped
    /// browse list (Downloads, Series, Authors, Genres, filtered results, and any
    /// pushed book list) — how many of `total` items starting at `offset` fit in one
    /// screen capped at `limit`, and how many are left over. Pure and static so it's
    /// unit-testable without a live `CPListTemplate`/`CPInterfaceController` (this
    /// project's extract-a-pure-function precedent, e.g.
    /// `DownloadManager.shouldReclaimOrphanDirectory`). `nonisolated` so
    /// `CarPlayListWindowingTests` can call it synchronously — same reason
    /// `playbackFailureAlertVariants` (C4) is `nonisolated` — this type itself is
    /// `@MainActor`.
    ///
    /// `limit` should already be the REAL system ceiling (`capItemCount(Limit
    /// .browseList)`), not `Limit.browseList` alone — see `capItemCount`'s doc comment
    /// on why those can differ.
    ///
    /// A trailing "Show more" row costs one of the `limit` slots itself, so whenever
    /// there IS a next page the visible count is `limit - 1`, not `limit` — otherwise a
    /// list of exactly `limit` items would show `limit - 1` real rows plus a "Show
    /// more" row leading to a single leftover item, which is worse than just showing
    /// all `limit` items with nothing left over.
    nonisolated static func listWindow(total: Int, offset: Int, limit: Int) -> (visible: Int, remaining: Int) {
        let left = max(total - offset, 0)
        guard limit > 0 else { return (0, left) }
        guard left > limit else { return (left, 0) }
        let visible = max(limit - 1, 0)
        return (visible, left - visible)
    }

    /// Windows `items` into one on-screen page and applies it to `template`, replacing
    /// the flat `prefix(Self.capItemCount(Limit.browseList))` every browse list here
    /// used to apply with no notice that anything was cut. When `listWindow` says
    /// there's a next page, a trailing "Show more" row re-renders that NEXT window into
    /// the SAME template in place (not a pushed template), so paging through a big
    /// library doesn't grow the interface controller's template stack.
    private func applyWindowedItems<Item>(
        _ items: [Item],
        offset: Int = 0,
        title: String,
        emptyMessage: String = String(localized: "Nothing here yet"),
        to template: CPListTemplate,
        rowBuilder: @escaping (Item) -> CPListItem
    ) {
        let limit = Self.capItemCount(Limit.browseList)
        let window = Self.listWindow(total: items.count, offset: offset, limit: limit)
        var rows = items[offset..<(offset + window.visible)].map(rowBuilder)
        if window.remaining > 0 {
            let moreItem = CPListItem(text: String(localized: "Show more…"), detailText: String(localized: "\(window.remaining) more", comment: "CarPlay list row detail: how many more items are hidden. %lld is the count."))
            moreItem.accessoryType = .disclosureIndicator
            // Item 16 (memory leak): `template` used to be captured STRONGLY here even
            // though this handler is itself stored on an item living inside
            // `template`'s own sections — template -> section -> item -> handler ->
            // template is a self-contained retain cycle that keeps the whole template
            // graph (and, via `rowBuilder`, `self` — see `reloadDownloads`/`pushBooks`)
            // alive forever once a list needs a "Show more" row at all (e.g. more than
            // ~24 downloads). `[weak self, weak template]` breaks it; the guard still
            // calls `completion()` on every path.
            moreItem.handler = { [weak self, weak template] _, completion in
                guard let self, let template else { completion(); return }
                self.applyWindowedItems(items, offset: offset + window.visible, title: title,
                                          emptyMessage: emptyMessage, to: template, rowBuilder: rowBuilder)
                completion()
            }
            rows.append(moreItem)
        }
        if rows.isEmpty { template.emptyViewSubtitleVariants = [emptyMessage] }
        template.updateSections([CPListSection(items: rows)])
    }

    /// WATCH-5: every `pushTemplate`/`setRootTemplate` call in this file used to pass
    /// `completion: nil`, so a rejection (e.g. pushing while already mid-transition, an
    /// invalidated interface controller after disconnect) was silently discarded with
    /// no log and no fallback. Mirrors the `ShelfLog`-based logging pattern used
    /// elsewhere in the codebase (e.g. `WatchSessionManager.updateWatchContext`).
    private func logTemplateResult(_ action: String, error: (any Error)?) {
        guard let error else { return }
        ShelfLog.error(.carplay, "CarPlay \(action) failed: \(error.localizedDescription)")
    }

    // MARK: Home tab

    /// Polish pass Phase 2a (CP-3): whether a Home refresh should leave the current
    /// shelves alone. Any failed fetch counts, because a partial answer would drop shelves.
    nonisolated static func shouldKeepHomeSections(loadFailed: Bool, isAccountSwitch: Bool, hasSections: Bool) -> Bool {
        loadFailed && !isAccountSwitch && hasSections
    }

    /// Home mirrors the mockup's shelves using the Audiobookshelf "personalized
    /// view". Each shelf becomes a `CPListSection`.
    func reloadHome(isAccountSwitch: Bool = false) {
        if isAccountSwitch {
            // Design review 2026-09-23 PL-1: an account switch invalidates every row
            // already on screen — clear them, and their capturing tap handlers, before
            // this reload's own fetch starts, so a tap during the gap can't land on the
            // previous account's book. Scoped to the account-switch path via the
            // parameter default; a routine Home refresh (library switch, a download
            // finishing) should not flash the list to empty.
            homeTemplate.updateSections([])
            homeTemplate.emptyViewSubtitleVariants = [String(localized: "Loading your library…")]
        }
        let generation = accountGeneration   // Review 6 Medium 9
        // Polish pass (CP-5): whether Home already showed shelves before this refresh
        // (an account switch cleared them above). Decides the early publish, the CP-3
        // keep rule and the downloads fallback, so it is captured before anything lands.
        let hadSections = !homeTemplate.sections.isEmpty
        Task {
            // Item 18 (efficiency): gather raw shelf entities first — `capShelvesToSystemLimit`
            // below trims to the system's real section/item ceilings BEFORE any shelf is
            // turned into `CPListItem`s (`makeBookRow` fires a cover-image fetch per row),
            // so a shelf the cap was always going to drop never builds a row or a fetch.
            var shelves: [(header: String, items: [LibraryItem])] = []
            // C5 (REVIEW_2026-09-04_UI.md Pass 4): every server call below is `try?`,
            // so offline (the normal condition in a car) and a genuine server error
            // both fell through to the exact same empty `shelves` as a truly empty
            // library — tracked separately here so the empty state can tell them
            // apart instead of collapsing into one generic "Nothing to show yet".
            var loadFailed = false

            // Polish pass (CP-5): offline on a first load, resume is one tap — show the
            // downloads straight away instead of waiting for fetches that can't answer.
            // A successful fetch below replaces this.
            if !hadSections, !NetworkMonitor.shared.isConnected,
               let downloaded = Self.downloadedHomeShelf(DownloadManager.shared.downloadedLibraryItems(), limit: Limit.homeSection) {
                publishHome([downloaded])
            }

            if AuthStore.shared.isConfigured {
                // Polish pass (CP-5): the two fetches are independent, so they run together.
                async let inProgressFetch = try? AudiobookshelfAPI.shared.getItemsInProgress()
                async let personalizedFetch = self.fetchPersonalizedShelves()

                if let inProgress = await inProgressFetch {
                    if !inProgress.isEmpty {
                        shelves.append((header: String(localized: "Continue Listening"), items: Array(inProgress.prefix(Limit.homeSection))))
                    }
                } else {
                    loadFailed = true
                }
                // Polish pass (CP-5): Continue Listening is the one-tap resume, so it goes up as
                // soon as it answers (first load only; a refresh keeps the shelves already there).
                if !hadSections, !shelves.isEmpty,
                   !Self.isStaleGeneration(captured: generation, current: accountGeneration) {
                    publishHome(shelves)
                }

                if let personalized = await personalizedFetch {
                    for shelf in personalized {
                        guard shelf.isBookShelf,
                              let title = Self.homeShelfTitle(for: shelf.labelStringKey),
                              let entities = shelf.entities, !entities.isEmpty else { continue }
                        if shelf.labelStringKey == "LabelContinueListening", !shelves.isEmpty { continue }
                        shelves.append((header: title, items: Array(entities.prefix(Limit.homeSection))))
                    }
                } else {
                    loadFailed = true
                }
            }

            // Review 6 Medium 9: an account switch during the fetches above makes these shelves the old account's.
            if Self.isStaleGeneration(captured: generation, current: accountGeneration) { return }
            // Polish pass Phase 2a (CP-3): a failed refresh (offline in the car, server
            // down) keeps the shelves already on screen instead of blanking Home. Only an
            // account switch, which cleared them above, or a first load shows the empty state.
            if Self.shouldKeepHomeSections(loadFailed: loadFailed, isAccountSwitch: isAccountSwitch,
                                           hasSections: hadSections) {
                ShelfLog.info(.carplay, "CarPlay Home refresh failed; keeping the shelves on screen")
                return
            }
            // Polish pass (CP-5): a first load that failed (offline, server down) still gets the
            // downloads, in-progress ones first, so the car can resume in one tap.
            if Self.shouldAppendDownloadedShelf(loadFailed: loadFailed, hadSections: hadSections),
               let downloaded = Self.downloadedHomeShelf(DownloadManager.shared.downloadedLibraryItems(), limit: Limit.homeSection) {
                shelves.append(downloaded)
            }
            if shelves.isEmpty {
                // C5: `NetworkMonitor.shared.isConnected`, not `ReachabilityStore` —
                // `ReachabilityStore.startMonitoring()` is only ever called from the
                // phone app's `MainTabView.task` (see its own doc comment), so a
                // CarPlay-only launch (phone app never opened this session) would
                // leave it stuck in whatever state it starts in and never polling.
                // `NetworkMonitor` is a standalone `@unchecked Sendable` singleton with
                // its own live `NWPathMonitor` regardless of which scene started it —
                // the same source C4's `playbackFailureAlertVariants`/
                // `listLoadFailureAlertVariants` already read.
                let variants = Self.homeEmptyStateVariants(
                    isConfigured: AuthStore.shared.isConfigured,
                    isOnline: NetworkMonitor.shared.isConnected,
                    loadFailed: loadFailed)
                homeTemplate.emptyViewTitleVariants = variants.title
                homeTemplate.emptyViewSubtitleVariants = variants.subtitle
            }

            publishHome(shelves)
        }
    }

    /// Polish pass (CP-5): the personalised-view half of Home's fetch, run beside
    /// `getItemsInProgress`. Nil means the libraries or the view couldn't be loaded.
    private func fetchPersonalizedShelves() async -> [PersonalizedView]? {
        guard let libraries = try? await cachedLibraries(),
              let libraryId = Self.currentLibraryId(libraries) else { return nil }
        return try? await AudiobookshelfAPI.shared.getPersonalizedView(libraryId: libraryId)
    }

    /// Polish pass (CP-5): orders, caps and applies Home's shelves. Shared by the early
    /// (Continue Listening / offline downloads) publish and the final one.
    private func publishHome(_ shelves: [(header: String, items: [LibraryItem])]) {
        // P-10 (REVIEW_2026-09-14_DESIGN.md): "Continue Listening" is the whole
        // point of a one-tap Home — `getItemsInProgress()` already prepends it when
        // that fetch succeeds and is non-empty, but when it comes back empty or
        // fails (loadFailed above), a server-side "LabelContinueListening"
        // personalized shelf can still land in `shelves` at whatever position the
        // server ranked it, not necessarily first. Hoist it unconditionally rather
        // than depending on which of the two fetch paths supplied it.
        let orderedShelves = Self.promotingContinueListening(shelves)

        // WATCH-5/Item 18: enforce the system's real total-item AND section caps,
        // not just our own per-section `Limit.homeSection` — see
        // `capShelvesToSystemLimit`'s doc — before building a single row.
        let capped = Self.capShelvesToSystemLimit(
            orderedShelves, maxSections: CPListTemplate.maximumSectionCount, maxItems: CPListTemplate.maximumItemCount)
        if capped.count < orderedShelves.count {
            let dropped = orderedShelves[capped.count...].map { $0.header }.joined(separator: ", ")
            ShelfLog.error(.carplay, "CarPlay dropped \(orderedShelves.count - capped.count) Home section(s) past the system's section/item limit\(dropped.isEmpty ? "" : ": \(dropped)")")
        }
        let sections = capped.map { shelf in
            CPListSection(items: shelf.items.map(makeBookRow), header: shelf.header, sectionIndexTitle: nil)
        }
        homeTemplate.updateSections(sections)
    }

    /// Polish pass (CP-5): the "Downloaded" shelf Home falls back to — in-progress, unfinished
    /// books first (most recently played first, as `orderedDownloadsForCarPlay`), then the rest.
    /// Nil when there is nothing downloaded. Pure and `nonisolated` so it's unit-testable.
    nonisolated static func downloadedHomeShelf(_ items: [LibraryItem], limit: Int) -> (header: String, items: [LibraryItem])? {
        let ordered = orderedDownloadsForCarPlay(items)
        let inProgress = ordered.filter { $0.progressPercent > 0 && !$0.isFinished }
        let rest = ordered.filter { !($0.progressPercent > 0 && !$0.isFinished) }
        let books = Array((inProgress + rest).prefix(max(limit, 0)))
        guard !books.isEmpty else { return nil }
        return (header: String(localized: "Downloaded"), items: books)
    }

    /// Polish pass (CP-5): the downloads fallback applies only to a first load that failed.
    /// A refresh that fails keeps the shelves already on screen (CP-3) instead.
    nonisolated static func shouldAppendDownloadedShelf(loadFailed: Bool, hadSections: Bool) -> Bool {
        loadFailed && !hadSections
    }

    /// C5 (REVIEW_2026-09-04_UI.md Pass 4): Home's empty state used to collapse three
    /// different situations into one of two strings — "Nothing to show yet" fired
    /// whenever `AuthStore.shared.isConfigured` was true, whether the library was
    /// genuinely empty OR every request above had just failed because the car has no
    /// signal. That sentence describes an empty library; the actual, far more common
    /// situation in a car is a full library temporarily out of reach, with downloaded
    /// books sitting one tab over and working perfectly. `emptyViewTitleVariants` was
    /// also never set anywhere in this file (only the subtitle was), so the empty view
    /// rendered with a subtitle and no title above it — set both here.
    ///
    /// `isOnline` and `loadFailed` are treated the same (both point at Downloads):
    /// from the driver's seat, "the app says it's connected but the request still
    /// failed" and "there's no signal" both mean the same thing — go use what's
    /// already downloaded. Only online AND successfully-loaded-but-empty gets the
    /// generic "genuinely empty library" copy.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live `CPListTemplate`,
    /// same shape as `playbackFailureAlertVariants` (C4).
    nonisolated static func homeEmptyStateVariants(
        isConfigured: Bool, isOnline: Bool, loadFailed: Bool
    ) -> (title: [String], subtitle: [String]) {
        guard isConfigured else {
            return ([String(localized: "Sign in")], [String(localized: "Sign in on your phone to get started")])
        }
        guard isOnline, !loadFailed else {
            return ([String(localized: "You're offline")], [String(localized: "Your downloads still work — try the Downloads tab")])
        }
        return ([String(localized: "Nothing here yet")], [String(localized: "Nothing to show yet")])
    }

    /// The library CarPlay should browse: the one selected in the app (shared via
    /// `SettingsStore`), else the first available.
    private static func currentLibraryId(_ libraries: [Library]) -> String? {
        if let id = SettingsStore.selectedLibraryId, libraries.contains(where: { $0.id == id }) {
            return id
        }
        return libraries.first?.id
    }

    private static func homeShelfTitle(for key: String) -> String? {
        switch key {
        case "LabelContinueListening": return String(localized: "Continue Listening")
        case "LabelRecentlyAdded":     return String(localized: "Recently Added")
        case "LabelContinueSeries":    return String(localized: "Continue Series")
        case "LabelDiscover":          return String(localized: "Discover")
        case "LabelListenAgain":       return String(localized: "Listen Again")
        default:                       return nil
        }
    }

    // MARK: Library tab

    /// Whether a Library-tab row whose destination needs typing may be offered as a
    /// live control. `CPSessionConfiguration.limitedUserInterfaces` reports `.keyboard`
    /// when the connected vehicle refuses to show a keyboard (typically while the car is
    /// in motion) — `CPSearchTemplate` needs exactly that, so a `.keyboard` limit turns
    /// such a row into a dead end, not a live control. `.list` (the other possible
    /// member) is deliberately not consulted here — that's the existing
    /// `maximumItemCount`/`maximumSectionCount` capping's job (see
    /// `capShelvesToSystemLimit`), not this row's. Pure and `nonisolated` so it's
    /// unit-testable without a live `CPSessionConfiguration`, same shape as
    /// `homeEmptyStateVariants`.
    ///
    /// Deliberately phrased about the *capability* rather than about Search by name: the
    /// caller decides which rows need a keyboard by declaring it in `rows` below, so
    /// adding a second typing-dependent row (or renaming Search) can't silently detach a
    /// row from the limit that's meant to gate it.
    nonisolated static func shouldOfferKeyboardRows(limitedUserInterfaces: CPLimitableUserInterface) -> Bool {
        !limitedUserInterfaces.contains(.keyboard)
    }

    /// C11 (REVIEW_2026-09-04_UI.md Pass 4): this used to call `updateSections`
    /// twice — once synchronously with the six static browse rows, then again from a
    /// `Task` that prepends a "Library: «name»" switcher section once
    /// `cachedLibraries()` resolved, for multi-library accounts. Rendered
    /// consequence: the tab painted six rows, then a beat later a new row appeared
    /// above them and pushed everything down one position — list content shifting
    /// under a hand already reaching for "Series".
    ///
    /// Fixed by resolving the switcher decision BEFORE the first (and now only)
    /// `updateSections` call, via `applyLibrarySections`, rather than building a
    /// placeholder shape and correcting it later:
    /// - **Warm cache** (`librariesCache` already populated — any reconnect after the
    ///   first, or simply because `reloadHome()`'s own `cachedLibraries()` call
    ///   already landed first) renders the FINAL shape synchronously, with no `Task`
    ///   and no delay at all.
    /// - **Cold cache** (the very first open this connection) waits for the one
    ///   cache-filling request before rendering anything, rather than rendering the
    ///   six rows early and reflowing once the switcher decision is known.
    ///   `libraryTemplate.emptyViewSubtitleVariants = [String(localized: "Loading…")]` (set in
    ///   `start()`) already covers exactly this gap — a single-library account
    ///   already saw this same brief "Loading…" beat before this fix (its `Task`
    ///   just did nothing once the fetch landed); this makes multi-library accounts
    ///   see the same beat instead of a fast six-row paint followed by a reflow.
    func reloadLibrary(isAccountSwitch: Bool = false) {
        if isAccountSwitch {
            // Design review 2026-09-23 PL-1: same reasoning as reloadHome() above —
            // clear the previous account's Library rows before this account-switch
            // reload awaits its fetch, rather than leaving stale rows (and their tap
            // handlers) live and tappable in the gap.
            libraryTemplate.updateSections([])
            libraryTemplate.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        }
        // `needsKeyboard` is the row's own declaration that its destination can't be
        // used without one, which is what the vehicle limit below gates on. It is
        // declared here rather than inferred from the row's title: matching on the
        // display string would silently stop gating the moment the row is renamed or
        // localised, and would not cover a second typing-dependent row added later.
        let rows: [(title: String, symbol: String, needsKeyboard: Bool, action: () -> Void)] = [
            (String(localized: "Search"),     "magnifyingglass",   true,  { [weak self] in self?.pushSearch() }),
            (String(localized: "Series"),     "books.vertical",    false, { [weak self] in self?.pushSeries() }),
            (String(localized: "Authors"),    "person.2",          false, { [weak self] in self?.pushAuthors() }),
            (String(localized: "Genres"),     "theatermasks",      false, { [weak self] in self?.pushGenres() }),
            (String(localized: "Downloaded"), "arrow.down.circle", false, { [weak self] in self?.pushDownloaded() }),
            (String(localized: "Bookmarks"),  "bookmark",          false, { [weak self] in self?.pushBookmarks() })
        ]

        // Per-row honesty, same call as `reloadSetup()`'s status rows: when the
        // vehicle won't show a keyboard, Search stays visible but inert
        // (`isEnabled = false`, no handler, detail text explains why) rather than
        // acting like a live control that dead-ends on a `CPSearchTemplate` the
        // driver can't type into.
        let keyboardAvailable = Self.shouldOfferKeyboardRows(
            limitedUserInterfaces: sessionConfiguration?.limitedUserInterfaces ?? [])

        let browseItems: [CPListItem] = rows.map { title, symbol, needsKeyboard, action in
            let rowDisabled = needsKeyboard && !keyboardAvailable
            let item = CPListItem(text: title,
                                  detailText: rowDisabled ? String(localized: "Unavailable while driving") : nil,
                                  image: UIImage(systemName: symbol))
            guard !rowDisabled else {
                item.isEnabled = false
                return item
            }
            item.accessoryType = .disclosureIndicator
            item.handler = { _, completion in
                action()
                completion()
            }
            return item
        }

        guard AuthStore.shared.isConfigured else {
            applyLibrarySections(libraries: [], browseItems: browseItems)
            return
        }
        if let cached = librariesCache {
            applyLibrarySections(libraries: cached, browseItems: browseItems)
            return
        }
        let generation = accountGeneration   // Review 6 Medium 9
        Task { [weak self] in
            guard let self else { return }
            // Polish pass (CP-6): a failed library fetch used to be swallowed into `[]`, so the
            // tab looked complete with no hint why the library switcher was missing. The browse
            // rows still show (Downloaded works offline); a house-style status row leads them.
            var libraries: [Library] = []
            do {
                libraries = try await self.cachedLibraries()
            } catch {
                ShelfLog.error(.carplay, "CarPlay library list failed to load: \(error.localizedDescription)")
                if Self.isStaleGeneration(captured: generation, current: self.accountGeneration) { return }
                let variants = Self.homeEmptyStateVariants(
                    isConfigured: true, isOnline: NetworkMonitor.shared.isConnected, loadFailed: true)
                let status = CPListItem(text: variants.title.first ?? "", detailText: variants.subtitle.first,
                                        image: UIImage(systemName: "exclamationmark.triangle"))
                status.isEnabled = false
                self.libraryTemplate.updateSections([
                    CPListSection(items: [status]),
                    CPListSection(items: browseItems)
                ])
                return
            }
            if Self.isStaleGeneration(captured: generation, current: self.accountGeneration) { return }
            self.applyLibrarySections(libraries: libraries, browseItems: browseItems)
        }
    }

    /// Builds and applies the Library tab's ONE final section layout — a "Library"
    /// switcher section prepended only for a multi-library account, otherwise just
    /// the static browse rows on their own. Both call sites in `reloadLibrary()`
    /// (the warm-cache synchronous path and the cold-cache `Task`) funnel through
    /// this same shape decision so there's only ever one `updateSections` call.
    /// C11 (REVIEW_2026-09-04_UI.md Pass 4).
    private func applyLibrarySections(libraries: [Library], browseItems: [CPListItem]) {
        guard libraries.count > 1 else {
            libraryTemplate.updateSections([CPListSection(items: browseItems)])
            return
        }
        let currentId = Self.currentLibraryId(libraries)
        let currentName = libraries.first { $0.id == currentId }?.name ?? String(localized: "Library")
        let switchItem = CPListItem(text: String(localized: "Library: \(currentName)", comment: "CarPlay row. %@ is the current library name."), detailText: String(localized: "Tap to switch"),
                                    image: UIImage(systemName: "building.columns"))
        switchItem.accessoryType = .disclosureIndicator
        switchItem.handler = { [weak self] _, completion in
            self?.pushLibraryPicker(libraries)
            completion()
        }
        libraryTemplate.updateSections([
            CPListSection(items: [switchItem], header: String(localized: "Library"), sectionIndexTitle: nil),
            CPListSection(items: browseItems, header: String(localized: "Browse"), sectionIndexTitle: nil)
        ])
    }

    private func pushLibraryPicker(_ libraries: [Library]) {
        let currentId = Self.currentLibraryId(libraries)
        let items = libraries.map { library -> CPListItem in
            let item = CPListItem(text: library.name,
                                  detailText: library.id == currentId ? String(localized: "Current", comment: "CarPlay: marks the currently selected item") : nil)
            item.handler = { [weak self] _, completion in
                SettingsStore.selectedLibraryId = library.id
                self?.reloadHome()
                self?.reloadLibrary()
                self?.interfaceController.popTemplate(animated: true) { _, error in
                    self?.logTemplateResult("popTemplate(libraryPicker)", error: error)
                }
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: String(localized: "Choose Library"), sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }
    }

    // MARK: Setup tab

    /// C6 (REVIEW_2026-09-04_UI.md Pass 4): `SetupTemplateBuilder.make()` used to run
    /// exactly once, in `start()`, and nothing ever rebuilt it — Playback Speed,
    /// Account, and Downloaded were all a snapshot taken at connect, and EVERY row
    /// got `item.handler = { _, completion in completion() }`
    /// (`CarPlayTemplates.swift:36`), so CarPlay rendered all four as selectable,
    /// flashed a selection highlight on tap, and did nothing — four rows that look
    /// like controls and aren't.
    ///
    /// This rebuilds `setupTemplate`'s sections from live state and is called from
    /// `start()` and from every hook that already refreshes the other tabs on
    /// relevant change: `handleAccountChanged` (account/server), `downloadsDidChange`
    /// (download count), and `playbackRateDidChange` (a new, dedicated observer below
    /// — `startObservingPlayback()`'s existing signature dedup is keyed on
    /// item/isPlaying/chapter, deliberately NOT rate, so a rate-only change wouldn't
    /// have re-fired it).
    ///
    /// Per-row honesty, decided per row rather than blanket-disabling everything:
    /// - **Account** and **Server** are pure status — `SetupTemplateBuilder`'s own doc
    ///   comment already establishes there is no in-car sign-in flow, so there is
    ///   nothing a tap could DO here. `isEnabled = false`, no handler: CarPlay renders
    ///   them inert instead of inviting a tap.
    /// - **Downloaded: N audiobooks** is the same kind of pure status — Setup isn't
    ///   where a download is started, resumed, or managed (that's the Downloads tab) —
    ///   so it's `isEnabled = false` too.
    /// - **Playback Speed** is the one row with a real in-car action available:
    ///   `advancePlaybackRate()` (shared with the Now Playing rate button, C7) steps
    ///   the rate and re-renders this row with the value it landed on, so tapping it
    ///   is a genuine control, not a status readout.
    /// - **Listening Profile** (P-14, REVIEW_2026-09-14_DESIGN.md) is the same kind of
    ///   real control as Playback Speed — pushes `pushListeningProfilePicker()`,
    ///   independent of whatever `offerOrApplyDrivingProfileIfNeeded()` decided on
    ///   connect, so a driver who declined the prompt (or wants Sleep/Work instead)
    ///   isn't stuck with that decision.
    private func reloadSetup() {
        let account = AuthStore.shared
        let statusItem: (String, String) -> CPListItem = { title, detail in
            let item = CPListItem(text: title, detailText: detail)
            item.isEnabled = false   // status only — see doc comment above
            return item
        }

        let accountItem = statusItem(String(localized: "Account"), account.isConfigured ? String(localized: "Signed in") : String(localized: "Not signed in"))
        let serverItem = statusItem(String(localized: "Server"), account.serverURL.isEmpty ? "—" : account.serverURL)
        let downloadedItem = statusItem(String(localized: "Downloaded"), String(localized: "\(DownloadManager.shared.downloadedItems.count) audiobooks", comment: "CarPlay Setup row detail. %lld is the number of downloaded audiobooks."))

        let speedItem = CPListItem(text: String(localized: "Playback Speed"),
                                   detailText: Self.formattedPlaybackRate(AudioPlayerService.shared.playbackRate))
        speedItem.accessoryType = .disclosureIndicator
        speedItem.handler = { [weak self] _, completion in
            self?.advancePlaybackRate()
            completion()
        }

        let profileItem = CPListItem(text: String(localized: "Listening Profile"),
                                     detailText: ListeningProfileManager.shared.activeProfile.label)
        profileItem.accessoryType = .disclosureIndicator
        profileItem.handler = { [weak self] _, completion in
            self?.pushListeningProfilePicker()
            completion()
        }

        setupTemplate.updateSections([
            CPListSection(items: [accountItem, serverItem], header: String(localized: "Manage your account on the phone"), sectionIndexTitle: nil),
            CPListSection(items: [speedItem, profileItem, downloadedItem])
        ])
    }

    /// P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): "Off / Driving / Sleep /
    /// Work lives at Settings → Playback & Appearance → scroll... [CarPlay settings]
    /// has Playback Speed and a downloaded toggle... but not the profile." Lets the
    /// driver pick a profile directly from the car. Same shape as
    /// `pushLibraryPicker(_:)` — a pushed `CPListTemplate`, current selection marked
    /// "Current", tap applies and pops back to Setup with the new selection reflected.
    private func pushListeningProfilePicker() {
        let current = ListeningProfileManager.shared.activeProfile
        let items = ListeningProfile.allCases.map { profile -> CPListItem in
            let item = CPListItem(text: profile.label,
                                  detailText: profile == current ? String(localized: "Current", comment: "CarPlay: marks the currently selected item") : profile.subtitle,
                                  image: UIImage(systemName: profile.icon))
            item.handler = { [weak self] _, completion in
                // Restore-semantics fix: explicit `.user` (the default `activate(_:)`
                // would already use) so this deliberate in-car pick is unambiguously
                // recorded as a user change — see `profileToRestoreOnDisconnect`'s doc
                // comment and requirement that a manual switch from this very row
                // counts as one.
                ListeningProfileManager.shared.activate(profile, origin: .user)
                self?.reloadSetup()
                self?.interfaceController.popTemplate(animated: true) { _, error in
                    self?.logTemplateResult("popTemplate(ListeningProfilePicker)", error: error)
                }
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: String(localized: "Listening Profile"), sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }
    }

    /// P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half): on connect, if the Driving
    /// profile isn't already active, either apply it silently (the driver already said
    /// "Always") or — the very first time ever — ask via a `CPAlertTemplate`. Saves
    /// whatever profile WAS active into `profileBeforeCarPlayAutoDriving` so `stop()`
    /// can restore it; see that property's doc comment. Both `activate(.driving, ...)`
    /// calls below pass `origin: .carPlay` — restore-semantics fix — so
    /// `restoreProfileAfterCarPlayIfNeeded()` can tell this silent auto-switch apart
    /// from a deliberate pick made afterwards (see `profileToRestoreOnDisconnect`). A
    /// no-op when Driving is already active or the driver has already declined once
    /// (`CarPlayAutoDrivingPreference.declined` — the prompt is genuinely one-time,
    /// not once-per-connect).
    ///
    /// Follows `presentAlert`'s established rules (its own doc comment): never stacks
    /// over another modal template, and CarPlay does not auto-dismiss on an action tap
    /// — both actions below explicitly call `dismissTemplate`.
    private func offerOrApplyDrivingProfileIfNeeded() {
        let manager = ListeningProfileManager.shared
        guard manager.activeProfile != .driving else { return }

        switch manager.carPlayAutoDrivingPreference {
        case .always:
            profileBeforeCarPlayAutoDriving = manager.activeProfile
            manager.activate(.driving, origin: .carPlay)
            reloadSetup()
        case .declined:
            break
        case .notAsked:
            guard !isStopped, interfaceController.presentedTemplate == nil else { return }
            let alert = CPAlertTemplate(
                titleVariants: [String(localized: "Switch to your Driving listening profile while connected to CarPlay?")],
                actions: [
                    CPAlertAction(title: String(localized: "Always", comment: "CarPlay alert button: always do this"), style: .default) { [weak self] _ in
                        guard let self else { return }
                        ListeningProfileManager.shared.setCarPlayAutoDrivingPreference(.always)
                        self.profileBeforeCarPlayAutoDriving = ListeningProfileManager.shared.activeProfile
                        ListeningProfileManager.shared.activate(.driving, origin: .carPlay)
                        self.reloadSetup()
                        self.interfaceController.dismissTemplate(animated: true) { _, error in
                            self.logTemplateResult("dismissTemplate(DrivingProfileAlert)", error: error)
                        }
                    },
                    CPAlertAction(title: String(localized: "Not Now"), style: .cancel) { [weak self] _ in
                        guard let self else { return }
                        ListeningProfileManager.shared.setCarPlayAutoDrivingPreference(.declined)
                        self.interfaceController.dismissTemplate(animated: true) { _, error in
                            self.logTemplateResult("dismissTemplate(DrivingProfileAlert)", error: error)
                        }
                    }
                ]
            )
            interfaceController.presentTemplate(alert, animated: true) { [weak self] _, error in
                self?.logTemplateResult("presentTemplate(DrivingProfileAlert)", error: error)
            }
        }
    }

    /// Restore-semantics fix (follow-up to P-14, REVIEW_2026-09-14_DESIGN.md — CarPlay
    /// half): the pure decision behind `restoreProfileAfterCarPlayIfNeeded()` — whether
    /// disconnect should restore the pre-connect profile, or leave whatever's active
    /// alone because a deliberate pick (from ANY source — Settings, the player menu,
    /// or this coordinator's own CarPlay Setup "Listening Profile" row) happened after
    /// CarPlay's silent auto-switch.
    ///
    /// Cases:
    /// - `userChangedSinceAutoApply == true` → `nil` (leave the user's choice alone),
    ///   regardless of what `activeNow` happens to be — even a deliberate re-pick of
    ///   `autoApplied` itself (e.g. Driving again) shouldn't be silently reverted a
    ///   moment later just because it matches.
    /// - `userChangedSinceAutoApply == false` and `activeNow == autoApplied` → still
    ///   exactly what CarPlay silently applied and nothing has touched it since, so
    ///   restore `preConnect` — the original (and still correct, in this case)
    ///   behaviour.
    /// - `userChangedSinceAutoApply == false` and `activeNow != autoApplied` →
    ///   defensive: the active profile changed without a recorded `.user`-origin
    ///   `activate(_:origin:)` call. Never observed in this codebase (every call site
    ///   is tracked via `ListeningProfileManager.lastActivationOrigin`), but restoring
    ///   over an unexplained state risks clobbering a real change this function
    ///   doesn't understand — `nil`.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live
    /// `ListeningProfileManager` or CarPlay session — same shape as
    /// `capShelvesToSystemLimit`/`listWindow`/`homeEmptyStateVariants`.
    nonisolated static func profileToRestoreOnDisconnect(
        preConnect: ListeningProfile,
        autoApplied: ListeningProfile,
        activeNow: ListeningProfile,
        userChangedSinceAutoApply: Bool
    ) -> ListeningProfile? {
        guard !userChangedSinceAutoApply else { return nil }
        guard activeNow == autoApplied else { return nil }
        return preConnect
    }

    /// P-14 (REVIEW_2026-09-14_DESIGN.md — CarPlay half), restore-semantics fix: undoes
    /// `offerOrApplyDrivingProfileIfNeeded()`'s auto-switch on disconnect — but ONLY
    /// when nothing has deliberately changed the profile since. `ListeningProfileManager`
    /// tags every `activate(_:origin:)` call `.user` (Settings, the player menu, and
    /// this coordinator's own `pushListeningProfilePicker()` all use the default) or
    /// `.carPlay` (this file's own auto-apply/restore bookkeeping); the last-recorded
    /// origin is `lastActivationOrigin`. If it's still `.carPlay` — i.e. nothing
    /// user-originated has run since the auto-switch — the profile at disconnect is
    /// still exactly what CarPlay itself silently applied, and this restores the
    /// pre-connect profile (including `.off`, which itself restores
    /// `ListeningProfileManager`'s snapshot baseline; see `activate(_:)`'s doc
    /// comment). If the driver (or any other surface) picked something since, that
    /// choice is left alone and only this connection's own bookkeeping
    /// (`profileBeforeCarPlayAutoDriving`) is cleared. See
    /// `profileToRestoreOnDisconnect(preConnect:autoApplied:activeNow:
    /// userChangedSinceAutoApply:)` for the full decision table. A no-op if this
    /// connection never auto-switched at all (declined, already Driving, or not yet
    /// answered).
    ///
    /// **[device check]**: not verified against a real CarPlay connect/disconnect
    /// cycle — no CarPlay hardware/simulator run in this pass. Expected behaviour:
    /// connect → auto Driving → disconnect restores the prior profile; connect → auto
    /// Driving → manual switch to Sleep (Setup row, player menu, or Settings) →
    /// disconnect keeps Sleep.
    private func restoreProfileAfterCarPlayIfNeeded() {
        guard let previous = profileBeforeCarPlayAutoDriving else { return }
        profileBeforeCarPlayAutoDriving = nil
        let manager = ListeningProfileManager.shared
        let restore = Self.profileToRestoreOnDisconnect(
            preConnect: previous,
            autoApplied: .driving,
            activeNow: manager.activeProfile,
            userChangedSinceAutoApply: manager.lastActivationOrigin != .carPlay
        )
        guard let restore else { return }
        manager.activate(restore, origin: .carPlay)
    }

    // MARK: Downloads tab

    /// C2 (REVIEW_2026-09-04_UI.md Pass 4): `DownloadManager.downloadedLibraryItems()`
    /// is title-sorted (`DownloadManager.swift:1126`), so a flat cap here showed
    /// whatever happened to sort first alphabetically — books A through roughly C for a
    /// 60-book library — and NOTHING else, with no way to reach the rest. Downloads is
    /// specifically the offline surface, the one thing guaranteed to work with zero
    /// signal, so the useful ordering for a capped first page is "what would I actually
    /// resume right now": most-recently-updated progress first, title as the tiebreak
    /// so the order stays stable and predictable once nothing distinguishes two books.
    /// `mediaProgress?.lastUpdate` is the only recency signal a downloaded book carries
    /// — `DownloadedBook.asLibraryItem()` synthesizes it from the manifest's own
    /// `lastUpdate` field, and there's no separate "date downloaded" timestamp anywhere
    /// in that model (confirmed by reading `DownloadedBook.swift` directly rather than
    /// assuming). A book that's never been played (`lastUpdate == nil`) sorts after
    /// every book that has been, then by title — so a fresh download doesn't jump the
    /// queue ahead of something actually in progress, but also doesn't get buried by an
    /// arbitrary title comparison. Pure and `nonisolated` so it's unit-testable.
    nonisolated static func orderedDownloadsForCarPlay(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { a, b in
            let aTime = a.mediaProgress?.lastUpdate ?? -1
            let bTime = b.mediaProgress?.lastUpdate ?? -1
            if aTime != bTime { return aTime > bTime }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    func reloadDownloads() {
        let books = Self.orderedDownloadsForCarPlay(DownloadManager.shared.downloadedLibraryItems())
        // Item 16 (memory leak): `rowBuilder: makeBookRow` (a bound instance-method
        // reference) captures `self` STRONGLY. That closure gets stored inside
        // `applyWindowedItems`'s "Show more" handler, which lives on `downloadsTemplate`
        // — a property `self` itself holds — closing the loop: self -> downloadsTemplate
        // -> … -> handler -> rowBuilder -> self. Wrapping it in an explicit `[weak self]`
        // closure breaks that leg of the cycle; the fallback only runs if `self` has
        // already been deallocated by the time this row is (re)built.
        applyWindowedItems(books, title: String(localized: "Downloads"), emptyMessage: String(localized: "No downloaded audiobooks yet"),
                           to: downloadsTemplate, rowBuilder: { [weak self] book in
            self?.makeBookRow(book) ?? CPListItem(text: book.title, detailText: Self.subtitle(for: book))
        })
    }

    // MARK: Library drill-downs

    private func pushSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            // `CPSearchTemplate` (unlike `CPListTemplate`) has no `.title` to log.
            self?.logTemplateResult("pushTemplate(Search)", error: error)
        }
    }

    private func pushSeries() {
        let template = CPListTemplate(title: String(localized: "Series"), sections: [])
        template.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }

        Task {
            // Review 7 Low (spurious alert): a stale-generation CancellationError returns silently.
            let libraries: [Library]
            do { libraries = try await cachedLibraries() } catch {
                if !Self.isCancellation(error) { showListLoadFailure(template) }
                return
            }
            guard let libraryId = Self.currentLibraryId(libraries),
                  let response = try? await AudiobookshelfAPI.shared.getSeries(libraryId: libraryId)
            else { showListLoadFailure(template); return }   // C4

            // P-10 (REVIEW_2026-09-14_DESIGN.md): was a `prefix(24)`-then-"Show more"
            // flat page (C2, REVIEW_2026-09-04_UI.md Pass 4) with no way to jump ahead
            // alphabetically. `getSeries(sort: "name")` (the default this call uses)
            // already returns `response.results` alphabetically, so no extra sort is
            // needed before bucketing — see `applyIndexedSections`'s doc comment.
            applyIndexedSections(response.results, titleKey: { $0.displayName }, to: template) { [weak self] series in
                let item = CPListItem(text: series.displayName, detailText: String(localized: "\(series.bookCount) books", comment: "CarPlay series row detail. %lld is the number of books in the series."))
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.pushBooks(title: series.displayName, books: series.books ?? [])
                    completion()
                }
                return item
            }
        }
    }

    private func pushAuthors() {
        let template = CPListTemplate(title: String(localized: "Authors"), sections: [])
        template.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }

        Task {
            // Review 7 Low (spurious alert): a stale-generation CancellationError returns silently.
            let libraries: [Library]
            do { libraries = try await cachedLibraries() } catch {
                if !Self.isCancellation(error) { showListLoadFailure(template) }
                return
            }
            guard let libraryId = Self.currentLibraryId(libraries),
                  let filterData = try? await AudiobookshelfAPI.shared.getFilterData(libraryId: libraryId),
                  let authors = filterData.authors
            else { showListLoadFailure(template); return }   // C4

            // P-10 (REVIEW_2026-09-14_DESIGN.md): was a `prefix(24)`-then-"Show more"
            // flat page (C2, REVIEW_2026-09-04_UI.md Pass 4) — a 300-author library
            // showed the first 24 with no way to jump ahead. `getFilterData`'s
            // `authors` array isn't documented as pre-sorted, so sort explicitly
            // before bucketing (same `localizedStandardCompare` the file already uses
            // in `orderedDownloadsForCarPlay`) rather than assume server order.
            let sortedAuthors = authors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            applyIndexedSections(sortedAuthors, titleKey: { $0.name }, to: template) { [weak self] author in
                let item = CPListItem(text: author.name, detailText: nil)
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    // Audiobookshelf filters items by `authors.<base64(id)>`.
                    self?.pushFilteredBooks(title: author.name,
                                            libraryId: libraryId,
                                            filter: "authors." + Self.absFilterValue(author.id))
                    completion()
                }
                return item
            }
        }
    }

    private func pushGenres() {
        let template = CPListTemplate(title: String(localized: "Genres"), sections: [])
        template.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }

        Task {
            // Review 7 Low (spurious alert): a stale-generation CancellationError returns silently.
            let libraries: [Library]
            do { libraries = try await cachedLibraries() } catch {
                if !Self.isCancellation(error) { showListLoadFailure(template) }
                return
            }
            guard let libraryId = Self.currentLibraryId(libraries),
                  let filterData = try? await AudiobookshelfAPI.shared.getFilterData(libraryId: libraryId),
                  let genres = filterData.genres
            else { showListLoadFailure(template); return }   // C4

            // P-10 (REVIEW_2026-09-14_DESIGN.md): same flat-page-with-no-jump-ahead
            // issue named for Series/Authors — Genres is the same shape (an
            // alphabetical name list), so it gets the same indexed treatment. Sorted
            // explicitly first, same reasoning as `pushAuthors`.
            let sortedGenres = genres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            applyIndexedSections(sortedGenres, titleKey: { $0 }, to: template) { [weak self] genre in
                let item = CPListItem(text: genre, detailText: nil)
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.pushFilteredBooks(title: genre,
                                            libraryId: libraryId,
                                            filter: "genres." + Self.absFilterValue(genre))
                    completion()
                }
                return item
            }
        }
    }

    private func pushDownloaded() {
        // C2: same recency-first reorder as the Downloads tab (`orderedDownloadsForCarPlay`'s
        // doc comment) — `pushBooks` below applies the actual windowing/paging.
        let books = Self.orderedDownloadsForCarPlay(DownloadManager.shared.downloadedLibraryItems())
        pushBooks(title: String(localized: "Downloaded"), books: books)
    }

    /// Bookmarks in Audiobookshelf are per-item, so we show bookmarks for the
    /// currently-playing book. Selecting one seeks there.
    private func pushBookmarks() {
        // C12 (REVIEW_2026-09-04_UI.md Pass 4): titled plain "Bookmarks" no matter what
        // was playing, so once something WAS playing there was nothing on screen saying
        // whose bookmarks these are (the "nothing playing" case already had its own
        // empty-state copy below). Same title source `AudioPlayerService` itself uses
        // for `MPMediaItemPropertyTitle` (`AudioPlayerService.swift:1359`), so this
        // can't disagree with what the Now Playing screen shows for the same book.
        let bookTitle = AudioPlayerService.shared.currentSession?.libraryItem?.title
        let template = CPListTemplate(title: bookTitle.map { String(localized: "Bookmarks — \($0)", comment: "CarPlay bookmarks screen title. %@ is the book title.") } ?? String(localized: "Bookmarks"), sections: [])
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }

        guard let itemId = AudioPlayerService.shared.currentItemId else {
            template.emptyViewSubtitleVariants = [String(localized: "Play a book to see its bookmarks")]
            template.updateSections([])
            return
        }
        template.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        Task {
            // C4: a failed fetch and a book with no bookmarks used to collapse into the
            // same "No bookmarks in this book" — which is a confident false statement
            // when the request never landed. Separate the two.
            guard let bookmarks = try? await AudiobookshelfAPI.shared.getBookmarks(itemId: itemId) else {
                showListLoadFailure(template)
                return
            }
            guard !bookmarks.isEmpty else {
                template.emptyViewSubtitleVariants = [String(localized: "No bookmarks in this book")]
                template.updateSections([])
                return
            }
            let items = bookmarks.map { bookmark -> CPListItem in
                let item = CPListItem(text: bookmark.title, detailText: Self.timestamp(bookmark.time))
                item.handler = { _, completion in
                    // Review 7 Medium 7: the book may have changed since this list was built.
                    if Self.shouldSeek(builtFor: itemId, current: AudioPlayerService.shared.currentItemId) {
                        AudioPlayerService.shared.seek(to: bookmark.time)
                    }
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    /// Generic push for a concrete list of `LibraryItem`s (series books, downloaded, …).
    ///
    /// C2 (REVIEW_2026-09-04_UI.md Pass 4): was a hard `prefix(24)` with no paging —
    /// see `applyWindowedItems`'s doc comment.
    private func pushBooks(title: String, books: [LibraryItem]) {
        let template = CPListTemplate(title: title, sections: [])
        // Item 16: see `reloadDownloads()`'s comment on this same fix — needed here too,
        // since `template` (though not a stored property) still retains itself forever
        // via its own "Show more" handler once `makeBookRow` is captured strongly.
        applyWindowedItems(books, title: title, to: template, rowBuilder: { [weak self] book in
            self?.makeBookRow(book) ?? CPListItem(text: book.title, detailText: Self.subtitle(for: book))
        })
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }
    }

    /// Push books resolved from a server-side filter (authors/genres).
    private func pushFilteredBooks(title: String, libraryId: String, filter: String) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }
        loadFilteredBooksPage(title: title, libraryId: libraryId, filter: filter, page: 0, into: template)
    }

    /// C2 (REVIEW_2026-09-04_UI.md Pass 4): unlike Series/Authors/Genres/Downloaded
    /// (the whole list is already in memory and `applyWindowedItems` windows it
    /// locally), a filtered book list is paged AT THE SERVER
    /// (`getLibraryItems(limit:page:)`) — so a "Show more" here means fetching the
    /// NEXT server page, not re-slicing an array already on device. `limit` stays the
    /// real system ceiling (`capItemCount(Limit.browseList)`, unchanged from the
    /// WATCH-5 comment this replaces) so the server page size and CarPlay's own item
    /// cap can't drift apart. The server response has no explicit "more pages" flag in
    /// this app's `LibraryItemsResponse` — a full page coming back is the best
    /// available signal that another might exist; the worst case is one dead-end "Show
    /// more" tap on the last page, which itself just renders an empty-then-corrected
    /// list rather than failing.
    /// The "Show more…" tap handler for a server-paged filtered list. Lives in its own
    /// method (not inline in `loadFilteredBooksPage`'s `Task`) so its
    /// `[weak self, weak template]` capture has no enclosing closure — see the Item 16
    /// comment at the call site. Falls out with `completion()` on every path.
    private func showMoreHandler(title: String, libraryId: String, filter: String,
                                 nextPage: Int, template: CPListTemplate) -> (CPSelectableListItem, @escaping () -> Void) -> Void {
        { [weak self, weak template] _, completion in
            // Design review 2026-09-23 PL-3: `completion` used to be called right here,
            // before `loadFilteredBooksPage`'s fetch even started — Apple documents that
            // "CarPlay displays an asynchronous progress indicator until you call the
            // completion closure" (`CPListItem.handler`), so the system spinner was
            // dismissed instantly and the stale row sat there through the real wait.
            // Threaded through to `loadFilteredBooksPage` instead, which now calls it
            // exactly once, after the row is actually updated (or a failure is shown).
            guard let self, let template else { completion(); return }
            self.loadFilteredBooksPage(title: title, libraryId: libraryId, filter: filter, page: nextPage, into: template, completion: completion)
        }
    }

    private func loadFilteredBooksPage(title: String, libraryId: String, filter: String, page: Int, into template: CPListTemplate, completion: (() -> Void)? = nil) {
        // Review 7 Medium 8: fetch one fewer than the cap so "Show more…" still fits.
        let limit = Self.filteredPageSize(cap: Self.capItemCount(Limit.browseList))
        Task {
            // WIRE: getLibraryItems(filter:) expects Audiobookshelf's encoded
            // filter string. If a category comes back empty, verify the encoding
            // in `absFilterValue` against your server version.
            guard let response = try? await AudiobookshelfAPI.shared.getLibraryItems(
                libraryId: libraryId, limit: limit, page: page, filter: filter)
            else {
                showListLoadFailure(template)   // C4
                // PL-3: called on the main actor (this `Task` inherits the enclosing
                // `@MainActor` isolation) exactly once, on this early-exit path too.
                completion?()
                return
            }

            var items = response.results.map(makeBookRow)
            let hasMore = response.results.count >= limit
            if hasMore {
                let moreItem = CPListItem(text: String(localized: "Show more…"), detailText: nil)
                moreItem.accessoryType = .disclosureIndicator
                // Item 16 (memory leak): `template` captured strongly here creates the
                // same template -> item -> handler -> template cycle described on
                // `applyWindowedItems`'s "Show more" handler — this is a server-paged
                // list rather than a locally-windowed one, but the leak shape (and fix)
                // is identical. Built by `showMoreHandler(...)` rather than inline: this
                // `Task` body legitimately holds `self` and `template` strongly for the
                // duration of the load, and Swift 6.4 (#ImplicitStrongCapture) flags a
                // weak inner capture nested inside such a closure.
                moreItem.handler = showMoreHandler(title: title, libraryId: libraryId, filter: filter,
                                                   nextPage: page + 1, template: template)
                items.append(moreItem)
            }
            if items.isEmpty { template.emptyViewSubtitleVariants = [String(localized: "Nothing here yet")] }
            template.updateSections([CPListSection(items: items)])
            // PL-3: the success path's single call, after the real content is in place.
            completion?()
        }
    }

    // MARK: Batch 327 — iOS 26.4 playback configuration

    /// What one CarPlay row (or the Chapters details header) should show for playback:
    /// which glyph the system draws, and where the progress indicator sits inside the
    /// content's duration.
    ///
    /// Batch 327: iOS 26.4 added `CPPlaybackConfiguration`, which supersedes the single
    /// `CPListItem.playbackProgress` fraction with real elapsed/duration values — so a
    /// row can say "4h 12m of 11h 06m" instead of "38% of something". Deciding *what*
    /// those numbers are is kept out here as a plain value for the same reason
    /// `chapterWindow`/`nextPlaybackRate` are: it is the part worth pinning with tests
    /// (`CarPlayPlaybackConfigurationTests`), and otherwise the part only observable on
    /// a real head unit.
    ///
    /// A nested type inside this `@MainActor` class, following
    /// `DownloadManager.RetryRecordAction`'s precedent — a nested type does not inherit
    /// the enclosing type's global actor, so the `nonisolated` builders below can
    /// construct it and the tests can compare it without hopping to the main actor.
    struct PlaybackRowState: Equatable {
        enum Action: Equatable {
            /// Selecting this row (or tapping the header button) starts or resumes.
            case play
            /// This is the loaded book — or the chapter the position is inside — and it
            /// is playing right now, so the glyph is a pause.
            case pause
        }
        let action: Action
        /// Seconds into `duration`. Always finite and inside `0...duration`.
        let elapsed: Double
        /// Total seconds, or `0` when unknown — which is exactly what
        /// `CPPlaybackConfiguration` documents for an unavailable duration (it then
        /// draws no progress indicator rather than a wrong one).
        let duration: Double
    }

    /// The one clamp on this whole path, which is why every state below is built through
    /// it. `CMTime(seconds:preferredTimescale:)` will happily encode NaN, infinity or a
    /// negative value, and CarPlay would then draw a progress indicator from garbage —
    /// or, worse for a book, from a duration that disagrees with the elapsed time sitting
    /// in front of it. A non-finite or non-positive duration collapses to the documented
    /// "unknown" `0` (with `elapsed` `0`, since there is nothing left for it to be a
    /// fraction of), and `elapsed` is clamped into `0...duration`.
    private nonisolated static func playbackRowState(
        _ action: PlaybackRowState.Action, elapsed: Double, duration: Double
    ) -> PlaybackRowState {
        guard duration.isFinite, duration > 0 else {
            return PlaybackRowState(action: action, elapsed: 0, duration: 0)
        }
        let safeElapsed = elapsed.isFinite ? min(max(elapsed, 0), duration) : 0
        return PlaybackRowState(action: action, elapsed: safeElapsed, duration: duration)
    }

    /// Core of `bookPlaybackState(book:…)`, taking the book's server-side progress as
    /// loose values rather than a `LibraryItem`: `refreshNowPlayingIndicators` re-applies
    /// a row's state from `WeakBookRow` (which deliberately holds no `LibraryItem`), and
    /// it must do that through the SAME implementation the row was built with.
    ///
    /// Source of truth, by row:
    /// - the loaded book (`isCurrent`) → the player's live position when the caller has
    ///   one, and a pause glyph while it is playing. This is the only row where the
    ///   server's progress record is the *stale* number.
    /// - every other book → its own server progress, and a play glyph, because that is
    ///   what selecting it would do.
    nonisolated static func bookPlaybackState(
        serverElapsed: Double, serverDuration: Double,
        isCurrent: Bool, isPlaying: Bool,
        playerTime: Double?, playerDuration: Double?
    ) -> PlaybackRowState {
        guard isCurrent else {
            return playbackRowState(.play, elapsed: serverElapsed, duration: serverDuration)
        }
        return playbackRowState(isPlaying ? .pause : .play,
                                elapsed: playerTime ?? serverElapsed,
                                duration: playerDuration ?? serverDuration)
    }

    /// `bookPlaybackState` for a row being built from a real `LibraryItem`.
    nonisolated static func bookPlaybackState(
        book: LibraryItem, currentItemId: String?, isPlaying: Bool,
        playerTime: Double?, playerDuration: Double?
    ) -> PlaybackRowState {
        bookPlaybackState(serverElapsed: book.currentTime, serverDuration: book.duration,
                          isCurrent: currentItemId != nil && book.id == currentItemId,
                          isPlaying: isPlaying,
                          playerTime: playerTime, playerDuration: playerDuration)
    }

    /// Chapter-relative progress: `duration` is the chapter's own length and `elapsed` is
    /// how far into it the whole-book position `now` has reached — the same
    /// chapter-relative framing the phone's scrubber uses when chapter data exists.
    ///
    /// Takes loose `start`/`end` rather than a `Chapter` so `refreshNowPlayingIndicators`
    /// can re-apply from `WeakChapterRow` without fabricating a `Chapter` to do it (and
    /// `Chapter` has a throwing `init(from:)` and no memberwise initializer anyway).
    /// `end <= start` is a shape the model deliberately keeps rather than dropping (see
    /// `Chapter.init(from:)`), so it has to be handled here: it yields duration `0`,
    /// i.e. no progress indicator, which is the same "reads as 0m" outcome the phone
    /// already gives such a chapter.
    nonisolated static func chapterState(
        start: Double, end: Double, now: Double, isPlaying: Bool
    ) -> PlaybackRowState {
        let duration = (start.isFinite && end.isFinite) ? max(end - start, 0) : 0
        // Half-open, matching every other current-chapter test in the app
        // (`PlayerViewModel.chapterIndex(in:at:)`, `renderChapterWindow`'s `isPlaying`).
        let isCurrent = (now >= start && now < end)
        return playbackRowState(isCurrent && isPlaying ? .pause : .play,
                                elapsed: now - start, duration: duration)
    }

    /// `chapterState` for a row being built from a real `Chapter`.
    nonisolated static func chapterPlaybackState(
        chapter: Chapter, now: Double, isPlaying: Bool
    ) -> PlaybackRowState {
        chapterState(start: chapter.start, end: chapter.end, now: now, isPlaying: isPlaying)
    }

    /// The single place that reads `AudioPlayerService` for a book row's state, so
    /// `makeBookRow` (build time), `refreshNowPlayingIndicators` (every state change) and
    /// the Chapters header can't disagree about what the current book should show.
    ///
    /// `playerDuration` is deliberately `nil` until the player actually knows it:
    /// `AudioPlayerService.duration` is `0` between "session started" and "asset ready",
    /// and `0` means "unknown" to `CPPlaybackConfiguration` — so in that window the
    /// book's own server-side duration is the better answer than none.
    private static func livePlaybackState(
        serverElapsed: Double, serverDuration: Double, itemId: String
    ) -> PlaybackRowState {
        let player = AudioPlayerService.shared
        let isCurrent = (player.currentItemId == itemId)
        return bookPlaybackState(
            serverElapsed: serverElapsed, serverDuration: serverDuration,
            isCurrent: isCurrent, isPlaying: player.isPlaying,
            playerTime: isCurrent ? player.currentTime : nil,
            playerDuration: (isCurrent && player.duration > 0) ? player.duration : nil)
    }

    /// `livePlaybackState` for a `LibraryItem` in hand.
    private static func livePlaybackState(for book: LibraryItem) -> PlaybackRowState {
        livePlaybackState(serverElapsed: book.currentTime, serverDuration: book.duration,
                          itemId: book.id)
    }

    /// 600 is the conventional media timescale (it divides 24/25/30 fps evenly). CarPlay
    /// renders whole seconds, so this is far more precision than the UI needs — it is
    /// picked for not surprising anyone who reads it later.
    private static let playbackTimescale: CMTimeScale = 600

    /// Applies a `PlaybackRowState` to anything CarPlay can show playback for: a
    /// `CPListItem` row, or the Chapters `CPListTemplateDetailsHeader` — both conform to
    /// `CPPlayableItem` as of iOS 26.4.
    ///
    /// Already `@MainActor` by way of the enclosing class, which it has to be:
    /// `CPPlaybackConfiguration` is `CARPLAY_TEMPLATE_UI_ACTOR` in the SDK.
    @available(iOS 26.4, *)
    private static func applyPlaybackConfiguration(
        _ state: PlaybackRowState, to item: any CPPlayableItem
    ) {
        item.playbackConfiguration = CPPlaybackConfiguration(
            preferredPresentation: .audio,
            playbackAction: state.action == .pause ? .pause : .play,
            elapsedTime: CMTime(seconds: state.elapsed, preferredTimescale: playbackTimescale),
            duration: CMTime(seconds: state.duration, preferredTimescale: playbackTimescale)
        )
    }

    // MARK: Row building

    /// Builds a standard audiobook row: title, "Author • time left", live
    /// progress bar, now-playing indicator, and async cover art. Tapping starts
    /// playback and pushes Now Playing. Each row is registered for live sync.
    private func makeBookRow(_ book: LibraryItem) -> CPListItem {
        // C10 (REVIEW_2026-09-04_UI.md Pass 4): rows used to build with no image at
        // all, so covers appeared one at a time as each request landed — a list where
        // half the rows have art and half don't reads as broken, not loading, and it
        // changes while the driver is looking at it. `CarPlayImageLoader.placeholder`
        // is set on every row up front; `loadCover` below replaces it once art lands.
        let item = CPListItem(text: book.title, detailText: Self.subtitle(for: book),
                               image: CarPlayImageLoader.placeholder)

        if book.progressPercent > 0 {
            item.playbackProgress = CGFloat(min(max(book.progressPercent, 0), 1))
        }
        item.isPlaying = (AudioPlayerService.shared.currentItemId == book.id)

        // Batch 327: iOS 26.4's real elapsed/duration progress, ALONGSIDE (not instead
        // of) the `playbackProgress` fraction above — that fraction is still the only
        // thing an iOS 17–26.3 head unit can draw, so both are set and the newer OS
        // simply prefers the richer one.
        if #available(iOS 26.4, *) {
            Self.applyPlaybackConfiguration(Self.livePlaybackState(for: book), to: item)
        }

        item.handler = { [weak self] _, completion in
            // Polish pass (CP-2): CarPlay shows a progress indicator on the row until the
            // completion closure is called (https://developer.apple.com/documentation/carplay/cplistitem/handler),
            // so it is called when the start has resolved or failed, not straight away.
            guard let self else { completion(); return }
            self.play(book: book, completion: completion)
        }

        CarPlayImageLoader.loadCover(itemId: book.id) { image in
            item.setImage(image)
        }

        // Batch 327: the tracked row now carries the book's server-side progress, which
        // is all `refreshNowPlayingIndicators` needs to rebuild exactly this state later
        // — two `Double`s rather than a second reference to the `LibraryItem` (and the
        // `Media`/chapters graph hanging off it) in this file's own bookkeeping array.
        trackedRows.append(WeakBookRow(item: item, itemId: book.id,
                                       serverElapsed: book.currentTime,
                                       serverDuration: book.duration))
        return item
    }

    // MARK: Playback + Now Playing

    private func play(book: LibraryItem, completion: @escaping () -> Void = {}) {
        // CP-2: a second tap would otherwise start a second session while the first is
        // still resolving. The extra tap's row spinner clears at once.
        guard !isStartingPlay else { completion(); return }
        isStartingPlay = true
        Task {
            // Polish pass (CP-2): the row spinner stops once the session is resolved, started
            // or refused, whichever path leaves this task. A streamed book can wait up to the
            // request timeout here, which is the time the spinner is for.
            defer {
                isStartingPlay = false
                completion()
            }
            // Polish pass Phase 2a #2: the phone's resolver — a downloaded book waits at most
            // a few seconds for the server, and starts from the furthest valid position
            // (server, download, queued upload, last known server position).
            guard let start = try? await PlayerViewModel.resolveStart(for: book, warmed: nil) else {
                // C4 (REVIEW_2026-09-04_UI.md Pass 4): the row's completion handler has
                // already fired, so a bare `return` would be a tap that does nothing. No
                // server session and no download; the alert copy says which.
                presentAlert(Self.playbackFailureAlertVariants(isOnline: NetworkMonitor.shared.isConnected))
                return
            }
            let session = start.session

            // AudioPlayerService.startPlayback also updates MPNowPlayingInfoCenter
            // and loads artwork, so CPNowPlayingTemplate is populated for free.
            // Review 2 Low (Playback), 30 October 2026: a refused start must not open Now Playing.
            var started = AudioPlayerService.shared.startPlayback(session: session, startTime: start.startTime)
            if !started {
                PlayerViewModel.closeOrphanedSession(session)
                // Review 3 Low (CarPlay fallback): a refused streaming start tries the downloaded copy before alerting.
                if !start.isLocal, let local = DownloadManager.shared.localSession(for: book.id) {
                    started = AudioPlayerService.shared.startPlayback(session: local, startTime: start.startTime)
                }
            }
            guard started else {
                presentAlert(Self.playbackFailureAlertVariants(isOnline: NetworkMonitor.shared.isConnected))
                return
            }
            presentNowPlaying()
        }
    }

    /// C1 (REVIEW_2026-09-04_UI.md Pass 4): everything that makes the Now Playing screen
    /// usable in the car — the rate button, the bookmark button, and the
    /// `CPNowPlayingTemplateObserver` registration that is the ONLY route to the Chapters
    /// list — used to hang off `presentNowPlaying()`, reachable from `play(book:)` alone.
    /// It therefore existed only if the book had been started from the car, in this
    /// connection. `CPNowPlayingTemplate` is a process-wide singleton whose buttons read
    /// `AudioPlayerService` at tap time, so none of this depends on *where* playback
    /// started: run it whenever there is a current book — from `start()` (already
    /// playing at connect) and from `playbackDidChange()` (a book started or changed on
    /// the phone, by Siri, or from a widget mid-drive).
    ///
    /// Idempotent by construction: `updateNowPlayingButtons` replaces the whole array
    /// rather than appending, `isNowPlayingObserverAdded` (WATCH-4) de-duplicates the
    /// observer, and `configuredNowPlayingItemId` skips repeat work for the same book.
    private func syncNowPlayingConfiguration() {
        guard !isStopped else { return }
        guard let itemId = AudioPlayerService.shared.currentItemId else { return }
        guard itemId != configuredNowPlayingItemId else { return }
        configuredNowPlayingItemId = itemId

        configureNowPlayingButtons()
        let nowPlaying = CPNowPlayingTemplate.shared
        // WATCH-4: `add(_:)` on the process-wide `CPNowPlayingTemplate.shared`
        // singleton does NOT de-duplicate observers — this used to run unconditionally
        // on every `play(book:)`, so after N plays there were N copies of `self`
        // registered, and a single Up Next tap fired `nowPlayingTemplateUpNextButtonTapped`
        // N times, pushing N stacked Chapters templates. `isNowPlayingObserverAdded`
        // makes this idempotent per coordinator instance; `stop()` removes it.
        if !isNowPlayingObserverAdded {
            nowPlaying.add(self)
            isNowPlayingObserverAdded = true
        }
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "Chapters")
    }

    /// Batch 327: iOS 27 adds `CPNowPlayingTemplate.allowsMiniPlayer`, which defaults to
    /// `YES` — deliberately left at that default and NOT set here. The mini player is a
    /// system-driven affordance for getting back to Now Playing from a browse list, which
    /// is precisely the navigation this app's users have to do by hand today; there is no
    /// reason for an audiobook client to opt out of it, and setting it explicitly would
    /// only be a same-value write that reads like a decision.
    private func presentNowPlaying() {
        // C1: configuration and presentation are now separate concerns — this only does
        // the push, and the configuration happens wherever a book appears.
        syncNowPlayingConfiguration()
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate !== nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true) { [weak self] _, error in
                self?.logTemplateResult("pushTemplate(NowPlaying)", error: error)
            }
        }
    }

    /// Rate + Bookmark buttons. (Skip/seek/play-pause come from
    /// MPRemoteCommandCenter, already configured in AudioPlayerService.)
    private func configureNowPlayingButtons() {
        applyNowPlayingButtons(bookmarkFilled: false)
    }

    /// Builds the Rate + Bookmark row and hands it to the template. `bookmarkFilled`
    /// picks the bookmark glyph (`bookmark` vs `bookmark.fill`); the handler is the same
    /// either way, so a tap during the confirmation flash still works.
    private func applyNowPlayingButtons(bookmarkFilled: Bool) {
        let rateButton = CPNowPlayingPlaybackRateButton { [weak self] _ in
            self?.advancePlaybackRate()
        }

        let bookmarkButton = CPNowPlayingImageButton(
            image: UIImage(systemName: bookmarkFilled ? "bookmark.fill" : "bookmark") ?? UIImage()
        ) { [weak self] _ in
            guard let itemId = AudioPlayerService.shared.currentItemId else {
                // C4: the button stays on the template after playback stops, so this
                // guard is reachable — and a bookmark tap that silently does nothing is
                // indistinguishable from one that worked.
                self?.presentAlert(Self.noPlaybackAlertVariants)
                return
            }
            let time = AudioPlayerService.shared.currentTime
            let title = AudioPlayerService.shared.currentChapter?.title ?? "Bookmark"
            // The car is one of the two places this app is most likely to have no usable
            // connection (the other being headphones on the move), so a bookmark made here
            // is queued rather than dropped — there is no UI on this template to report a
            // failure to anyway.
            //
            // C8 (REVIEW_2026-09-04_UI.md Pass 4): the write above used to be entirely
            // fire-and-forget — the comment already reasoned carefully about FAILURE
            // (queued, not dropped), but there was no report of SUCCESS either: the
            // glyph was static and stayed static, so the only way to confirm a
            // bookmark landed was Library → Bookmarks, three taps and a mode switch,
            // while driving. Realistic consequence: a driver taps twice, gets two
            // bookmarks seconds apart, both titled with the same chapter name.
            // `create(...)` already awaits its local queue write before returning
            // (`BookmarkSyncService.perform`), so the confirmation below reflects "the
            // bookmark now exists" (synced immediately or queued to sync — either way
            // created) rather than firing optimistically before that write happens.
            //
            // HIG audit 2026-09-17 M15: this used to route success through
            // `presentTransientAlert(["Bookmark added"])`, a modal `CPAlertTemplate`
            // used as a routine confirmation toast — Apple's alert guidance is for
            // things that need attention or a decision, not "that worked"
            // (https://developer.apple.com/documentation/carplay/cpnowplayingtemplate
            // and the `CPAlertTemplate` guidance `presentAlert`'s own doc comment
            // already cites). `flashBookmarkConfirmation()` reflects success in the
            // button's own state instead — a briefly-filled bookmark glyph — which
            // needs nothing modal.
            Task { [weak self] in
                _ = await BookmarkSyncService.shared.create(itemId: itemId, time: time, title: title)
                self?.flashBookmarkConfirmation()
            }
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons([rateButton, bookmarkButton])
    }

    /// HIG audit 2026-09-17 M15: swaps the bookmark button's glyph to a filled
    /// variant for a beat, then reverts it — an in-template confirmation that a
    /// bookmark was created, replacing the `presentTransientAlert` toast this used to
    /// call. `bookmarkFlashTask` cancels any earlier flash still pending so two quick
    /// bookmarks don't leave the glyph stuck filled or fight over the revert.
    private func flashBookmarkConfirmation(duration: TimeInterval = 1.5) {
        guard !isStopped else { return }
        bookmarkFlashTask?.cancel()
        applyNowPlayingButtons(bookmarkFilled: true)
        bookmarkFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.applyNowPlayingButtons(bookmarkFilled: false)
        }
    }

    /// C6/C7 (REVIEW_2026-09-04_UI.md Pass 4): the one action shared by the Now
    /// Playing rate button and Setup's "Playback Speed" row (C6) — both need to
    /// advance the rate AND tell the driver what it landed on.
    private func advancePlaybackRate() {
        let next = Self.nextPlaybackRate(after: AudioPlayerService.shared.playbackRate)
        AudioPlayerService.shared.setPlaybackRate(next)
        // C6: keeps Setup's "Playback Speed" row from going stale again the instant
        // this file itself is the one changing the rate.
        reloadSetup()
        // HIG audit 2026-09-17 M15: this used to end with
        // `presentTransientAlert([Self.formattedPlaybackRate(next)])` on the theory
        // (see the old version of this comment) that `CPNowPlayingPlaybackRateButton`
        // draws a fixed glyph with no numeric readout of its own. Apple's page for the
        // button says otherwise: "CarPlay uses MPRemoteCommandCenter to observe changes
        // to the playback rate and updates the button's appearance accordingly"
        // (https://developer.apple.com/documentation/carplay/cpnowplayingplaybackratebutton).
        // `AudioPlayerService.setPlaybackRate` already pushes the new rate into
        // `MPNowPlayingInfoPropertyPlaybackRate`/`...DefaultPlaybackRate`
        // (`AudioPlayerService.swift:1382-1386`), so the system button already shows
        // where the tap landed on its own — a modal `CPAlertTemplate` on top of that
        // was a redundant success toast (Apple's alert guidance reserves
        // `CPAlertTemplate` for things that need attention or a decision, not routine
        // confirmation). Setup's "Playback Speed" row (`reloadSetup()`, just above)
        // still shows the value too, via the `reloadSetup()` call above.
    }

    /// C7 (REVIEW_2026-09-04_UI.md Pass 4): the fixed `[1.0, 1.25, 1.5, 1.75, 2.0]`
    /// ladder wrapped from 2.5× (a rate this app fully supports —
    /// `PlayerViewModel.setPlaybackRate` clamps to 0.5–3.0, `SettingsStore
    /// .perBookSpeed` remembers per book) straight to 1.0×, dropping a book to less
    /// than half its speed mid-sentence at highway speed, and any rate above 2.0 or
    /// below 1.0 (reachable from the phone's fine −/+0.05 stepper) wrapped the same
    /// way with no relationship to where it started.
    ///
    /// This steps by 0.25 across the app's own supported 0.5–3.0 range and wraps ONLY
    /// at the top, back to 0.5 — the single wrap is now the edge of the actual range
    /// rather than an arbitrary mid-ladder cliff, and it's the case `formattedPlaybackRate`
    /// makes visible via the transient confirmation in `advancePlaybackRate()`.
    /// `current` is walked up to the next 0.25 grid point rather than assumed to
    /// already be on one, since the phone's fine stepper can land it anywhere (e.g.
    /// 1.05×) — the tolerance below keeps float rounding from either re-selecting the
    /// current stop or skipping the next one.
    ///
    /// Pure and `nonisolated` so it's unit-testable without a live `AudioPlayerService`
    /// (this file's `@MainActor`), same shape as `playbackFailureAlertVariants` (C4).
    nonisolated static func nextPlaybackRate(after current: Float) -> Float {
        let minRate: Float = 0.5
        let maxRate: Float = 3.0
        let step: Float = 0.25
        let tolerance: Float = 0.001
        var candidate = minRate
        while candidate <= maxRate + tolerance {
            if candidate > current + tolerance {
                return min(candidate, maxRate)
            }
            candidate += step
        }
        return minRate   // `current` was already at (or past) the top — wrap.
    }

    /// C7: "1×" / "1.5×" / "2.75×" for the transient rate confirmation and Setup's
    /// "Playback Speed" row (C6) — trims the trailing zero(s) `%.2f` always produces
    /// so a whole rate reads "1×" rather than "1.00×", but still shows a fine-stepped
    /// rate like 1.05× exactly rather than rounding it away. Pure and `nonisolated`.
    nonisolated static func formattedPlaybackRate(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    // MARK: C4 — user-facing failure alerts

    /// C4 (REVIEW_2026-09-04_UI.md Pass 4): before this there was no `CPAlertTemplate`
    /// anywhere in `Services/`, so EVERY failure in the car was silent — a `guard let
    /// session else { return }` after a tap, a `template.updateSections([])` after a
    /// failed fetch, and the driver with one bar in a car park has no way to tell
    /// "server unreachable" from "app broken" from "wrong book".
    ///
    /// Rules this helper enforces so the alerts stay driving-safe:
    /// - **Never stacks.** `presentedTemplate` is CarPlay's one modal slot; presenting a
    ///   second alert over a first is at best rejected and at worst buries an alert the
    ///   driver hasn't dismissed. A dropped duplicate is the right trade — the first
    ///   alert is already saying the same thing.
    /// - **One action.** Dismiss and nothing else; a car alert is not a decision point.
    ///   CarPlay does not auto-dismiss, so the action must call `dismissTemplate`.
    /// - **Only for things the driver just did.** Background refreshes (`reloadHome`,
    ///   `reloadDownloads`, the account/download observers) deliberately do NOT call
    ///   this — an alert nobody asked for is worse than a stale list.
    ///
    /// `variants` are longest-first, per CarPlay's convention: the system picks the
    /// longest string the vehicle's display can actually fit.
    private func presentAlert(_ variants: [String]) {
        guard !isStopped else { return }

        let dismiss = CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true) { _, error in
                self?.logTemplateResult("dismissTemplate(alert)", error: error)
            }
        }
        let alert = CPAlertTemplate(titleVariants: variants, actions: [dismiss])
        // Polish pass (CP-8): a failure alert used to be dropped whenever another template was
        // already presented, so the second failure said nothing. The newest alert replaces the
        // one on screen: dismiss, then present, since `presentTemplate` doesn't stack
        // (https://developer.apple.com/documentation/carplay/cpinterfacecontroller/presenttemplate(_:animated:completion:)).
        let present = { [weak self] in
            guard let self, !self.isStopped else { return }
            self.interfaceController.presentTemplate(alert, animated: true) { [weak self] _, error in
                self?.logTemplateResult("presentTemplate(alert)", error: error)
            }
        }
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: false) { [weak self] _, error in
                self?.logTemplateResult("dismissTemplate(replacedAlert)", error: error)
                present()
            }
        } else {
            present()
        }
    }

    // HIG audit 2026-09-17 M15: `presentTransientAlert(_:duration:)` used to live here
    // — a self-dismissing `CPAlertTemplate` used as a success toast for the bookmark
    // button and the Now Playing rate button. Apple's guidance reserves
    // `CPAlertTemplate` for things that need attention or a decision, not routine
    // confirmation (https://developer.apple.com/documentation/carplay/cpnowplayingtemplate).
    // Both call sites were converted to in-template state instead: the bookmark
    // button flashes a filled glyph (`flashBookmarkConfirmation()`, near
    // `configureNowPlayingButtons()`), and the rate button already shows the current
    // rate via `MPRemoteCommandCenter` per
    // https://developer.apple.com/documentation/carplay/cpnowplayingplaybackratebutton
    // (see `advancePlaybackRate()`). With no call sites left, the helper was removed
    // rather than kept as dead code; `presentAlert(_:)` above remains for real
    // failures (C4).

    /// C4: copy for "the tap couldn't start this book". Both paths in `play(book:)` have
    /// failed by the time this is used, so offline necessarily also means "and it isn't
    /// downloaded" — which is the more actionable half to say out loud.
    ///
    /// Pure and non-private so a test can pin it (CLAUDE.md's extract-a-pure-function
    /// precedent, as with `DownloadManager.shouldReclaimOrphanDirectory`): the ordering
    /// contract (longest variant first) is an API requirement that is otherwise only
    /// visible on a vehicle screen this project can't render from CI.
    nonisolated static func playbackFailureAlertVariants(isOnline: Bool) -> [String] {
        isOnline
            ? [String(localized: "Couldn't start this book"), String(localized: "Can't play")]
            : [String(localized: "You're offline and this book isn't downloaded"), String(localized: "Offline — not downloaded"), String(localized: "Offline")]
    }

    /// C4: copy for "a list you asked for couldn't load". Deliberately does not name the
    /// list — the driver knows which screen they're on, and shorter is safer.
    nonisolated static func listLoadFailureAlertVariants(isOnline: Bool) -> [String] {
        isOnline
            ? [String(localized: "Couldn't reach your server"), String(localized: "Server unreachable"), String(localized: "No connection")]
            : [String(localized: "You're offline — try your downloads"), String(localized: "Offline")]
    }

    /// C4: copy for an action that needs a loaded book when there isn't one.
    nonisolated static var noPlaybackAlertVariants: [String] {
        [String(localized: "Start a book first"), String(localized: "Nothing playing")]
    }

    /// C4: the subtitle a list shows once its load has failed. Without this, a failed
    /// drill-down keeps the `"Loading…"` subtitle it was pushed with, forever.
    private static var listLoadFailureSubtitle: String { String(localized: "Couldn't load") }

    /// C4: shared tail for the four server-backed drill-downs — put the list into an
    /// honest empty state AND tell the driver, since the failure happened after the
    /// template was already pushed and there is nothing else on screen to notice.
    private func showListLoadFailure(_ template: CPListTemplate) {
        template.emptyViewSubtitleVariants = [Self.listLoadFailureSubtitle]
        template.updateSections([])
        presentAlert(Self.listLoadFailureAlertVariants(isOnline: NetworkMonitor.shared.isConnected))
    }

    // MARK: Chapters / Queue

    /// C3 (REVIEW_2026-09-04_UI.md Pass 4): the window of chapter INDICES to show
    /// around `currentIndex`, so the current chapter is always somewhere inside it —
    /// the old `prefix(24)` failure mode on a 60-100-chapter book (the norm for this
    /// account's own content, not the edge: its shared payload is 21-hour LitRPG
    /// serials) opened straight on chapters 1-24 with the current chapter, and any
    /// chapter navigation forward from it, absent. Pure and `nonisolated` so
    /// `CarPlayListWindowingTests` can call it directly.
    ///
    /// Biased 4 chapters BEHIND `currentIndex` and the rest ahead — a car's chapter
    /// list is used for "skip ahead a few", so most of the window should be forward of
    /// where playback is now. Reserves one slot per navigation row it turns out to
    /// need (String(localized: "Earlier chapters…") / String(localized: "Later chapters…")), decided from the un-reserved
    /// window first: shrinking the item window to make room for those rows can only
    /// move `startIndex`/`endIndex` further INSIDE `0..<chapterCount`, so a row already
    /// decided unnecessary can't become necessary, and vice versa isn't possible either
    /// — hence the single recheck below rather than a fixed-point loop.
    ///
    /// Returns a plain labeled tuple (matching `listWindow` above) rather than a
    /// dedicated struct, so there's no question of a nested type picking up this
    /// `@MainActor` class's actor isolation — the tuple is unambiguously a plain value.
    nonisolated static func chapterWindow(
        chapterCount: Int, currentIndex: Int?, limit: Int
    ) -> (startIndex: Int, endIndex: Int, hasEarlier: Bool, hasLater: Bool) {
        guard chapterCount > 0, limit > 0 else {
            return (0, 0, false, false)
        }
        guard chapterCount > limit else {
            return (0, chapterCount, false, false)
        }

        let current = min(max(currentIndex ?? 0, 0), chapterCount - 1)
        let behind = 4

        // First pass: does the ideal (un-reserved) window touch either edge?
        let idealStart = max(current - behind, 0)
        let idealEnd = min(idealStart + limit, chapterCount)
        let hasEarlier = idealStart > 0
        let hasLater = idealEnd < chapterCount

        // Second pass: shrink the window by one slot per row it needs, then re-center
        // on `current` within that smaller width — sliding it back into bounds if the
        // shrunk window would otherwise run past `chapterCount` (the near-the-end case).
        let reserved = (hasEarlier ? 1 : 0) + (hasLater ? 1 : 0)
        let width = max(limit - reserved, 1)
        var start = max(current - behind, 0)
        let end = min(start + width, chapterCount)
        if end - start < width { start = max(end - width, 0) }

        return (start, end, start > 0, end < chapterCount)
    }

    /// Item 17: pages the visible chapter window by a FULL PAGE in either direction,
    /// anchored at the edge of the window being paged FROM — used by "Earlier
    /// chapters…"/String(localized: "Later chapters…") — rather than nudging `currentIndex` by one and
    /// letting `chapterWindow`'s "biased 4 behind" centering (meant for the INITIAL
    /// open, to keep the currently-playing chapter on screen) decide the next page.
    /// That reuse was the actual bug: with `chapterWindow`'s `behind = 4` constant,
    /// re-centering on `startIndex - 1` moved the window back by only 5 chapters no
    /// matter how wide the page was, while re-centering on `endIndex` for "Later"
    /// happened to advance by roughly `width - 4` — two different, both-wrong step
    /// sizes instead of one full, equal page each way.
    ///
    /// `forward: true` starts the new page exactly where the old one ended
    /// (`anchorIndex == old window.endIndex`); `forward: false` ends the new page
    /// exactly where the old one started (`anchorIndex == old window.startIndex`) —
    /// contiguous paging, no gap and no overlap. Reserves a slot for whichever of
    /// String(localized: "Earlier chapters…")/String(localized: "Later chapters…") the new page still needs using the same
    /// two-pass shrink `chapterWindow` uses (reserving a slot can pull the far edge
    /// back enough to remove the need for a row on that side, so it's resolved, then
    /// rechecked, rather than assumed up front).
    ///
    /// Pure and `nonisolated` so `CarPlayListWindowingTests` can call it directly,
    /// same shape as `chapterWindow`/`listWindow`.
    nonisolated static func chapterPage(
        chapterCount: Int, anchorIndex: Int, limit: Int, forward: Bool
    ) -> (startIndex: Int, endIndex: Int, hasEarlier: Bool, hasLater: Bool) {
        guard chapterCount > 0, limit > 0 else { return (0, 0, false, false) }
        guard chapterCount > limit else { return (0, chapterCount, false, false) }

        if forward {
            let start = min(max(anchorIndex, 0), chapterCount)
            let hasEarlier = start > 0
            let firstPassWidth = max(limit - (hasEarlier ? 1 : 0), 1)
            let firstPassEnd = min(start + firstPassWidth, chapterCount)
            let hasLater = firstPassEnd < chapterCount
            let width = max(limit - (hasEarlier ? 1 : 0) - (hasLater ? 1 : 0), 1)
            let end = min(start + width, chapterCount)
            return (start, end, hasEarlier, end < chapterCount)
        } else {
            let end = min(max(anchorIndex, 0), chapterCount)
            let hasLater = end < chapterCount
            let firstPassWidth = max(limit - (hasLater ? 1 : 0), 1)
            let firstPassStart = max(end - firstPassWidth, 0)
            let hasEarlier = firstPassStart > 0
            let width = max(limit - (hasLater ? 1 : 0) - (hasEarlier ? 1 : 0), 1)
            let start = max(end - width, 0)
            return (start, end, start > 0, hasLater)
        }
    }

    /// C12 (REVIEW_2026-09-04_UI.md Pass 4): `Chapter.title` decodes to `""` when the
    /// server omits it (`AudiobookshelfModels.swift:367-369`, deliberately tolerant) —
    /// this used to go straight into `CPListItem(text:)`, giving a row with an empty
    /// first line and only a timestamp underneath. Falls back to "Chapter N" (1-based
    /// on `chapter.id`, matching `ChapterListSheet`'s own numbering in
    /// `PlayerView+Sheets.swift`) ONLY when the title is genuinely blank after
    /// trimming — deliberately does NOT use `Chapter.titlesAreSelfNumbered` (the phone
    /// side's signal for whether to print an index column at all), because CarPlay's
    /// chapter list has never printed one (see this review's own "Checked and not a
    /// problem" note on this file) — there's no second numbering scheme here to
    /// collide with, just a hole to fill for the rows that need it.
    nonisolated static func chapterDisplayTitle(_ chapter: Chapter) -> String {
        let trimmed = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Chapter \(chapter.id + 1)", comment: "CarPlay fallback title for an untitled chapter. %lld is the chapter number.") : chapter.title
    }

    /// A `CPListTemplate` of chapters, windowed around the current one.
    /// Selecting a chapter seeks to its start. Rows are registered for live sync.
    fileprivate func pushChapters() {
        let template = CPListTemplate(title: String(localized: "Chapters"), sections: [])
        let chapters = AudioPlayerService.shared.chapters

        if chapters.isEmpty {
            trackedChapterRows.removeAll()
            template.emptyViewSubtitleVariants = [String(localized: "This book has no chapters")]
            template.updateSections([])
        } else {
            let now = AudioPlayerService.shared.currentTime
            let currentIndex = chapters.firstIndex { now >= $0.start && now < $0.end }
            let limit = Self.capItemCount(Limit.browseList)
            let window = Self.chapterWindow(chapterCount: chapters.count, currentIndex: currentIndex, limit: limit)
            renderChapterWindow(chapters: chapters, window: window, limit: limit, now: now, into: template)
        }
        // Batch 327: the iOS 26.4 details header. Attached whether or not the book has
        // chapters — a book with none still gets the cover, title, time-left and a
        // play/pause button above the empty-state line, which is strictly more useful
        // than the bare "This book has no chapters" screen this pushed before.
        if #available(iOS 26.4, *) {
            attachChaptersHeader(to: template)
        }
        interfaceController.pushTemplate(template, animated: true) { [weak self] _, error in
            self?.logTemplateResult("pushTemplate(\(template.title ?? "untitled"))", error: error)
        }
    }

    /// Batch 327: builds and installs the Chapters list's `CPListTemplateDetailsHeader`
    /// (iOS 26.4) for the book that is currently loaded — cover, title, "Author • Xh Ym
    /// left", a play/pause button, and a progress indicator on the thumbnail.
    ///
    /// Assigns `template.listHeader` rather than using the 26.4
    /// `init(title:listHeader:sections:assistantCellConfiguration:)`, so `pushChapters`
    /// keeps using the one plain `CPListTemplate(title:sections:)` initializer on every OS
    /// and the pre-26.4 path is untouched by this batch.
    ///
    /// Skipped entirely when there is no loaded session: the header is *about* a book, and
    /// `pushChapters` is only reachable from the Now Playing template's Up Next button,
    /// so in practice there always is one — this guard is for the case where playback
    /// stopped between the tap and this call.
    @available(iOS 26.4, *)
    private func attachChaptersHeader(to template: CPListTemplate) {
        guard let book = AudioPlayerService.shared.currentSession?.libraryItem else { return }

        // HIG audit 2026-09-17 L16b: was `CarPlayImageLoader.placeholder`, sized off
        // `CPListItem.maximumImageSize` (the ROW image slot) — see
        // `CarPlayImageLoader.headerPlaceholder(carTraitCollection:)` for what was
        // checked (`CPListTemplate`, `CPListImageRowItem`, `CPThumbnailImage`
        // .maximumImageSize(forAspectRatio:)) and the iOS 27/26.4 split. Still an SF
        // Symbol loading state, replaced by the real cover below. **[device check]**
        let header = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: CarPlayImageLoader.headerPlaceholder(
                carTraitCollection: interfaceController.carTraitCollection)),
            title: book.title,
            subtitle: Self.livePlaybackSubtitle(for: book),
            actionButtons: [Self.playPauseActionButton(isPlaying: AudioPlayerService.shared.isPlaying)]
        )
        // A visual call, not a functional one: the header derives an adaptive light/dark
        // background from the cover. Audiobook covers are strongly coloured and this is
        // the look the API is for, but it cannot be judged from source. **[device check]**
        header.wantsAdaptiveBackgroundStyle = true
        // Progress indicator on the thumbnail itself, from the same pure decision the
        // book rows use.
        Self.applyPlaybackConfiguration(Self.livePlaybackState(for: book), to: header)

        template.listHeader = header
        chaptersHeaderObject = header
        loadChaptersHeaderCover(itemId: book.id, into: header)
    }

    /// Requests a header-sized cover (much larger than the 200 px row thumbnails
    /// `CarPlayImageLoader.coverWidth` is tuned for) and swaps it in when it lands.
    ///
    /// On iOS 27, `CPThumbnailImage.maximumImageSize(forAspectRatio:)` reports the size
    /// the system actually wants — asking for exactly that avoids holding an oversized
    /// bitmap in the thumbnail pipeline, which is the reason the SDK added the call.
    /// Earlier OSes have no such API, so 400 px is used: double the row width, which is
    /// the right order of magnitude for a header slot, and the same fallback used if
    /// iOS 27 ever reports a non-positive size.
    ///
    /// `[weak header]` rather than `[weak self]`: this closure needs nothing from the
    /// coordinator, and the header must not be kept alive by an in-flight cover request
    /// after the Chapters template has been popped.
    @available(iOS 26.4, *)
    private func loadChaptersHeaderCover(itemId: String, into header: CPListTemplateDetailsHeader) {
        var width = 400
        if #available(iOS 27.0, *) {
            let recommended = CPThumbnailImage.maximumImageSize(forAspectRatio: 1).width
            if recommended > 0 { width = Int(recommended) }
        }
        CarPlayImageLoader.loadCover(itemId: itemId, width: width) { [weak header] image in
            header?.thumbnail = CPThumbnailImage(image: image)
        }
    }

    /// Batch 327: keeps an open Chapters header in step with playback — progress
    /// indicator, time-left subtitle and the play/pause glyph on its action button.
    /// Called from `refreshNowPlayingIndicators`, so it follows that method's cadence
    /// (state changes, not every tick — see its doc comment).
    ///
    /// The header's properties are documented as live — assigning `subtitle`/
    /// `actionButtons` on the installed instance is the supported way to update it, so
    /// this rebuilds the one button rather than mutating a retained `CPButton` (whose
    /// `image` is read-only anyway).
    @available(iOS 26.4, *)
    private func refreshChaptersHeader() {
        guard let header = chaptersHeaderObject as? CPListTemplateDetailsHeader else { return }
        guard let book = AudioPlayerService.shared.currentSession?.libraryItem else { return }
        header.title = book.title
        header.subtitle = Self.livePlaybackSubtitle(for: book)
        header.actionButtons = [Self.playPauseActionButton(isPlaying: AudioPlayerService.shared.isPlaying)]
        Self.applyPlaybackConfiguration(Self.livePlaybackState(for: book), to: header)
    }

    /// The header's single action button. Captures nothing — it reads
    /// `AudioPlayerService` at tap time, exactly like `configureNowPlayingButtons`'s
    /// buttons do, so there is no `self` and (Item 16) no template to capture and leak.
    private static func playPauseActionButton(isPlaying: Bool) -> CPButton {
        let glyph = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill") ?? UIImage()
        return CPButton(image: glyph) { _ in
            AudioPlayerService.shared.togglePlayPause()
        }
    }

    /// Renders one windowed page of `chapters` — the initial page centered around the
    /// current chapter (`chapterWindow`, called from `pushChapters`) or a subsequent
    /// page reached via String(localized: "Earlier chapters…")/String(localized: "Later chapters…") (`chapterPage`, called
    /// from the handlers below) — into `template`, re-rendering the adjacent window IN
    /// PLACE (same template, no template stacking) when the book has more chapters
    /// than fit at once. C3 (REVIEW_2026-09-04_UI.md Pass 4); paging fixed for item 17.
    private func renderChapterWindow(
        chapters: [Chapter],
        window: (startIndex: Int, endIndex: Int, hasEarlier: Bool, hasLater: Bool),
        limit: Int, now: Double, into template: CPListTemplate
    ) {
        trackedChapterRows.removeAll()
        var rows: [CPListItem] = []
        let builtForItemId = AudioPlayerService.shared.currentItemId   // Review 7 Medium 7

        if window.hasEarlier {
            let earlier = CPListItem(text: String(localized: "Earlier chapters…"), detailText: nil)
            earlier.accessoryType = .disclosureIndicator
            // Item 16 (memory leak): `template` used to be captured strongly, creating
            // a template -> item -> handler -> template cycle exactly like
            // `applyWindowedItems`'s "Show more" row. Item 17: pages back a FULL window
            // via `chapterPage`, anchored at this page's own `startIndex`, instead of
            // re-centering `chapterWindow` on a one-off nudged index (see
            // `chapterPage`'s doc comment for why that was wrong).
            earlier.handler = { [weak self, weak template] _, completion in
                guard let self, let template else { completion(); return }
                let page = Self.chapterPage(chapterCount: chapters.count, anchorIndex: window.startIndex, limit: limit, forward: false)
                self.renderChapterWindow(chapters: chapters, window: page, limit: limit, now: now, into: template)
                completion()
            }
            rows.append(earlier)
        }

        for chapter in chapters[window.startIndex..<window.endIndex] {
            let item = CPListItem(text: Self.chapterDisplayTitle(chapter), detailText: Self.timestamp(chapter.start))
            item.isPlaying = (now >= chapter.start && now < chapter.end)
            // Batch 327: chapter-relative elapsed/duration, so the current chapter's row
            // shows how far into THAT chapter playback is. `playbackProgress` is left
            // alone here — it was never set on chapter rows, and the pre-26.4 look of
            // this list is deliberately unchanged.
            if #available(iOS 26.4, *) {
                Self.applyPlaybackConfiguration(
                    Self.chapterPlaybackState(chapter: chapter, now: now,
                                              isPlaying: AudioPlayerService.shared.isPlaying),
                    to: item)
            }
            item.handler = { _, completion in
                if Self.shouldSeek(builtFor: builtForItemId, current: AudioPlayerService.shared.currentItemId) {   // Review 7 Medium 7
                    AudioPlayerService.shared.seek(to: chapter.start)
                }
                completion()
            }
            trackedChapterRows.append(WeakChapterRow(item: item, start: chapter.start, end: chapter.end))
            rows.append(item)
        }

        if window.hasLater {
            let later = CPListItem(text: String(localized: "Later chapters…"), detailText: nil)
            later.accessoryType = .disclosureIndicator
            // Item 16/17: see the String(localized: "Earlier chapters…") handler above — same leak fix
            // (`weak template`) and same full-page-forward fix via `chapterPage`.
            later.handler = { [weak self, weak template] _, completion in
                guard let self, let template else { completion(); return }
                let page = Self.chapterPage(chapterCount: chapters.count, anchorIndex: window.endIndex, limit: limit, forward: true)
                self.renderChapterWindow(chapters: chapters, window: page, limit: limit, now: now, into: template)
                completion()
            }
            rows.append(later)
        }

        template.updateSections([CPListSection(items: rows)])
    }

    // MARK: Live playback sync

    /// Keeps on-screen CarPlay rows in step with playback that changes elsewhere
    /// (phone, Siri, the Now Playing screen). Observes `AudioPlayerService`
    /// (which is `@Observable`) and re-arms after every change.
    ///
    /// Reading `currentChapter?.id` also transitively observes `currentTime`, so
    /// the loop re-fires as playback advances — but a signature check ensures we
    /// only touch the UI when the book, play state, or chapter actually changes.
    private func startObservingPlayback() {
        withObservationTracking {
            let player = AudioPlayerService.shared
            _ = player.currentItemId
            _ = player.isPlaying
            _ = player.currentChapter?.id
        } onChange: { [weak self] in
            // `[weak self]` on both closures — Swift 6.4's #ImplicitStrongCapture flags a
            // weak inner capture whose outer closure implicitly holds `self` strongly.
            Task { @MainActor [weak self] in self?.playbackDidChange() }
        }
    }

    private func playbackDidChange() {
        // WATCH-4: without this guard, `stop()` setting `isStopped` did nothing to
        // actually halt this self-re-arming loop — `startObservingPlayback()` would
        // just keep re-registering itself against `AudioPlayerService.shared`
        // (an app-wide singleton that outlives any single CarPlay connection) even
        // after this coordinator was supposed to be dead, doing pointless work for a
        // disconnected interface controller until ARC happened to deallocate it.
        guard !isStopped else { return }
        startObservingPlayback()   // re-arm for the next change

        let player = AudioPlayerService.shared
        let signature = "\(player.currentItemId ?? "-")|\(player.isPlaying)|\(player.currentChapter?.id ?? -1)"
        guard signature != lastPlaybackSignature else { return }
        lastPlaybackSignature = signature

        // C1 (REVIEW_2026-09-04_UI.md Pass 4): this observer already fires when
        // `currentItemId` changes — from anywhere, including the phone, Siri, a widget
        // or auto-advance into the next book in a queue — so it is the one path that
        // sees every "there is now a (different) current book" transition without adding
        // a new notification or a second observation. `syncNowPlayingConfiguration()`
        // filters out the pause/resume and chapter-boundary firings itself.
        syncNowPlayingConfiguration()
        refreshNowPlayingIndicators()
    }

    /// Batch 327: this also re-applies every tracked row's `CPPlaybackConfiguration`.
    ///
    /// CADENCE, deliberately unchanged: `startObservingPlayback` re-arms on
    /// `currentItemId`/`isPlaying`/`currentChapter?.id` and `playbackDidChange` drops
    /// anything whose signature matches the last one, so this runs on book changes,
    /// play/pause and chapter boundaries — NOT on every time tick. The elapsed values
    /// pushed into CarPlay are therefore "as of the last state change", not a live
    /// second-by-second readout; a row can read a few minutes behind until the next
    /// chapter boundary. That is the intended trade: firing this per tick would push a
    /// full row update into CarPlay twice a second for every visible list, which is
    /// exactly the churn `lastPlaybackSignature` exists to prevent (see C1/C7). The
    /// numbers are still an enormous improvement on the pre-26.4 `playbackProgress`
    /// fraction, which only ever refreshed when a list was rebuilt.
    private func refreshNowPlayingIndicators() {
        let player = AudioPlayerService.shared
        let currentId = player.currentItemId
        let now = player.currentTime
        let isPlaying = player.isPlaying
        // See `livePlaybackState`: 0 means "not known yet", not "zero-length book".
        let playerDuration: Double? = player.duration > 0 ? player.duration : nil

        // Book rows: highlight the loaded book; drop rows whose template is gone.
        trackedRows.removeAll { $0.item == nil }
        for row in trackedRows {
            let isCurrent = (row.itemId == currentId)
            row.item?.isPlaying = isCurrent
            if #available(iOS 26.4, *) {
                if let item = row.item {
                    // The current row gets the live player position and a play/pause
                    // glyph; every other tracked row keeps the server progress it was
                    // built with, so pausing the current book can't wipe the progress
                    // indicators off the rest of the list.
                    let state = Self.bookPlaybackState(
                        serverElapsed: row.serverElapsed, serverDuration: row.serverDuration,
                        isCurrent: isCurrent, isPlaying: isPlaying,
                        playerTime: isCurrent ? now : nil,
                        playerDuration: isCurrent ? playerDuration : nil)
                    Self.applyPlaybackConfiguration(state, to: item)
                }
            }
        }

        // Chapter rows (if a Chapters list is open): highlight the current chapter.
        trackedChapterRows.removeAll { $0.item == nil }
        for row in trackedChapterRows {
            row.item?.isPlaying = (now >= row.start && now < row.end)
            if #available(iOS 26.4, *) {
                if let item = row.item {
                    Self.applyPlaybackConfiguration(
                        Self.chapterState(start: row.start, end: row.end,
                                          now: now, isPlaying: isPlaying),
                        to: item)
                }
            }
        }

        // Batch 327: and the Chapters details header, if that list is the one on screen.
        if #available(iOS 26.4, *) {
            refreshChaptersHeader()
        }
    }

    // MARK: WATCH-4 — refresh tabs after connect on relevant app-state changes

    /// Previously the tab bar was built once in `start()` and never touched again
    /// except by playback changes (`startObservingPlayback`) and user-driven pushes —
    /// a download finishing never updated the Downloads tab, signing in mid-drive left
    /// Home stuck on "Sign in on your phone," and nothing refreshed if the selected
    /// library or download state changed from the phone side while already connected.
    /// `DownloadManager` is an `@Observable` singleton this file can reach directly
    /// (same `withObservationTracking` idiom `startObservingPlayback` already uses for
    /// `AudioPlayerService`); `AuthViewModel` is NOT a singleton, so account changes are
    /// instead picked up via the existing `.shelfheadAccountChanged` notification
    /// (posted by `AuthViewModel.login`/`loginWithOIDC`/`logout`/`switchAccount` — see
    /// its doc comment, extended this batch to cover all four transitions, not just
    /// `switchAccount`).
    private func startObservingAppState() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAccountChanged),
            name: .shelfheadAccountChanged, object: nil)
        startObservingDownloads()
        startObservingPlaybackRate()   // C6: keeps Setup's speed row live — see its doc comment
    }

    @objc private func handleAccountChanged() {
        Task { @MainActor in
            guard !self.isStopped else { return }
            // The signed-in account may have changed entirely — the cached libraries
            // list belongs to whichever account fetched it, so it must be invalidated
            // rather than reused across a sign-out/sign-in.
            self.accountGeneration += 1   // Review 6 Medium 9
            self.librariesCache = nil
            // Review 6 Low (account switch): drop any pushed Series/Authors/Genres/Bookmarks list of the old account.
            self.interfaceController.popToRootTemplate(animated: false) { _, _ in }
            await AudiobookshelfAPI.shared.configureFromKeychainIfNeeded()
            // PL-1: this is the one call site that represents an actual account
            // switch (see `.shelfheadAccountChanged`'s doc comment) rather than a
            // routine refresh — `reloadDownloads()`/`reloadSetup()` already rebuild
            // synchronously from in-memory state, so they need no equivalent clear.
            self.reloadHome(isAccountSwitch: true)
            self.reloadLibrary(isAccountSwitch: true)
            self.reloadDownloads()
            // C6: Account/Server on Setup were the two rows `handleAccountChanged`
            // used to skip entirely — this was the exact "sign in on the phone
            // mid-drive, Home fills with books, Setup still says 'Not signed in'"
            // case the review called out.
            self.reloadSetup()
        }
    }

    private func startObservingDownloads() {
        withObservationTracking {
            _ = DownloadManager.shared.downloadedItems
            _ = DownloadManager.shared.activeDownloads
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.downloadsDidChange() }   // both weak, as above
        }
    }

    private func downloadsDidChange() {
        guard !isStopped else { return }
        startObservingDownloads()   // re-arm, same pattern as `startObservingPlayback`
        reloadDownloads()
        // A download finishing or being removed can change Home's rows. Polish pass
        // Phase 2a (CP-4): only then — not on every progress tick of an active download,
        // which refetched Home from the server each time.
        let downloaded = DownloadManager.shared.downloadedItems
        if homeDownloadedItems != downloaded {
            homeDownloadedItems = downloaded
            reloadHome()
        }
        // C6: Setup's "Downloaded: N audiobooks" row was the other one this observer
        // never touched — finish a download and the count on Setup was wrong for the
        // rest of the drive.
        reloadSetup()
    }

    /// C6/C7 (REVIEW_2026-09-04_UI.md Pass 4): `playbackRate` is deliberately NOT one
    /// of the properties `startObservingPlayback()` tracks — that loop's signature
    /// dedup is keyed on item/isPlaying/chapter so it doesn't do unrelated
    /// now-playing-indicator work on every rate tick, and folding rate in would either
    /// break that dedup or require threading a second signature through it. A rate
    /// change (from this file's own `advancePlaybackRate()`, or from the phone's
    /// fine −/+ stepper while already connected — same process, same
    /// `AudioPlayerService.shared`) only needs to refresh one thing: Setup's stale
    /// "Playback Speed" row (C6).
    private func startObservingPlaybackRate() {
        withObservationTracking {
            _ = AudioPlayerService.shared.playbackRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.playbackRateDidChange() }   // both weak, as above
        }
    }

    private func playbackRateDidChange() {
        guard !isStopped else { return }
        startObservingPlaybackRate()   // re-arm, same pattern as `startObservingPlayback`
        reloadSetup()
    }

    /// WATCH-5 (REVIEW_2026-08-12.md): `/api/libraries` was previously re-fetched on
    /// every call site that needed it — `reloadHome`, `reloadLibrary`, `pushSeries`,
    /// `pushAuthors`, `pushGenres`, and (worst) once per keystroke in the search
    /// delegate. The account's library list changes rarely; caching it here (cleared on
    /// account change via `handleAccountChanged`) turns "two network calls per
    /// keystroke while typing a search" into zero once the first fetch lands.
    private func cachedLibraries() async throws -> [Library] {
        if let librariesCache { return librariesCache }
        let generation = accountGeneration   // Review 6 Medium 9: don't write the old account's list back
        let libraries = try await AudiobookshelfAPI.shared.getLibraries()
        if Self.isStaleGeneration(captured: generation, current: accountGeneration) { throw CancellationError() }
        librariesCache = libraries
        return libraries
    }

    // MARK: Formatting helpers

    /// Batch 327: `subtitle(for:)`'s exact shape ("Author • Xh Ym left"), but computed
    /// from the PLAYER's position when this is the loaded book, for the Chapters details
    /// header — which is only ever shown for the loaded book, and sits directly under a
    /// live progress indicator, so a subtitle built from the server's last-synced
    /// progress record would visibly disagree with the bar above it.
    ///
    /// Not folded into `subtitle(for:)`: that one builds rows for arbitrary books in a
    /// browse list, where the server record IS the right source, and it must stay pure of
    /// the current-playback reads this does.
    private static func livePlaybackSubtitle(for book: LibraryItem) -> String {
        let state = livePlaybackState(for: book)
        let remaining = max(state.duration - state.elapsed, 0)
        guard state.duration > 0, remaining > 0 else { return book.authorName }
        return String(localized: "\(book.authorName) • \(shortDuration(remaining)) left", comment: "CarPlay book subtitle. First %@ is the author, second %@ is the remaining time such as 10h 34m.")
    }

    private static func subtitle(for book: LibraryItem) -> String {
        let author = book.authorName
        let remaining = max(book.duration - book.currentTime, 0)
        if book.progressPercent > 0, remaining > 0 {
            return String(localized: "\(author) • \(shortDuration(remaining)) left", comment: "CarPlay book subtitle. First %@ is the author, second %@ is the remaining time such as 10h 34m.")
        }
        return author
    }

    /// Polish pass (CR-1): `Int(_:)` traps on NaN and infinity, so a bad duration from a server
    /// would crash the car UI. Non-finite or negative values read as 0, huge ones clamp.
    nonisolated static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 31_536_000_000))
    }

    /// "10h 34m" / "34m" — compact for driving.
    private static func shortDuration(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h)h \(m)m", comment: "Compact duration: hours and minutes") : String(localized: "\(m)m", comment: "Compact duration: minutes only")
    }

    /// "9:32:36" / "4:05" — absolute position for chapters/bookmarks.
    private static func timestamp(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Audiobookshelf encodes author/genre filter values as base64 of the raw
    /// id/name. Adjust here if your server expects a different scheme.
    private static func absFilterValue(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
    }
}

// MARK: - CPNowPlayingTemplateObserver  (Chapters via the Up Next button)

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        pushChapters()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Not used — album/artist button is disabled.
    }
}

// MARK: - CPSearchTemplateDelegate  (Library search from the car)

extension CarPlayCoordinator: CPSearchTemplateDelegate {
    /// WATCH-5 (REVIEW_2026-08-12.md): previously fired a brand-new, un-cancelled
    /// `Task` on every single keystroke — two network calls each (`/api/libraries`,
    /// uncached at the time, plus `/api/libraries/{id}/search`), with no debounce and
    /// no guard against an earlier keystroke's slower request completing AFTER a later
    /// one and overwriting its (more current) results — a driver typing "harry potter"
    /// could see the list flicker back to stale "h"/"ha" results after "harry" had
    /// already rendered. Now: (1) cancels the previous search's task before starting a
    /// new one, (2) waits a short debounce so a fast typist doesn't fire a request per
    /// keystroke at all, (3) checks `Task.isCancelled` before calling
    /// `completionHandler`, so a superseded request can never win the race, and
    /// (4) uses `cachedLibraries()` (see its doc comment) instead of re-fetching
    /// `/api/libraries` every time.
    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { completionHandler([]); return }
        searchTask = Task {
            // Debounce: bail out early (before touching the network at all) if another
            // keystroke arrives within this window.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let libraries = try? await cachedLibraries(),
                  let libraryId = Self.currentLibraryId(libraries),
                  let results = try? await AudiobookshelfAPI.shared.search(libraryId: libraryId, query: query) else {
                if !Task.isCancelled { completionHandler([]) }
                return
            }
            guard !Task.isCancelled else { return }
            // HIG audit 2026-09-17 M14: this used to hand back a flat
            // `prefix(Self.capItemCount(Limit.browseList))` with no signal that
            // anything was cut, the one place in this file that truncates without the
            // "Show more…" cue `applyWindowedItems` uses for browse lists (see its doc
            // comment). Search has no next page to page into — the CPSearchTemplate
            // API re-invokes this delegate method on every keystroke instead — so the
            // row is disabled rather than tappable, same treatment as the pure-status
            // rows in `reloadSetup()`/`reloadHome()` (`isEnabled = false`, no handler,
            // detail text/label explains why).
            let cap = Self.capItemCount(Limit.browseList)
            guard results.count > cap else {
                completionHandler(results.map(self.makeBookRow))
                return
            }
            var rows = results.prefix(max(cap - 1, 0)).map(self.makeBookRow)
            let moreItem = CPListItem(text: String(localized: "More matches — refine your search"), detailText: nil)
            moreItem.isEnabled = false
            rows.append(moreItem)
            completionHandler(rows)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        // makeBookRow set a handler that starts playback; invoke it, else just finish.
        if let handler = item.handler {
            handler(item, completionHandler)
        } else {
            completionHandler()
        }
    }
}

// MARK: - CPSessionConfigurationDelegate  (vehicle display-limit changes)

extension CarPlayCoordinator: CPSessionConfigurationDelegate {
    /// Fires when the vehicle's reported UI limits change — e.g. the car starts
    /// moving and adds `.keyboard`, or stops and drops it again. Reruns
    /// `reloadLibrary()` (the same method `start()` and every other Library-tab
    /// change already funnels through) so the Search row's enabled/detail state in
    /// `shouldOfferKeyboardRows(limitedUserInterfaces:)` reflects the current limit rather
    /// than whatever was true when the tab last rendered.
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        reloadLibrary()
    }
}

// MARK: - Weak row references (live-sync bookkeeping)

/// Weakly holds a browse row so we can update its now-playing indicator without
/// keeping dismissed templates alive. CarPlay retains visible items; once a
/// template is popped, its items deallocate and `item` becomes nil (pruned).
private final class WeakBookRow {
    weak var item: CPListItem?
    let itemId: String
    /// Batch 327: the book's server-side progress as of when the row was built, so
    /// `refreshNowPlayingIndicators` can rebuild this row's `CPPlaybackConfiguration`
    /// (see `CarPlayCoordinator.bookPlaybackState`) from the tracking entry alone.
    ///
    /// Plain `Double`s rather than a whole `LibraryItem` or a `PlaybackRowState`: these
    /// two numbers are the only part of the state that is fixed for this row's lifetime.
    /// The ACTION half, and whose position is authoritative, both depend on whether this
    /// row is the current book at refresh time — which is exactly what changes.
    let serverElapsed: Double
    let serverDuration: Double
    init(item: CPListItem, itemId: String, serverElapsed: Double, serverDuration: Double) {
        self.item = item
        self.itemId = itemId
        self.serverElapsed = serverElapsed
        self.serverDuration = serverDuration
    }
}

private final class WeakChapterRow {
    weak var item: CPListItem?
    let start: Double
    let end: Double
    init(item: CPListItem, start: Double, end: Double) {
        self.item = item
        self.start = start
        self.end = end
    }
}
