import Foundation
import Observation
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Batch 406: owns the app's two Live Activities — the sleep timer countdown and the
/// aggregate "Downloading N books" progress — on the Lock Screen and in the Dynamic Island.
/// The widget extension draws them (`ShelfHeadWidgets/ShelfHeadLiveActivities.swift`); the
/// data shapes are `SleepTimerActivityState`/`DownloadsActivityState` in
/// `Shared/SharedPlayback.swift`, the one file both targets compile.
///
/// **Observes rather than being told.** Sleep state can change from a dozen places
/// (manual arm, smart snap, "+15", shake-to-reset, Undo, bedtime auto-arm, Control Center,
/// the timer firing, `stop()`), and pause/resume and speed changes affect it too.
/// Downloads change from even more (start, adopt-on-relaunch, progress, pause, cancel,
/// fail, finish, account switch). Rather than threading a call through every one of those
/// sites, each service makes exactly one call — `observeSleepTimer(of:)` from
/// `AudioPlayerService.setSleepTimer`, `observeDownloads(of:)` from
/// `DownloadManager.ensureSessionReady()` — and from then on this follows their
/// `@Observable` state with `withObservationTracking`, re-registering after each change.
///
/// **Throttled.** Observation fires on every countdown tick and every published download
/// percent; the pure decisions below (`sleepNeedsUpdate`, `downloadsNeedsUpdate`) decide
/// whether a change is worth an ActivityKit update. A sleep countdown is a wall-clock end
/// date that `Text(timerInterval:)` counts down by itself, so it only needs an update when
/// that date actually moves (extend, reset, seek, speed change, pause/resume).
///
/// **Starting needs the foreground.** `Activity.request` only works while the app is in
/// the foreground (ActivityKit `Activity` documentation), so a timer armed from CarPlay
/// or the bedtime window while backgrounded can't start one; the
/// `didBecomeActiveNotification` re-evaluation below starts it the next time the app is
/// opened. Updating and ending work from the background. The exception (Batch 495, Y3) is
/// a `LiveActivityIntent`: Siri's Set Sleep Timer and the Control Centre toggle arm inside
/// `allowingIntentStart(_:)`, so their countdown starts at once.
@MainActor
final class LiveActivityController {
    // Same `nonisolated static let shared` + `nonisolated init()` shape as
    // `AudioPlayerService.shared`/`DownloadManager.shared` (see CRIT-3 step 3 there).
    nonisolated static let shared = LiveActivityController()
    nonisolated private init() {}

    /// Opt-out switch, read from standard defaults; a missing key means on. HIG "Live
    /// Activities": "make it easy for people to turn them off in your app". The Settings
    /// toggle that writes this key belongs to `SettingsStore`/Settings (not this file).
    nonisolated static let enabledDefaultsKey = "settings_liveActivitiesEnabled"

    private var isEnabledByUser: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// Re-applies the opt-out (and everything else) now — call after the Settings toggle
    /// for `enabledDefaultsKey` changes, so switching it off ends a running activity at
    /// once instead of on the next timer or download change.
    func refresh() {
        evaluateSleep()
        evaluateDownloads(force: true)
    }

    // MARK: - Pure decisions (unit-tested in LiveActivityControllerTests)

    /// Smallest real playback speed the math will divide by; the app's range is 0.5×–3×,
    /// so this only guards against a zero/negative rate from a not-yet-ready player.
    nonisolated static let minimumRate: Double = 0.1

    /// How far a sleep timer's wall-clock end may drift before the activity is updated.
    /// Countdown ticks and the 0.5 s time observer move the computed end by well under a
    /// second; anything the listener did (extend, seek, speed) moves it by far more.
    nonisolated static let sleepEndTolerance: TimeInterval = 5

    /// Wall-clock seconds for `mediaSeconds` of book audio at `rate`. Chapter-based
    /// timers (end of chapter, +N chapters, a smart-snapped countdown, end of book) are
    /// measured in book time, which plays `rate` times faster than the clock.
    nonisolated static func wallClockSeconds(mediaSeconds: TimeInterval, rate: Double) -> TimeInterval {
        max(mediaSeconds, 0) / max(rate, minimumRate)
    }

    /// What the sleep activity should show, or nil when no activity should exist (no
    /// timer, or nothing left to count).
    ///
    /// - `remaining` is `AudioPlayerService.sleepTimerRemaining`: wall seconds for a plain
    ///   countdown, book seconds when `hasMediaTarget` (a chapter/snap target).
    /// - End of book has no remaining figure of its own (`-1`); it counts down to
    ///   `duration - currentTime` of book time.
    /// - Paused shows a frozen figure: the countdown doesn't tick and the book doesn't
    ///   move while paused (`setSleepTimer`'s `guard self.isPlaying`), so a running clock
    ///   would be wrong.
    nonisolated static func sleepState(
        option: SleepTimerOption, remaining: TimeInterval, hasMediaTarget: Bool,
        isPlaying: Bool, rate: Double, currentTime: Double, duration: Double,
        title: String, now: Date
    ) -> SleepTimerActivityState? {
        let kind: SleepTimerActivityState.Kind
        let wall: TimeInterval
        switch option {
        case .off:
            return nil
        case .minutes:
            kind = .countdown
            wall = hasMediaTarget ? wallClockSeconds(mediaSeconds: remaining, rate: rate) : remaining
        case .endOfChapter, .chapters:
            kind = .chapter
            wall = wallClockSeconds(mediaSeconds: remaining, rate: rate)
        case .endOfBook:
            kind = .endOfBook
            wall = wallClockSeconds(mediaSeconds: duration - currentTime, rate: rate)
        }
        guard wall > 0 else { return nil }
        return SleepTimerActivityState(
            kind: kind, bookTitle: title,
            endDate: isPlaying ? now.addingTimeInterval(wall) : nil,
            pausedRemaining: wall, isPaused: !isPlaying)
    }

    /// Whether `next` differs from what the activity already shows by enough to spend an
    /// update on. Labels and play state always count; times only past the tolerance.
    nonisolated static func sleepNeedsUpdate(
        previous: SleepTimerActivityState?, next: SleepTimerActivityState,
        tolerance: TimeInterval = sleepEndTolerance
    ) -> Bool {
        guard let previous else { return true }
        if previous.kind != next.kind || previous.bookTitle != next.bookTitle
            || previous.isPaused != next.isPaused {
            return true
        }
        switch (previous.endDate, next.endDate) {
        case let (old?, new?):
            return abs(new.timeIntervalSince(old)) >= tolerance
        case (nil, nil):
            return abs(next.pausedRemaining - previous.pausedRemaining) >= tolerance
        default:
            return true
        }
    }

    /// One in-flight book, as the aggregate sees it.
    struct DownloadSample: Equatable, Sendable {
        var progress: Double
        var isPaused: Bool
    }

    /// The downloads activity's content for this run, or nil when there should be none.
    ///
    /// - Something moving → `.downloading`, fraction averaged over every book in the run,
    ///   finished ones counting as complete (so the bar never jumps backwards when a book
    ///   finishes and leaves the active set).
    /// - Everything left is paused → nil. A paused queue isn't a live task, and the
    ///   activity would otherwise sit on the Lock Screen for up to eight hours.
    /// - Nothing left → `.finished` if anything was saved, `.failed` if everything failed,
    ///   nil if the run was simply cancelled.
    nonisolated static func downloadsState(
        active: [DownloadSample], finishedCount: Int, failedCount: Int, singleTitle: String?
    ) -> DownloadsActivityState? {
        if active.contains(where: { !$0.isPaused }) {
            let total = Double(active.count + finishedCount)
            let sum = active.reduce(0) { $0 + min(max($1.progress, 0), 1) } + Double(finishedCount)
            return DownloadsActivityState(
                phase: .downloading, activeCount: active.count,
                fraction: total > 0 ? min(sum / total, 1) : 0,
                finishedCount: finishedCount, failedCount: failedCount,
                singleTitle: active.count == 1 ? singleTitle : nil)
        }
        guard active.isEmpty else { return nil }
        if finishedCount > 0 {
            return DownloadsActivityState(
                phase: .finished, activeCount: 0, fraction: 1,
                finishedCount: finishedCount, failedCount: failedCount,
                singleTitle: finishedCount == 1 ? singleTitle : nil)
        }
        if failedCount > 0 {
            return DownloadsActivityState(
                phase: .failed, activeCount: 0, fraction: 0,
                finishedCount: 0, failedCount: failedCount,
                singleTitle: failedCount == 1 ? singleTitle : nil)
        }
        return nil
    }

    /// Progress steps that always earn an update, and the minimum spacing for smaller ones.
    nonisolated static let downloadsFractionStep: Double = 0.05
    nonisolated static let downloadsMinimumInterval: TimeInterval = 3

    /// Whether to push `next` over `previous`: any change of phase, count or title at
    /// once; progress on every ~5% step, or on any whole-percent change once
    /// `downloadsMinimumInterval` has passed since the last update.
    nonisolated static func downloadsNeedsUpdate(
        previous: DownloadsActivityState?, next: DownloadsActivityState,
        lastUpdateAt: Date?, now: Date
    ) -> Bool {
        guard let previous else { return true }
        if previous.phase != next.phase || previous.activeCount != next.activeCount
            || previous.finishedCount != next.finishedCount || previous.failedCount != next.failedCount
            || previous.singleTitle != next.singleTitle {
            return true
        }
        if abs(next.fraction - previous.fraction) >= downloadsFractionStep { return true }
        guard Int(next.fraction * 100) != Int(previous.fraction * 100) else { return false }
        guard let lastUpdateAt else { return true }
        return now.timeIntervalSince(lastUpdateAt) >= downloadsMinimumInterval
    }

    // MARK: - Bootstrap

    private var didBootstrap = false
    private var foregroundObserver: (any NSObjectProtocol)?

    /// One-time setup on the first hook call: end activities a previous process left
    /// behind (a crash or force-quit can't end its own; the timer and download run they
    /// described are gone with it — Apple's "Displaying live data with Live Activities"
    /// recommends exactly this check on launch), and re-evaluate on every return to the
    /// foreground, the only time a pending activity can start.
    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        #if canImport(ActivityKit)
        let orphanedSleep = Activity<SleepTimerActivityAttributes>.activities
        let orphanedDownloads = Activity<DownloadsActivityAttributes>.activities
        if !orphanedSleep.isEmpty || !orphanedDownloads.isEmpty {
            Task {
                for activity in orphanedSleep { await activity.end(nil, dismissalPolicy: .immediate) }
                for activity in orphanedDownloads { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
        #endif
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                LiveActivityController.shared.lastRefusedRequestAt = [:]
                LiveActivityController.shared.evaluateSleep()
                LiveActivityController.shared.evaluateDownloads(force: true)
            }
        }
    }

    /// After a refused request (Live Activities switched off for the app, the system's
    /// limit reached), don't retry on every countdown tick or progress change; the next
    /// try is after this long or on the next return to the foreground.
    nonisolated static let requestRetryInterval: TimeInterval = 60
    private var lastRefusedRequestAt: [String: Date] = [:]

    /// Batch 495 (REVIEW 2026-11-11 Y3): > 0 while code running inside a `LiveActivityIntent`'s
    /// `perform()` (Siri "Set Sleep Timer", the Control Centre sleep-timer toggle) changes state.
    /// ActivityKit lets such an intent start a Live Activity with the app in the background
    /// (`Activity.request(attributes:content:pushType:)`, `LiveActivityIntent` docs).
    private var intentStartDepth = 0

    /// Runs `body` (synchronously) with background starts allowed. Only call it from a path
    /// that a `LiveActivityIntent`'s `perform()` is waiting on.
    func allowingIntentStart(_ body: () -> Void) {
        intentStartDepth += 1
        defer { intentStartDepth -= 1 }
        body()
    }

    /// Batch 495 (Y3): whether to attempt `Activity.request` now. Inside a `LiveActivityIntent`
    /// the listener just asked for this, so neither the background rule nor the retry
    /// throttle applies; otherwise the app must not be in the background, and a recent
    /// refusal holds off retries for `retryInterval`.
    nonisolated static func mayRequestActivity(isInBackground: Bool, insideLiveActivityIntent: Bool,
                                               lastRefusedAt: Date?, now: Date,
                                               retryInterval: TimeInterval = requestRetryInterval) -> Bool {
        if insideLiveActivityIntent { return true }
        guard !isInBackground else { return false }
        if let lastRefusedAt, now.timeIntervalSince(lastRefusedAt) < retryInterval { return false }
        return true
    }

    /// Whether a request for the activity `kind` is worth attempting now.
    private func canStartActivity(_ kind: String) -> Bool {
        Self.mayRequestActivity(isInBackground: UIApplication.shared.applicationState == .background,
                                insideLiveActivityIntent: intentStartDepth > 0,
                                lastRefusedAt: lastRefusedRequestAt[kind], now: Date())
    }

    // MARK: - Sleep timer

    private weak var player: AudioPlayerService?
    private var lastSleepState: SleepTimerActivityState?
    /// Set when the person swiped the activity away while the timer was still armed, so
    /// the next tick doesn't put it straight back; cleared when the timer is next set.
    private var sleepDismissedByUser = false
    #if canImport(ActivityKit)
    private var sleepActivity: Activity<SleepTimerActivityAttributes>?
    #endif

    /// The one hook `AudioPlayerService.setSleepTimer` calls. Idempotent: the first call
    /// starts following the player; every call re-evaluates immediately.
    func observeSleepTimer(of player: AudioPlayerService) {
        bootstrapIfNeeded()
        if self.player !== player {
            self.player = player
            trackSleep()
        }
        // A deliberate (re-)arm shows the activity again even if the last one was swiped
        // away: drop the reference to a dismissed one so it isn't read as a new dismissal.
        #if canImport(ActivityKit)
        if let activity = sleepActivity, activity.activityState != .active, activity.activityState != .stale {
            sleepActivity = nil
        }
        #endif
        sleepDismissedByUser = false
        evaluateSleep()
    }

    /// Reads exactly the properties the activity depends on inside an observation scope,
    /// so a change to any of them schedules one re-evaluation. With no timer armed only
    /// `sleepTimerOption` is read, so ordinary playback ticks don't wake this up.
    private func trackSleep() {
        guard let player else { return }
        withObservationTracking {
            _ = sleepInputs(of: player)
        } onChange: {
            Task { @MainActor in
                LiveActivityController.shared.evaluateSleep()
                LiveActivityController.shared.trackSleep()
            }
        }
    }

    private func sleepInputs(of player: AudioPlayerService) -> SleepTimerActivityState? {
        let option = player.sleepTimerOption
        guard option != .off else { return nil }
        let needsBookTime = option == .endOfBook
        return Self.sleepState(
            option: option,
            remaining: player.sleepTimerRemaining,
            hasMediaTarget: player.sleepTargetTime != nil,
            isPlaying: player.isPlaying,
            rate: Double(player.playbackRate),
            currentTime: needsBookTime ? player.currentTime : 0,
            duration: needsBookTime ? player.duration : 0,
            title: SharedPlayback.normalizedTitle(player.currentSession?.libraryItem?.title ?? ""),
            now: Date())
    }

    private func evaluateSleep() {
        guard let player else { return }
        guard isEnabledByUser, let next = sleepInputs(of: player) else {
            endSleep()
            return
        }
        #if canImport(ActivityKit)
        if let activity = sleepActivity, activity.activityState == .active || activity.activityState == .stale {
            guard Self.sleepNeedsUpdate(previous: lastSleepState, next: next) else { return }
            lastSleepState = next
            let content = Self.sleepContent(next)
            Task { await activity.update(content) }
        } else {
            if sleepActivity != nil {
                sleepActivity = nil
                sleepDismissedByUser = true
            }
            guard !sleepDismissedByUser, canStartActivity("sleep") else { return }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                lastRefusedRequestAt["sleep"] = Date()
                return
            }
            do {
                sleepActivity = try Activity.request(
                    attributes: SleepTimerActivityAttributes(), content: Self.sleepContent(next), pushType: nil)
                lastSleepState = next
            } catch {
                lastRefusedRequestAt["sleep"] = Date()
                ShelfLog.info(.playback, "Sleep timer Live Activity not started: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func endSleep() {
        lastSleepState = nil
        sleepDismissedByUser = false
        #if canImport(ActivityKit)
        guard let activity = sleepActivity else { return }
        sleepActivity = nil
        // Immediate: the timer is over (fired, turned off, or playback stopped) and a
        // leftover "Sleep timer" card would only be misleading. HIG "Live Activities":
        // "Always end a Live Activity immediately when the task or event ends".
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    #if canImport(ActivityKit)
    /// Stale a little after the timer should have fired: if the app died mid-countdown
    /// nothing will end the activity, and the widget greys the countdown out instead of
    /// sitting on 0:00. A paused timer has no end to be stale after.
    private static func sleepContent(_ state: SleepTimerActivityState) -> ActivityContent<SleepTimerActivityState> {
        ActivityContent(state: state, staleDate: state.endDate?.addingTimeInterval(60), relevanceScore: 100)
    }
    #endif

    // MARK: - Downloads

    private weak var downloads: DownloadManager?
    private var lastDownloadsState: DownloadsActivityState?
    private var lastDownloadsUpdateAt: Date?
    /// Every book that has been in flight during the current run (since the activity
    /// last ended), and how the ones that left the active set ended up.
    private var runItemIds: Set<String> = []
    private var runFinished: Set<String> = []
    private var runFailed: Set<String> = []
    private var runTitles: [String: String] = [:]
    private var trailingDownloadsEvaluation: Task<Void, Never>?
    /// Same as `sleepDismissedByUser`, for the rest of the current run.
    private var downloadsDismissedByUser = false
    #if canImport(ActivityKit)
    private var downloadsActivity: Activity<DownloadsActivityAttributes>?
    #endif

    /// The one hook `DownloadManager.ensureSessionReady()` calls (app launch, background
    /// relaunch, background refresh). Idempotent.
    func observeDownloads(of manager: DownloadManager) {
        bootstrapIfNeeded()
        if downloads !== manager {
            downloads = manager
            trackDownloads()
        }
        evaluateDownloads(force: false)
    }

    private func trackDownloads() {
        guard let downloads else { return }
        withObservationTracking {
            for task in downloads.activeDownloads.values {
                _ = task.progress
                _ = task.isPaused
            }
            _ = downloads.downloadedItems
            _ = downloads.failedDownloads
        } onChange: {
            Task { @MainActor in
                LiveActivityController.shared.evaluateDownloads(force: false)
                LiveActivityController.shared.trackDownloads()
            }
        }
    }

    /// Folds the manager's current state into this run's bookkeeping and returns the
    /// aggregate. Repairs are left out: they're a Diagnostics action on a book that's
    /// already downloaded, and a failed repair would otherwise read as "Downloaded".
    private func currentDownloadsState(of manager: DownloadManager) -> DownloadsActivityState? {
        let active = manager.activeDownloads.values.filter { !$0.isRepair }
        for task in active {
            runItemIds.insert(task.id)
            runTitles[task.id] = SharedPlayback.normalizedTitle(task.title)
        }
        let activeIds = Set(active.map(\.id))
        for id in runItemIds.subtracting(activeIds) where !runFinished.contains(id) && !runFailed.contains(id) {
            if manager.downloadedItems.contains(id) {
                runFinished.insert(id)
            } else if manager.failedDownloads[id] != nil {
                runFailed.insert(id)
            } else {
                // Cancelled or removed: not part of the run's outcome at all.
                runItemIds.remove(id)
            }
        }
        let singleId: String? = {
            if active.count == 1 { return active.first?.id }
            if active.isEmpty, runFinished.count == 1 { return runFinished.first }
            if active.isEmpty, runFinished.isEmpty, runFailed.count == 1 { return runFailed.first }
            return nil
        }()
        return Self.downloadsState(
            active: active.map { DownloadSample(progress: $0.progress, isPaused: $0.isPaused) },
            finishedCount: runFinished.count, failedCount: runFailed.count,
            singleTitle: singleId.flatMap { runTitles[$0] })
    }

    private func resetRun() {
        runItemIds = []
        runFinished = []
        runFailed = []
        runTitles = [:]
        lastDownloadsState = nil
        lastDownloadsUpdateAt = nil
        trailingDownloadsEvaluation?.cancel()
        trailingDownloadsEvaluation = nil
        downloadsDismissedByUser = false
    }

    /// `force` skips the throttle — used on return to the foreground, so the content
    /// (and its stale date) is refreshed even when the numbers happen not to have moved.
    private func evaluateDownloads(force: Bool) {
        guard let downloads else { return }
        let next = isEnabledByUser ? currentDownloadsState(of: downloads) : nil
        guard let next else {
            endDownloads(final: nil)
            return
        }
        if next.phase != .downloading {
            endDownloads(final: next)
            return
        }
        #if canImport(ActivityKit)
        let now = Date()
        if let activity = downloadsActivity, activity.activityState == .active || activity.activityState == .stale {
            guard force || Self.downloadsNeedsUpdate(
                previous: lastDownloadsState, next: next, lastUpdateAt: lastDownloadsUpdateAt, now: now
            ) else {
                scheduleTrailingDownloadsEvaluation()
                return
            }
            lastDownloadsState = next
            lastDownloadsUpdateAt = now
            let content = Self.downloadsContent(next, now: now)
            Task { await activity.update(content) }
        } else {
            if downloadsActivity != nil {
                downloadsActivity = nil
                downloadsDismissedByUser = true
            }
            guard !downloadsDismissedByUser, canStartActivity("downloads") else { return }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                lastRefusedRequestAt["downloads"] = Date()
                return
            }
            do {
                downloadsActivity = try Activity.request(
                    attributes: DownloadsActivityAttributes(),
                    content: Self.downloadsContent(next, now: now), pushType: nil)
                lastDownloadsState = next
                lastDownloadsUpdateAt = now
            } catch {
                lastRefusedRequestAt["downloads"] = Date()
                ShelfLog.info(.downloads, "Downloads Live Activity not started: \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// A throttled change with no further progress behind it would otherwise never be
    /// shown (e.g. the last tick before a stall); re-check once the interval has passed.
    private func scheduleTrailingDownloadsEvaluation() {
        guard trailingDownloadsEvaluation == nil else { return }
        trailingDownloadsEvaluation = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.downloadsMinimumInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            LiveActivityController.shared.trailingDownloadsEvaluation = nil
            LiveActivityController.shared.evaluateDownloads(force: false)
        }
    }

    /// Ends the run. A drained queue gets its summary briefly — "Downloaded" for five
    /// minutes, a failure for fifteen since it's something to act on in the app (HIG
    /// "Live Activities": a custom dismissal time proportional to the activity; its
    /// 15–30 minute guide is for summaries people return to, which a download isn't).
    /// Cancelled, paused or switched-off runs leave immediately.
    private func endDownloads(final: DownloadsActivityState?) {
        resetRun()
        #if canImport(ActivityKit)
        guard let activity = downloadsActivity else { return }
        downloadsActivity = nil
        let now = Date()
        let policy: ActivityUIDismissalPolicy
        let content: ActivityContent<DownloadsActivityState>?
        if let final {
            policy = .after(now.addingTimeInterval(final.phase == .failed ? 15 * 60 : 5 * 60))
            content = ActivityContent(state: final, staleDate: nil)
        } else {
            policy = .immediate
            content = nil
        }
        Task { await activity.end(content, dismissalPolicy: policy) }
        #endif
    }

    #if canImport(ActivityKit)
    /// The app gets no progress callbacks while suspended (background `URLSession`
    /// transfers carry on in the system daemon and only wake the app on completion), so
    /// the figure can silently freeze. Two minutes without an update marks it stale and
    /// the widget says so instead of presenting an old percentage as live.
    private static func downloadsContent(_ state: DownloadsActivityState, now: Date) -> ActivityContent<DownloadsActivityState> {
        ActivityContent(state: state, staleDate: now.addingTimeInterval(120), relevanceScore: 50)
    }
    #endif
}
