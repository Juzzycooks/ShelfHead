import SwiftUI
import WatchKit

/// Batch 411 (docs/design/watch-redesign-2026-10-21.md, "The Shelf"): the app's root.
/// Replaces `WatchHomeView` (hero card + five tiles) and the second `NavigationStack` the
/// companion "something's playing" root used to wrap around Now Playing.
///
/// One cover per page, in a vertical-page `TabView` (watchOS 10), so the Crown moves
/// book to book with the system's own detents and page indicator. A tap plays the book
/// where `WatchShelf` says it plays (or shows Now Playing for the book already loaded); a
/// long press opens Book Details. Library and Settings are toolbar pushes.
///
/// The book list is `WatchShelf.sleeves(for:)` (pure, unit-tested). This view only
/// gathers the inputs from both stacks and routes taps.
struct WatchShelfView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchConnectivityStore.self) private var companion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var path: [WatchShelfRoute] = []
    @State private var selection: String?
    @State private var downloadBooks: [WatchShelfBook] = []
    @State private var pendingPhonePlay: WatchPlayRequest?
    /// Decided once per launch, as `WatchRootView` always did: a fresh iPhone snapshot
    /// with a book in it opens on that book's Now Playing, pushed over the Shelf so Back
    /// lands here.
    @State private var didDecideLaunchRoute = false
    /// The skeleton shows for `skeletonLimit` at most; after that a slow network gets the
    /// Shelf with what's known (downloads, the iPhone's book, Browse), and books in
    /// progress slot in when they arrive.
    @State private var skeletonExpired = false
    private static let skeletonLimit: Duration = .seconds(4)

    /// The one-time "Get this Watch ready for runs" page (Critique 2026-10-06, onboard).
    @State private var runSetupDismissed = UserDefaults.standard.bool(forKey: WatchRunSetupPrompt.dismissedDefaultsKey)
    @State private var runSetupCompleted = UserDefaults.standard.bool(forKey: WatchRunSetupPrompt.completedDefaultsKey)

    private var engine: StandaloneAudioEngine { store.standalone }
    private var library: WatchStandaloneLibraryStore { store.library }

    // MARK: - Inputs

    private var input: WatchShelfInput {
        var input = WatchShelfInput()
        if let state = store.playbackState, state.hasActiveItem, !companion.isStateStale {
            input.phoneCurrent = WatchShelfBook(itemId: state.itemId, title: state.title, author: state.author,
                                                progress: store.estimatedProgress, coverData: state.coverData)
            input.phoneIsPlaying = state.isPlaying
        }
        if engine.isLoaded, let itemId = engine.currentItemId {
            input.watchCurrent = WatchShelfBook(itemId: itemId, title: engine.itemTitle, author: engine.itemAuthor,
                                                progress: engine.duration > 0 ? engine.currentTime / engine.duration : 0)
            input.watchIsPlaying = engine.isPlaying
        }
        if store.authState == .active {
            input.serverInProgress = library.allInProgressItems.map { item in
                WatchShelfBook(itemId: item.id,
                               title: item.media?.metadata?.title ?? String(localized: "Untitled"),
                               author: item.media?.metadata?.authorName ?? String(localized: "Unknown Author"),
                               progress: item.mediaProgress?.progress ?? 0)
            }
        }
        input.mirroredInProgress = WatchShelf.mirroredInProgress(store.recentlyAdded)
        input.downloads = downloadBooks
        input.isStandaloneMode = store.mode == .standalone
        input.phoneIsReachable = companion.isReachable
        input.hasWatchSession = store.authState == .active
        // Batch 495 (REVIEW 2026-11-11 W6): what the downloaded mark and an offline
        // stream's dimmed cover need.
        input.downloadedItemIds = Set(store.localDownloads.downloads.keys.filter { store.localDownloads.isDownloaded(itemId: $0) })
        input.networkIsAvailable = store.progressSync.isNetworkAvailable
        input.serverIsReachable = !library.inProgressIsFromCache
        return input
    }

    private var sleeves: [WatchShelfSleeve] { WatchShelf.sleeves(for: input) }

    /// Batch 496 (REVIEW 2026-11-11 W13): which setup page, if any. Its place on the Shelf
    /// (second, not last) is `WatchShelf.pages(sleeves:prompt:)`.
    private var setupPrompt: WatchSetupPromptKind? {
        WatchRunSetupPrompt.prompt(hasNoSession: store.authState == .noSession,
                                   wasDismissed: runSetupDismissed,
                                   wasCompleted: runSetupCompleted,
                                   signedOutOnPhone: store.signedOutOnPhone)
    }

    private var pages: [WatchShelfPage] { WatchShelf.pages(sleeves: sleeves, prompt: setupPrompt) }

    private var pageIds: [String] { pages.map(\.id) }

    /// Batch 496 (W13): Set Up Again's hand-over in flight.
    @State private var isRequestingHandoff = false
    @State private var handoffFailed = false

    /// Nothing to show yet but something is on its way: the first iPhone snapshot, or the
    /// Watch's own in-progress fetch.
    private var isLoading: Bool {
        guard !skeletonExpired, sleeves.allSatisfy({ $0.book == nil }) else { return false }
        let waitingForPhone = companion.isReachable && !companion.hasReceivedAnySnapshot
        let waitingForServer = store.authState == .active && library.inProgressState == .loading
        return waitingForPhone || waitingForServer
    }

    /// Re-read downloads when the finished set changes or playback stops (a stop writes the
    /// position the order depends on).
    private var downloadsKey: String {
        let ids = store.localDownloads.downloads.keys
            .filter { store.localDownloads.isDownloaded(itemId: $0) }
            .sorted()
            .joined(separator: ",")
        return "\(ids)|\(engine.isLoaded)"
    }

    /// Batch 495 (W6): includes the network, so a list restored from the saved copy while
    /// offline is fetched again (and its sleeves undimmed) when the network returns.
    private var inProgressKey: String {
        "\(store.authState == .active)|\(library.selectedLibraryId ?? "")|\(engine.isLoaded)|\(companion.playbackState?.itemId ?? "")|\(store.progressSync.isNetworkAvailable)"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: $selection) {
                if isLoading {
                    WatchShelfSkeletonPage()
                        .tag(Optional("shelf.loading"))
                } else {
                    // Batch 496 (REVIEW 2026-11-11 W13): the setup page sits second, not last.
                    let shelfPages = pages
                    ForEach(Array(shelfPages.enumerated()), id: \.element.id) { index, shelfPage in
                        switch shelfPage {
                        case .sleeve(let sleeve):
                            page(for: sleeve, index: index, count: shelfPages.count)
                                .tag(Optional(sleeve.id))
                        case .setupPrompt(let kind):
                            Group {
                                switch kind {
                                case .firstRun: runSetupPage
                                case .signedOutOnPhone: signedOutPage
                                }
                            }
                            .tag(Optional(WatchShelfPage.setupPromptId))
                        }
                    }
                }
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(WatchTheme.background, for: .tabView)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: WatchShelfRoute.browse) {
                        toolbarGlyph("books.vertical")
                    }
                    .tint(WatchTheme.cardBackground)
                    .accessibilityLabel("Library")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: WatchShelfRoute.settings) {
                        toolbarGlyph("gearshape")
                    }
                    .tint(WatchTheme.cardBackground)
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: WatchShelfRoute.self) { route in
                destination(for: route)
            }
        }
        .onChange(of: pageIds, initial: true) { _, ids in
            if selection == nil || !ids.contains(selection ?? "") {
                selection = ids.first
            }
        }
        .task(id: downloadsKey) { await loadDownloadBooks() }
        .task(id: inProgressKey) { await loadInProgress() }
        .task { decideLaunchRouteOnce() }
        .task {
            try? await Task.sleep(for: Self.skeletonLimit)
            skeletonExpired = true
        }
        .onChange(of: companion.hasReceivedAnySnapshot) { _, hasSnapshot in
            if hasSnapshot { decideLaunchRouteOnce() }
        }
        .onChange(of: store.authState, initial: true) { _, state in
            guard state == .active, !runSetupCompleted else { return }
            runSetupCompleted = true
            UserDefaults.standard.set(true, forKey: WatchRunSetupPrompt.completedDefaultsKey)
        }
        .onChange(of: store.mode) { _, newMode in
            // "Play on Watch" from the iPhone's Now Playing flips the mode once the book
            // loads here. The iPhone's screen can't follow, so swap it for this Watch's.
            guard newMode == .standalone, engine.isLoaded, path.last == .phoneNowPlaying else { return }
            path[path.count - 1] = watchNowPlayingRoute
        }
        .onOpenURL { url in
            guard WatchDeepLink(url: url) == .nowPlaying else { return }
            if store.mode == .standalone, engine.isLoaded {
                path = [watchNowPlayingRoute]
            } else {
                path = [.phoneNowPlaying]
            }
            didDecideLaunchRoute = true
        }
        .confirmationDialog(
            pendingPhonePlay.map { String(localized: "Play \u{201C}\($0.title)\u{201D}?") } ?? "",
            isPresented: Binding(get: { pendingPhonePlay != nil }, set: { if !$0 { pendingPhonePlay = nil } }),
            titleVisibility: .visible
        ) {
            Button("Play") {
                if let request = pendingPhonePlay {
                    if request.stopsOnWatch {
                        // Batch 490 (REVIEW 2026-11-11 W4): save and stop this Watch first;
                        // the iPhone half may still ask about the iPhone's own book.
                        Task {
                            await store.standalone.stopAndWriteOutProgress()
                            playOnPhone(itemId: request.itemId, title: request.title)
                        }
                    } else {
                        companion.playItem(itemId: request.itemId)
                        path.append(.phoneNowPlaying)
                    }
                }
                pendingPhonePlay = nil
            }
            Button("Cancel", role: .cancel) { pendingPhonePlay = nil }
        } message: {
            if let request = pendingPhonePlay {
                if request.stopsOnWatch {
                    Text(String(localized: "\u{201C}\(request.currentTitle)\u{201D} stops on this Watch.", comment: "Confirmation message; %@ is the title of the book now playing"))
                } else {
                    Text("\u{201C}\(request.currentTitle)\u{201D} stops on your iPhone.")
                }
            }
        }
        // Moved from `WatchHomeView`. Only standalone sync sets a conflict.
        .alert("Progress Doesn't Match", isPresented: Binding(
            get: { store.progressSync.pendingConflict != nil },
            set: { if !$0 { store.progressSync.dismissConflict() } }
        ), presenting: store.progressSync.pendingConflict) { conflict in
            Button("Keep This Watch (\(conflict.localTime.watchFormattedTime))") {
                Task { await store.progressSync.resolveConflict(keepLocal: true) }
            }
            Button("Use Server (\(conflict.serverTime.watchFormattedTime))") {
                Task { await store.progressSync.resolveConflict(keepLocal: false) }
            }
            Button("Ask Me Later", role: .cancel) {
                store.progressSync.dismissConflict()
            }
        } message: { conflict in
            Text("\u{201C}\(conflict.title)\u{201D} has different progress here than on the server \u{2014} this Watch is at \(conflict.localTime.watchFormattedTime), the server is at \(conflict.serverTime.watchFormattedTime). Which one should win?")
        }
    }

    /// Accent is for action and live state (DESIGN.md), so the toolbar's two navigation
    /// buttons sit on espresso glass with a cream glyph, like Now Playing's "⋯".
    private func toolbarGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(WatchMetrics.rowIconFont())
            .foregroundStyle(WatchTheme.icon)
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for sleeve: WatchShelfSleeve, index: Int, count: Int) -> some View {
        WatchShelfSleeveView(
            sleeve: sleeve,
            coverSide: coverSide,
            isDownloaded: sleeve.book.map { store.localDownloads.isDownloaded(itemId: $0.itemId) } ?? false,
            dimsForAlwaysOn: isLuminanceReduced,
            onTap: { activate(sleeve) },
            onDetails: sleeve.book == nil ? nil : { showDetails(sleeve) },
            onAdjust: { direction in move(from: sleeve.id, direction: direction) })
    }

    private var coverSide: CGFloat {
        let bounds = WKInterfaceDevice.current().screenBounds
        return WatchShelf.coverSide(screenWidth: bounds.width, screenHeight: bounds.height,
                                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    private var runSetupPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Get this Watch ready for runs")
                    .font(WatchMetrics.navigationRowTitleFont(weight: .semibold))
                    .foregroundStyle(WatchTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sign in on the Watch so it can play downloads without your iPhone.")
                    .font(WatchMetrics.secondaryFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink(value: WatchShelfRoute.setup) {
                    Text("Set Up")
                        .font(WatchMetrics.secondaryFont(weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // Batch 490 (REVIEW 2026-11-11 W14): Worn Taupe with the wrist down (Always-On Rule).
                .watchProminentTint()
                Button("Not Now") {
                    runSetupDismissed = true
                    UserDefaults.standard.set(true, forKey: WatchRunSetupPrompt.dismissedDefaultsKey)
                }
                .font(WatchMetrics.secondaryFont())
                .buttonStyle(.plain)
                .foregroundStyle(WatchTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, WatchMetrics.scrollContentHorizontalPadding)
        }
    }

    /// Batch 496 (REVIEW 2026-11-11 W13): after the iPhone's account switch or sign-out.
    /// Deliberately not an automatic hand-over: a switch on a shared iPhone means someone
    /// else is using it (a parent's account must not land on a child's Watch), and an SSO
    /// account can only lend a short-lived token. The wearer's tap is the consent, and the
    /// hand-over stays interactive, as Batch 312 made it.
    private var signedOutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Signed out on iPhone")
                    .font(WatchMetrics.navigationRowTitleFont(weight: .semibold))
                    .foregroundStyle(WatchTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your iPhone switched accounts or signed out, so this Watch did too. Set it up again to play here without your iPhone.")
                    .font(WatchMetrics.secondaryFont())
                    .foregroundStyle(WatchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    setUpAgain()
                } label: {
                    Group {
                        if isRequestingHandoff {
                            ProgressView()
                                .accessibilityLabel("Setting up")
                        } else {
                            Text("Set Up Again")
                                .font(WatchMetrics.secondaryFont(weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .watchProminentTint()
                .disabled(isRequestingHandoff)
                if handoffFailed, let message = store.authFailureMessage {
                    Text(message)
                        .font(WatchMetrics.secondaryFont())
                        .foregroundStyle(WatchTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Not Now") {
                    store.dismissSignedOutOnPhone()
                }
                .font(WatchMetrics.secondaryFont())
                .buttonStyle(.plain)
                .foregroundStyle(WatchTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, WatchMetrics.scrollContentHorizontalPadding)
        }
    }

    /// With the iPhone in reach, asks it for the account it is on now, right here. Otherwise
    /// opens Account, which offers the Watch's own sign-in.
    private func setUpAgain() {
        WatchHaptics.tap()
        guard companion.isReachable else {
            path.append(.setup)
            return
        }
        handoffFailed = false
        isRequestingHandoff = true
        Task {
            let ok = await store.requestHandoffFromPhone()
            isRequestingHandoff = false
            handoffFailed = !ok
        }
    }

    // MARK: - Routing

    private var watchNowPlayingRoute: WatchShelfRoute {
        .watchNowPlaying(itemId: engine.currentItemId ?? "", title: engine.itemTitle, author: engine.itemAuthor)
    }

    @ViewBuilder
    private func destination(for route: WatchShelfRoute) -> some View {
        switch route {
        case .phoneNowPlaying:
            NowPlayingView()
        case .watchNowPlaying(let itemId, let title, let author):
            StandaloneNowPlayingView(itemId: itemId, title: title, author: author, coverItemId: itemId)
        case .details(let itemId, let title, let author, let progress):
            WatchBookDetailView(itemId: itemId, title: title, author: author, progress: progress)
        case .browse:
            WatchBrowseView()
        case .settings:
            SettingsView()
        case .setup:
            WatchAccountView()
        }
    }

    private func activate(_ sleeve: WatchShelfSleeve) {
        WatchHaptics.tap()
        switch sleeve.kind {
        case .current(let source, _):
            path.append(source == .watch ? watchNowPlayingRoute : .phoneNowPlaying)
        case .book(let target, let isAvailable):
            guard let book = sleeve.book else { return }
            // A sleeve that can't play here says why on its glyph; the tap opens Details,
            // which spells it out and offers the download.
            guard isAvailable else {
                showDetails(sleeve)
                return
            }
            switch target {
            case .watch:
                path.append(.watchNowPlaying(itemId: book.itemId, title: book.title, author: book.author))
            case .iPhone:
                // Batch 490 (REVIEW 2026-11-11 W4): a book loaded on this Watch is saved and
                // stopped before the iPhone starts, asking first when it is playing.
                let engine = store.standalone
                switch WatchPlayOnPhoneWatchAction.decide(engineIsLoaded: engine.isLoaded, engineIsPlaying: engine.isPlaying,
                                                          engineTitle: engine.itemTitle) {
                case .nothing:
                    playOnPhone(itemId: book.itemId, title: book.title)
                case .stopWatch:
                    Task {
                        await engine.stopAndWriteOutProgress()
                        playOnPhone(itemId: book.itemId, title: book.title)
                    }
                case .confirmStoppingWatch(let currentTitle):
                    pendingPhonePlay = WatchPlayRequest(itemId: book.itemId, title: book.title,
                                                        currentTitle: currentTitle, stopsOnWatch: true)
                }
            }
        case .browse:
            path.append(.browse)
        case .setup:
            path.append(.setup)
        }
    }

    /// The iPhone half of a sleeve tap: plays now, or asks when the iPhone is playing a
    /// different book. (Body moved out of `activate` in Batch 490 so W4 can call it after
    /// stopping this Watch.)
    private func playOnPhone(itemId: String, title: String) {
        switch WatchPlayRequestDecision.decide(requestedItemId: itemId, current: companion.playbackState) {
        case .playNow:
            companion.playItem(itemId: itemId)
            path.append(.phoneNowPlaying)
        case .confirmReplacing(let currentTitle):
            pendingPhonePlay = WatchPlayRequest(itemId: itemId, title: title, currentTitle: currentTitle)
        }
    }

    private func showDetails(_ sleeve: WatchShelfSleeve) {
        guard let book = sleeve.book else { return }
        path.append(.details(itemId: book.itemId, title: book.title, author: book.author, progress: book.progress))
    }

    /// VoiceOver's adjustable action on a sleeve: the Crown's paging, for swipe users.
    private func move(from id: String, direction: AccessibilityAdjustmentDirection) {
        let ids = pageIds
        guard let index = ids.firstIndex(of: id) else { return }
        switch direction {
        case .increment: if index + 1 < ids.count { selection = ids[index + 1] }
        case .decrement: if index > 0 { selection = ids[index - 1] }
        @unknown default: break
        }
    }

    private func decideLaunchRouteOnce() {
        guard !didDecideLaunchRoute, companion.hasReceivedAnySnapshot else { return }
        didDecideLaunchRoute = true
        // Finding 24 (26 August 2026): only a fresh snapshot may open on Now Playing; a
        // redelivered stale context would otherwise open on a book that has stopped.
        if store.mode == .companion, !companion.isStateStale,
           companion.playbackState?.hasActiveItem == true, path.isEmpty {
            path = [.phoneNowPlaying]
        }
    }

    // MARK: - Loading

    private func loadInProgress() async {
        guard store.authState == .active else { return }
        // Batch 495 (W6): a library list that failed offline is tried again once the
        // network is back (`inProgressKey`), so the saved shelf gives way to the live one.
        if case .failed = library.librariesState, store.progressSync.isNetworkAvailable {
            await library.reloadLibraries()
        } else {
            await library.loadLibrariesIfNeeded()
        }
        await library.loadInProgress()
    }

    /// This Watch's finished downloads, each at the newer of its own position and the
    /// server's (the manifest's, or the iPhone's snapshot), resolved by `WatchResumePoint`
    /// as Play resolves it. Moved from `WatchHomeView.loadResumeCandidate`.
    private func loadDownloadBooks() async {
        let manager = store.localDownloads
        var inputs: [WatchResumeInput] = []
        for (itemId, download) in manager.downloads where manager.isDownloaded(itemId: itemId) {
            let local = await store.progressSync.lastKnownLocalProgress(itemId: itemId)
            let server = WatchServerProgressPicker.newest([companionProgress(itemId: itemId), download.serverProgress])
            let point = WatchResumePoint.resolve(server: server, localTime: local?.currentTime,
                                                 localUpdatedAtMs: local?.updatedAt, duration: download.duration)
            inputs.append(WatchResumeInput(
                itemId: itemId,
                title: download.title,
                author: download.author,
                duration: download.duration,
                downloadedAt: download.downloadedAt,
                lastPosition: point.position,
                lastPlayedAt: point.updatedAtMs))
        }
        downloadBooks = WatchShelf.orderedDownloads(inputs)
    }

    private func companionProgress(itemId: String) -> WatchServerProgress? {
        guard let state = store.playbackState else { return nil }
        return WatchServerProgress.fromCompanion(
            snapshotItemId: state.itemId, requestedItemId: itemId,
            sameServer: WatchStore.comparableServerURL(state.scope.serverURL)
                == WatchStore.comparableServerURL(AuthStore.shared.serverURL),
            estimatedTime: WatchProgressEstimator.estimatedCurrentTime(state: state),
            isPlaying: state.isPlaying,
            lastConfirmedUpdate: state.lastConfirmedUpdate)
    }
}

/// Where the Shelf's one `NavigationStack` can go.
enum WatchShelfRoute: Hashable {
    case phoneNowPlaying
    case watchNowPlaying(itemId: String, title: String, author: String)
    case details(itemId: String, title: String, author: String, progress: Double)
    case browse
    case settings
    case setup
}

// MARK: - Sleeve

/// One page of the Shelf: the cover, a two-line title, and the progress ring with the
/// source glyph. One VoiceOver element whose default action is the tap.
private struct WatchShelfSleeveView: View {
    let sleeve: WatchShelfSleeve
    let coverSide: CGFloat
    let isDownloaded: Bool
    let dimsForAlwaysOn: Bool
    let onTap: () -> Void
    let onDetails: (() -> Void)?
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            cover
            titleBlock
            statusLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.5) {
            guard let onDetails else { return }
            WatchHaptics.tap()
            onDetails()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(.default, onTap)
        .accessibilityAction(named: Text("Book Details")) { onDetails?() }
        .accessibilityAdjustableAction(onAdjust)
    }

    @ViewBuilder
    private var cover: some View {
        switch sleeve.kind {
        case .browse:
            glyphCover("books.vertical.fill")
        case .setup:
            glyphCover("applewatch")
        case .current, .book:
            if let book = sleeve.book {
                WatchShelfCover(book: book, isDownloaded: isDownloaded, side: coverSide)
                    // AX-6 (Round 4): an unavailable sleeve dims its cover only; the
                    // title, percent and crossed-out phone keep full contrast.
                    .opacity(dimsForAlwaysOn ? 0.6 : (sleeve.isAvailable ? 1 : 0.55))
            }
        }
    }

    private func glyphCover(_ systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WatchTheme.cardBackground)
            .overlay(
                Image(systemName: systemImage)
                    .font(WatchMetrics.heroGlyphFont())
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WatchTheme.icon))
            .frame(width: coverSide, height: coverSide)
            .accessibilityHidden(true)
    }

    private var titleText: String {
        switch sleeve.kind {
        case .browse: return String(localized: "Browse Library")
        case .setup: return String(localized: "Set Up ShelfHead")
        case .current, .book: return sleeve.book?.title ?? ""
        }
    }

    private var titleBlock: some View {
        Text(titleText)
            .font(WatchMetrics.contentRowTitleFont(weight: .semibold, rounded: true))
            .foregroundStyle(WatchTheme.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch sleeve.kind {
        case .browse:
            caption(String(localized: "Search and all books"))
        case .setup:
            caption(String(localized: "Sign in to play here"))
        case .current(_, let isPlaying):
            ringLine(isLive: isPlaying)
        case .book:
            ringLine(isLive: false)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WatchMetrics.captionFont())
            .foregroundStyle(WatchTheme.secondaryText)
            .lineLimit(1)
    }

    private func ringLine(isLive: Bool) -> some View {
        HStack(spacing: 5) {
            WatchShelfProgressRing(progress: sleeve.book?.progress ?? 0,
                                   tint: isLive && !dimsForAlwaysOn ? WatchTheme.accent : WatchTheme.icon)
                .frame(width: 13, height: 13)
            if let reason = sleeve.unavailableReason {
                // Batch 495 (REVIEW 2026-11-11 W6): a sleeve that can't play says why, in
                // words at full contrast, beside the reason's glyph (Dim-the-Picture Rule).
                Image(systemName: reason.systemImage)
                    .font(WatchMetrics.captionFont(weight: .semibold))
                    .foregroundStyle(WatchTheme.secondaryText)
                Text(Self.unavailableCaption(reason))
                    .font(WatchMetrics.captionFont(weight: .medium))
                    .foregroundStyle(WatchTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(verbatim: WatchShelf.percentText(sleeve.book?.progress ?? 0))
                    .font(WatchMetrics.captionFont(weight: .medium).monospacedDigit())
                    .foregroundStyle(WatchTheme.secondaryText)
                if let glyph = sleeve.sourceSystemImage {
                    Image(systemName: glyph)
                        .font(WatchMetrics.captionFont(weight: .semibold))
                        .foregroundStyle(WatchTheme.secondaryText)
                }
                // Batch 495 (W6): the downloaded mark. The sleeve's VoiceOver label says it.
                if sleeve.isDownloaded {
                    Image(systemName: WatchShelfSleeve.downloadedSystemImage)
                        .font(WatchMetrics.captionFont(weight: .semibold))
                        .foregroundStyle(WatchTheme.icon)
                }
            }
        }
    }

    /// Batch 495 (W6): the status line's words for a sleeve that can't play.
    private static func unavailableCaption(_ reason: WatchShelfUnavailableReason) -> String {
        switch reason {
        case .phoneOutOfReach:
            // The same words as Now Playing's out-of-range line, so one key and one translation.
            return String(localized: "iPhone out of range")
        case .noWatchSession:
            return String(localized: "Not signed in", comment: "Shelf sleeve status: the Watch has no sign-in of its own to stream with, and the book isn't downloaded")
        case .offline:
            return String(localized: "Offline", comment: "Shelf sleeve status: no network and the book isn't downloaded")
        case .serverUnreachable:
            return String(localized: "Server unreachable", comment: "Shelf sleeve status: the server didn't answer and the book isn't downloaded")
        }
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        guard let book = sleeve.book else { return titleText }
        let percent = WatchShelf.percentText(book.progress)
        // Batch 495 (REVIEW 2026-11-11 W6): the downloaded mark, spoken.
        if sleeve.isDownloaded {
            return String(localized: "\(book.title), by \(book.author), \(percent) listened, downloaded to this Watch", comment: "Shelf sleeve: title, author, percent listened, and that the book is downloaded to the Watch")
        }
        return String(localized: "\(book.title), by \(book.author), \(percent) listened", comment: "Shelf sleeve: title, author, percent listened")
    }

    private var accessibilityHint: String {
        switch sleeve.kind {
        case .current(let source, _):
            return source == .watch ? String(localized: "Opens Now Playing on this Watch") : String(localized: "Opens Now Playing on your iPhone")
        case .book(let target, let isAvailable):
            if !isAvailable {
                // Batch 495 (REVIEW 2026-11-11 W6): the hint names the sleeve's reason.
                switch sleeve.unavailableReason ?? .phoneOutOfReach {
                case .phoneOutOfReach:
                    return String(localized: "Unavailable, your iPhone isn\u{2019}t reachable. Opens Book Details.")
                case .noWatchSession:
                    return String(localized: "Unavailable, this Watch isn\u{2019}t signed in and the book isn\u{2019}t downloaded. Opens Book Details.")
                case .offline:
                    return String(localized: "Unavailable offline, the book isn\u{2019}t downloaded to this Watch. Opens Book Details.")
                case .serverUnreachable:
                    return String(localized: "Unavailable, the server isn\u{2019}t answering and the book isn\u{2019}t downloaded. Opens Book Details.")
                }
            }
            return target == .watch ? String(localized: "Plays on this Watch") : String(localized: "Plays on your iPhone")
        case .browse:
            return String(localized: "Opens Library")
        case .setup:
            return String(localized: "Opens setup for this Watch")
        }
    }
}

/// A sleeve's cover: the iPhone's bytes when it sent them, this Watch's downloaded file,
/// or the server's. With none of those, the title set on espresso, never a blank tile.
private struct WatchShelfCover: View {
    @Environment(WatchStore.self) private var watchStore
    let book: WatchShelfBook
    let isDownloaded: Bool
    let side: CGFloat
    @State private var loaded: Data?

    var body: some View {
        Group {
            if let data = book.coverData ?? loaded, let image = WatchDecodedCoverCache.image(for: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                // Batch 413: the shared title cover (Book Details uses it too).
                WatchTitleCover(title: book.title, author: book.author)
            }
        }
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: loaded != nil)
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
        .task(id: book.itemId) {
            guard book.coverData == nil else { return }
            if isDownloaded, let url = watchStore.localDownloads.localCoverURL(itemId: book.itemId),
               let data = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: url) }).value {
                loaded = data
                return
            }
            loaded = await WatchCoverLoader.shared.loadCoverData(itemId: book.itemId, width: Int(side * 2))
        }
    }
}

/// The ring under a cover. Animates only when the value changes (and not under Reduce
/// Motion, via `watchAnimation`).
private struct WatchShelfProgressRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(WatchTheme.cardBorder, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .watchAnimation(.easeOut(duration: WatchMetrics.stateChangeAnimationDuration), value: progress)
        .accessibilityHidden(true)
    }
}

/// Shown while the first iPhone snapshot or the server's in-progress list is on its way.
private struct WatchShelfSkeletonPage: View {
    var body: some View {
        let bounds = WKInterfaceDevice.current().screenBounds
        let side = WatchShelf.coverSide(screenWidth: bounds.width, screenHeight: bounds.height, isAccessibilitySize: false)
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WatchTheme.cardBackground)
                .frame(width: side, height: side)
            RoundedRectangle(cornerRadius: 4).fill(WatchTheme.cardBackground).frame(width: side * 0.8, height: 10)
            RoundedRectangle(cornerRadius: 4).fill(WatchTheme.cardBackground).frame(width: side * 0.4, height: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
