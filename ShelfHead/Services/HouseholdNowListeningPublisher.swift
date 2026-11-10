import Foundation

// MARK: - Settings

extension SettingsKeys {
    /// Batch 454: "Share what I'm listening to". Default OFF; turning it on is the user's choice.
    static let householdShareNowListening = "settings_householdShareNowListening"
}

extension SettingsStore {
    static var householdShareNowListening: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKeys.householdShareNowListening) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.householdShareNowListening) }
    }
}

// MARK: - Pure rules

/// Batch 454: when to publish the Now Listening record. At most once a minute while playing, plus at once
/// when you pause, finish, or start a different book. Pure; pinned by `HouseholdSocialTests`.
nonisolated enum NowListeningThrottle {
    static let interval: TimeInterval = 60
    /// Past this the book counts as finished when playback stops.
    static let finishedProgress = 0.99

    enum Trigger: Equatable { case tick, pause, finish, bookChanged }

    /// What, if anything, happened since the last look. `wasPlaying`/`previousItemId` are the last look's
    /// state. A paused book that was merely loaded (app launch) is not "now listening", so a book change
    /// only counts while playing.
    static func trigger(wasPlaying: Bool, isPlaying: Bool, previousItemId: String?, itemId: String?,
                        progress: Double) -> Trigger? {
        guard itemId != nil else { return nil }
        if wasPlaying && !isPlaying {
            return progress >= finishedProgress ? .finish : .pause
        }
        guard isPlaying else { return nil }
        if itemId != previousItemId { return .bookChanged }
        return .tick
    }

    static func shouldPublish(_ trigger: Trigger, lastPublishedAt: Date?, now: Date) -> Bool {
        switch trigger {
        case .pause, .finish, .bookChanged:
            return true
        case .tick:
            guard let lastPublishedAt else { return true }
            return now.timeIntervalSince(lastPublishedAt) >= interval
        }
    }

    /// Progress to publish: a finished book says 1.
    static func publishedProgress(_ progress: Double, trigger: Trigger) -> Double {
        trigger == .finish ? 1 : min(max(progress, 0), 1)
    }
}

// MARK: - Publisher

/// Batch 454: publishes your `NowListening` record when (and only when) you've turned sharing on. It polls
/// `PlayerViewModel` every few seconds (cheap property reads) instead of hooking the player, so it needs one
/// call: `HouseholdNowListeningPublisher.shared.start(player: playerViewModel)` once at launch. The poll
/// notices pause and finish within one interval; `evaluate()` can also be called straight from the pause path
/// for an instant publish.
@MainActor
final class HouseholdNowListeningPublisher {
    static let shared = HouseholdNowListeningPublisher()

    private var player: PlayerViewModel?
    private var loop: Task<Void, Never>?
    private var lastPublishedAt: Date?
    private var wasPlaying = false
    private var lastItemId: String?

    /// Seconds between looks. Publishing itself is throttled to `NowListeningThrottle.interval`.
    private static let pollSeconds: UInt64 = 10

    private init() {}

    func start(player: PlayerViewModel) {
        self.player = player
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.evaluate()
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    /// Looks at the player once and publishes when the rules say so.
    func evaluate(now: Date = Date()) {
        guard let player else { return }
        let isPlaying = player.isPlaying
        let book = player.currentBook
        let itemId = book?.id
        defer {
            wasPlaying = isPlaying
            lastItemId = itemId
        }
        guard SettingsStore.householdShareNowListening else { return }
        // Review 7 Medium 11: a kid account never publishes what it plays.
        guard !KidProfileStore.standard.isKid(AccountStore.currentAccountId) else { return }
        let store = HouseholdStore.shared
        guard store.isInHousehold, let memberId = store.myMemberId, let book, !book.isPodcast,
              player.currentEpisode == nil else { return }
        let progress = player.progress
        guard let trigger = NowListeningThrottle.trigger(wasPlaying: wasPlaying, isPlaying: isPlaying,
                                                        previousItemId: lastItemId, itemId: itemId,
                                                        progress: progress),
              NowListeningThrottle.shouldPublish(trigger, lastPublishedAt: lastPublishedAt, now: now) else { return }
        lastPublishedAt = now
        store.save(.nowListening(HouseholdNowListening(
            memberId: memberId,
            libraryItemId: book.id,
            serverFingerprint: ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL),
            title: book.title,
            author: book.authorName,
            progress: NowListeningThrottle.publishedProgress(progress, trigger: trigger),
            updatedAt: now)))
    }

    /// Call when the toggle changes. Off deletes your record; on publishes at once if a book is playing.
    func sharingChanged(enabled: Bool) {
        let store = HouseholdStore.shared
        if enabled {
            lastPublishedAt = nil
            // Treat the current state as "just started" so a playing book publishes right away.
            wasPlaying = false
            lastItemId = nil
            evaluate()
        } else if let memberId = store.myMemberId, let record = store.snapshot.nowListening[memberId] {
            store.delete(.nowListening(record))
        }
    }
}
