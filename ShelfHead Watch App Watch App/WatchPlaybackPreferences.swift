import Foundation

/// Batch 495 (REVIEW 2026-11-11 W7): the listener's playback settings for a book played on
/// this Watch (standalone), from the last settings payload the iPhone sent
/// (`WatchChapterSkipSettings`, persisted), the last iPhone snapshot, and speeds set on
/// this Watch. Pure, so the precedence is pinned by `Batch495WatchPlaybackPreferencesTests`.
nonisolated enum WatchPlaybackPreferences {
    static let minimumRate = 0.5
    static let maximumRate = 3.0

    /// Skip intervals: the settings payload's, else the last iPhone snapshot's
    /// (`WatchPlaybackState.skipBackwardInterval`/`skipForwardInterval`), else 15 s / 30 s.
    /// A zero, negative or non-finite value counts as missing.
    static func skipIntervals(settings: WatchChapterSkipSettings,
                              snapshotBackward: Double?, snapshotForward: Double?) -> (backward: Double, forward: Double) {
        func usable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        let backward = usable(settings.skipBackwardInterval) ?? usable(snapshotBackward) ?? StandaloneAudioEngine.skipBackwardSeconds
        let forward = usable(settings.skipForwardInterval) ?? usable(snapshotForward) ?? StandaloneAudioEngine.skipForwardSeconds
        return (backward, forward)
    }

    /// Smart rewind is on unless the iPhone said it's off. An iPhone too old to send the
    /// setting gets the iPhone's own default (on, `SettingsStore.registerDefaults`).
    static func smartRewindIsEnabled(settings: WatchChapterSkipSettings) -> Bool {
        settings.smartRewind ?? true
    }

    /// The speed a book starts at on this Watch. Precedence, first usable value wins:
    /// 1. the speed set for this book on this Watch that the iPhone hasn't confirmed yet.
    ///    Batch 497 (REVIEW 2026-11-11 W7): the Watch now sends it to the iPhone
    ///    (`WatchBookSpeedUpdate`) and drops its own entry once the iPhone's settings come
    ///    back holding the same speed (`acknowledged`), so after that a later iPhone change
    ///    wins as rule 2. Until then (in flight, an iPhone app too old to receive it, or
    ///    refused during SharePlay) the Watch's choice still wins here;
    /// 2. the iPhone's remembered speed for this book;
    /// 3. the last speed set on this Watch for any book (only when one was ever set here,
    ///    so a listener who used the Watch's speed before Batch 495 keeps it);
    /// 4. the iPhone's default speed;
    /// 5. 1×.
    /// Clamped to 0.5×–3×, the range both devices offer. The iPhone's Listening Profile
    /// speed is not mirrored.
    static func startRate(itemId: String, watchBookSpeeds: [String: Double],
                          settings: WatchChapterSkipSettings, watchLastRate: Double?) -> Double {
        func usable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        let rate = usable(watchBookSpeeds[itemId])
            ?? usable(settings.perBookSpeeds?[itemId])
            ?? usable(watchLastRate)
            ?? usable(settings.defaultSpeed)
            ?? 1.0
        return clampedRate(rate)
    }

    static func clampedRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1.0 }
        return min(max(rate, minimumRate), maximumRate)
    }

    /// Records `rate` for `itemId` in the Watch's own map, keeping it to `cap` entries.
    /// The entry just set is always kept (same trimming as the iPhone's
    /// `SettingsStore.setSpeed`).
    static func recording(_ rate: Double, forItem itemId: String, in map: [String: Double],
                          cap: Int = bookSpeedCap) -> [String: Double] {
        var map = map
        map[itemId] = rate
        if map.count > cap {
            for key in map.keys.sorted() where key != itemId {
                map.removeValue(forKey: key)
                if map.count <= cap { break }
            }
        }
        return map
    }

    /// Batch 497 (REVIEW 2026-11-11 W7): two speeds are the same within half the iPhone's
    /// 0.05 step (it rounds what it stores).
    static func speedsMatch(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= 0.025 + 1e-9
    }

    /// Batch 497 (W7): the Watch's map after the listener sets `rate` for `itemId` here,
    /// and whether to send it to the iPhone. When the iPhone already remembers that speed
    /// for the book and no earlier Watch speed for it is still unconfirmed, no Watch entry
    /// is kept and nothing is sent: rule 2 gives the same speed, and a later iPhone change
    /// then wins. With an unconfirmed entry, an earlier send may yet change the iPhone's
    /// copy, so this one is recorded and sent too (they arrive in order).
    static func settingWatchSpeed(_ rate: Double, forItem itemId: String, in map: [String: Double],
                                  phoneSpeeds: [String: Double]?,
                                  cap: Int = bookSpeedCap) -> (map: [String: Double], sendsToPhone: Bool) {
        if map[itemId] == nil, speedsMatch(phoneSpeeds?[itemId], rate) {
            return (map, false)
        }
        return (recording(rate, forItem: itemId, in: map, cap: cap), true)
    }

    /// Batch 497 (W7): drops each Watch entry the iPhone's settings now hold the same speed
    /// for. That's the iPhone's confirmation that it stored the Watch's choice.
    static func acknowledged(watchBookSpeeds: [String: Double], phoneSpeeds: [String: Double]?) -> [String: Double] {
        guard let phoneSpeeds, !phoneSpeeds.isEmpty else { return watchBookSpeeds }
        return watchBookSpeeds.filter { !speedsMatch(phoneSpeeds[$0.key], $0.value) }
    }

    static let bookSpeedCap = 200
    /// UserDefaults key for the Watch's own per-book speeds.
    static let bookSpeedsDefaultsKey = "standalone.perBookSpeed"
}
