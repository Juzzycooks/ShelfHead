import SwiftUI

/// PL-4 (docs/design-review.md): the chapters and sleep timer that standalone Watch playback
/// (`StandaloneAudioEngine`, no phone) was missing. The decisions live in these pure types so
/// they're unit-tested; the engine only feeds them the playback clock.

/// A sleep timer for standalone playback. Counts *playing* time, not wall-clock time: the engine
/// ticks it once per playback second, so pausing for an hour doesn't expire a 15-minute timer.
/// "End of chapter" is an absolute book position instead, so it also survives a seek back.
struct StandaloneSleepTimer: Equatable {
    /// The last seconds before the timer fires, over which the volume ramps down to silence.
    static let fadeSeconds: Double = 10

    let option: WatchSleepTimerOption
    /// Playing seconds left, for a minutes timer.
    private(set) var remainingSeconds: Double?
    /// Absolute book position where the chapter ends, for an end-of-chapter timer.
    let chapterEnd: Double?

    /// A minutes timer, or nil for a non-positive length.
    static func minutes(_ minutes: Int) -> StandaloneSleepTimer? {
        guard minutes > 0 else { return nil }
        return StandaloneSleepTimer(option: .minutes(minutes), remainingSeconds: Double(minutes) * 60, chapterEnd: nil)
    }

    /// A timer that fires at the end of the chapter containing `time`, or nil when there is no
    /// chapter data (a downloaded book played offline has none).
    static func endOfChapter(chapters: [WatchChapter], at time: Double) -> StandaloneSleepTimer? {
        guard let chapter = Self.chapter(in: chapters, at: time) else { return nil }
        return StandaloneSleepTimer(option: .endOfChapter, remainingSeconds: nil, chapterEnd: chapter.end)
    }

    /// The chapter whose `[start, end)` contains `time`; the last chapter also owns its end point.
    static func chapter(in chapters: [WatchChapter], at time: Double) -> WatchChapter? {
        if let hit = chapters.first(where: { time >= $0.start && time < $0.end }) { return hit }
        if let last = chapters.last, time == last.end { return last }
        return nil
    }

    /// Advances a minutes timer by `seconds` of playback. No effect on an end-of-chapter timer.
    mutating func tick(seconds: Double) {
        guard let remaining = remainingSeconds else { return }
        remainingSeconds = max(0, remaining - seconds)
    }

    /// Seconds until it fires, given the current book position.
    func secondsLeft(currentTime: Double) -> Double {
        if let remainingSeconds { return remainingSeconds }
        return max(0, (chapterEnd ?? currentTime) - currentTime)
    }

    func isExpired(currentTime: Double) -> Bool { secondsLeft(currentTime: currentTime) <= 0 }

    /// Player volume for the fade-out: 1 until `fadeSeconds` before it fires, then a linear ramp to 0.
    func fadeVolume(currentTime: Double) -> Float {
        let left = secondsLeft(currentTime: currentTime)
        guard left < Self.fadeSeconds else { return 1 }
        return Float(max(0, left / Self.fadeSeconds))
    }

    /// "12m left" / "45s left" style hint for the UI.
    ///
    /// Critique 2026-10-06 (clarify): shared with companion mode through
    /// `WatchSleepStatus.remainingText`, so both modes read the same.
    func remainingLabel(currentTime: Double) -> String {
        WatchSleepStatus.remainingText(seconds: secondsLeft(currentTime: currentTime)) ?? String(localized: "0s left", comment: "Sleep timer remaining time, zero seconds")
    }
}

// Batch 410: `StandaloneChaptersView` and `StandaloneSleepTimerView` were here. Both modes
// now use the shared sheets in `WatchNowPlayingSheets.swift`.
