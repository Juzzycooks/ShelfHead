import Foundation
import GroupActivities
import Observation
import Combine

/// Batch 456: runs Listen Together (SharePlay) for the app. One instance (`shared`), started once
/// from the app root (`start()`), listens for sessions. For a session on a book from this
/// account's server it starts that book, attaches the AVPlayer's playback coordinator, then joins.
///
/// Unverified without two devices on a FaceTime call: the coordinator with the audio-processing tap,
/// multi-file books and background behaviour (see the Batch 456 report).
@MainActor
@Observable
final class ListenTogetherController {
    static let shared = ListenTogetherController()

    private(set) var state: ListenTogetherState = .idle

    @ObservationIgnored private var session: GroupSession<ListenTogetherActivity>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var messageTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var bookWatchTask: Task<Void, Never>?
    /// The last (book id, track) both sides agree on, so echoes of our own changes aren't re-sent.
    @ObservationIgnored private var lastBookId: String?
    @ObservationIgnored private var lastTrack: (itemId: String, index: Int)?
    @ObservationIgnored private var sessionTitle = ""
    @ObservationIgnored private var waitingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    private init() {}

    private var player: AudioPlayerService { AudioPlayerService.shared }
    private var myFingerprint: String { ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL) }

    var isActive: Bool { if case .active = state { return true } else { return false } }
    var isBusy: Bool { switch state { case .waiting, .active: return true; default: return false } }

    private func send(_ event: ListenTogetherEvent) { state = ListenTogetherLogic.reduce(state, event) }

    /// Begin listening for sessions the system hands us (a FaceTime call joined, or a shared link
    /// opened). Idempotent.
    func start() {
        guard listenerTask == nil else { return }
        // Review 4 Low (account switch): a session belongs to the account's server, so leave it.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        }
        listenerTask = Task { [weak self] in
            for await session in ListenTogetherActivity.sessions() {
                await self?.handle(session)
            }
        }
    }

    // MARK: Initiating

    /// Activates SharePlay for `item` over a live FaceTime call. Returns false when no call is
    /// active (the caller should then present the sharing controller / ShareLink instead).
    @discardableResult
    func startSharing(item: LibraryItem) async -> Bool {
        let activity = Self.activity(for: item, fingerprint: myFingerprint)
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            send(.startedSharing)
            startWaitingTimeout()
            do {
                _ = try await activity.activate()
                return true
            } catch {
                cancelWaitingTimeout()
                send(.failedToStart)
                return false
            }
        case .activationDisabled, .cancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Review 4 Medium 7: `.waiting` has no UI exit, so reset it if no session ever arrives
    /// (FaceTime sheet dismissed, call ended).
    private func startWaitingTimeout() {
        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ListenTogetherLogic.waitingTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.send(.waitTimedOut)
        }
    }

    private func cancelWaitingTimeout() {
        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = nil
    }

    nonisolated static func activity(for item: LibraryItem, fingerprint: String) -> ListenTogetherActivity {
        ListenTogetherActivity(libraryItemId: item.id, serverFingerprint: fingerprint, title: item.title, author: item.authorName)
    }

    // MARK: Session lifecycle

    private func handle(_ newSession: GroupSession<ListenTogetherActivity>) async {
        let activity = newSession.activity
        let matches = ListenTogetherLogic.fingerprintsMatch(activity.serverFingerprint, myFingerprint)
        send(.sessionOffered(matchesMyServer: matches, title: activity.title))
        guard matches else {
            // Not our server: never join, so the coordinator never drives this device.
            newSession.leave()
            return
        }
        cancelWaitingTimeout() // Review 5 Medium 4: only a matching session ends the wait
        leave()                                   // one session at a time
        send(.sessionOffered(matchesMyServer: true, title: activity.title))
        session = newSession
        sessionTitle = activity.title
        let messenger = GroupSessionMessenger(session: newSession)
        self.messenger = messenger

        // Start the book first (own account, own URLs); the coordinator then aligns the time.
        if AudioPlayerService.shared.currentItemId != activity.libraryItemId {
            await PlaybackCoordinator.shared.play(itemId: activity.libraryItemId)
        }
        guard session === newSession else { return }   // left or replaced while the book loaded
        // Review 4 Medium 6: the shared book didn't load (offline, deleted, no access): don't join,
        // or this device's different book would be broadcast to the group.
        guard ListenTogetherLogic.shouldJoin(loadedItemId: player.currentItemId, sharedItemId: activity.libraryItemId) else {
            newSession.leave()
            tearDown(failed: true)
            return
        }
        lastBookId = player.currentItemId
        lastTrack = player.currentItemId.map { ($0, player.currentTrackIndex) }

        // Apple's pattern: coordinate, then join.
        player.attachGroupSession(newSession)
        player.onTrackLoaded = { [weak self] itemId, index in self?.localTrackLoaded(itemId: itemId, index: index) }
        newSession.join()

        newSession.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                if case .active = self.state { self.send(.participantsChanged(participants.count)) }
                else { self.send(.joined(participants: participants.count, title: self.sessionTitle)) }
            }
            .store(in: &cancellables)
        newSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessionState in
                // The call ended or the group ended the activity: tidy up this side.
                if case .invalidated = sessionState { self?.tearDown(failed: false) }
            }
            .store(in: &cancellables)

        messageTasks.append(Task { [weak self] in
            for await (message, _) in messenger.messages(of: ListenTogetherMessage.self) {
                await self?.receive(message)
            }
        })
        watchLocalBook()
    }

    /// The user taps Leave. Ends this device's part only (the others keep listening).
    func leave() {
        session?.leave()
        tearDown(failed: false)
    }

    private func tearDown(failed: Bool) {
        cancelWaitingTimeout()
        messageTasks.forEach { $0.cancel() }
        messageTasks = []
        bookWatchTask?.cancel()
        bookWatchTask = nil
        cancellables.removeAll()
        player.detachGroupSession()
        player.onTrackLoaded = nil
        session = nil
        messenger = nil
        lastBookId = nil
        lastTrack = nil
        if isBusy || failed { send(.invalidated(failed: failed)) }
    }

    func dismissNotice() { send(.dismissedNotice) }

    // MARK: Messages

    private func receive(_ message: ListenTogetherMessage) async {
        switch message {
        case .bookChanged(let itemId, let title):
            guard itemId != player.currentItemId else { return }
            sessionTitle = title
            lastBookId = itemId
            lastTrack = (itemId, 0)
            await PlaybackCoordinator.shared.play(itemId: itemId)
        case .trackChanged(let itemId, let trackIndex):
            guard itemId == player.currentItemId else { return }
            lastTrack = (itemId, trackIndex)
            player.coordinatedMoveToTrack(trackIndex)
        }
    }

    private func localTrackLoaded(itemId: String, index: Int) {
        guard let messenger, session != nil else { return }
        if let last = lastTrack, last.itemId == itemId, last.index == index { return }   // echo of a remote change
        lastTrack = (itemId, index)
        Task { try? await messenger.send(ListenTogetherMessage.trackChanged(itemId: itemId, trackIndex: index)) }
    }

    /// Tells the group when *this* device starts a different book. Polls the player's current
    /// item id once a second (cheap, only while a session is live), because `PlayerViewModel` (not owned here) starts books.
    private func watchLocalBook() {
        bookWatchTask?.cancel()
        bookWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.localBookMayHaveChanged()
            }
        }
    }

    private func localBookMayHaveChanged() {
        guard let messenger, session != nil, let id = player.currentItemId, id != lastBookId else { return }
        lastBookId = id
        lastTrack = (id, player.currentTrackIndex)
        let title = PlaybackCoordinator.shared.playerViewModel?.currentBook?.title ?? sessionTitle
        sessionTitle = title
        Task { try? await messenger.send(ListenTogetherMessage.bookChanged(itemId: id, title: title)) }
    }
}
