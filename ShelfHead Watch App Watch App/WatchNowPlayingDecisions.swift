import Foundation

// Critique 2026-10-06 (shape → adapt + distill): the Watch is designed as a player for
// runs. One Now Playing layout serves both modes (`WatchNowPlayingScreen`), fed by a
// mode-specific source. The decisions that layout and the root screen depend on live
// here, pure and Foundation-only, so `WatchNowPlayingDecisionsTests` can pin them
// without a paired device. Same precedent as `WatchRootTiles`.

/// Where the audio is coming out. Shown on the root hero and on Now Playing, because a
/// companion-mode tap drives the phone while a standalone tap drives this Watch, and
/// nothing on screen used to say which.
nonisolated enum WatchPlaybackSource: String, Equatable, Sendable {
    case iPhone
    case watch

    var label: String {
        switch self {
        case .iPhone: return String(localized: "iPhone", comment: "Playback device name")
        case .watch: return String(localized: "Watch", comment: "Playback device name")
        }
    }

    var systemImage: String {
        switch self {
        case .iPhone: return "iphone"
        case .watch: return "applewatch"
        }
    }

    var accessibilityLabel: String { String(localized: "Playing on \(label)", comment: "%@ is the playback device name, iPhone or Watch") }
}

/// What Now Playing's tool row and "More" button open. Batch 410 (Watch redesign, The
/// Shelf): these were pages of a four-page vertical pager, duplicated per mode
/// (`ChaptersView`/`StandaloneChaptersView` and so on). The pager took the Digital Crown
/// for paging; as sheets over one screen, they leave the Crown free for volume.
nonisolated enum WatchNowPlayingSheet: String, Identifiable, CaseIterable, Equatable, Sendable {
    case speed
    case sleep
    case chapters
    case bookmarks
    case more

    var id: String { rawValue }
}

/// The speeds the Watch's speed sheet lists. Was a fixed six-step cycle on a tap
/// (`WatchSpeedCycler`), which meant up to five taps to get back to 1×. The sheet lists
/// 0.5× to 3.0× (the phone's `PlayerViewModel.setPlaybackRate` clamp) in tenths plus the
/// quarter steps people expect, and keeps a custom rate set on the phone (1.15×) in the
/// list so the current speed is always one of the rows.
nonisolated enum WatchSpeedOptions {
    static let minimum: Double = 0.5
    static let maximum: Double = 3.0

    static let standard: [Double] = {
        var speeds = stride(from: 5, through: 30, by: 1).map { Double($0) / 10 }
        speeds.append(contentsOf: [1.25, 1.75])
        return speeds.sorted()
    }()

    /// `standard`, plus `current` when it's in range and not already listed.
    static func options(including current: Double?) -> [Double] {
        guard let current, current.isFinite, current >= minimum - 0.001, current <= maximum + 0.001,
              !standard.contains(where: { matches($0, current) }) else { return standard }
        return (standard + [current]).sorted()
    }

    /// The row that reads as selected: same rate to within rounding noise.
    static func matches(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
}

/// A chapter as the shared Chapters sheet shows it. Companion mode has
/// `WatchChapterSummary` (from the iPhone), standalone has `WatchChapter` (from the
/// server); both adapt into this.
nonisolated struct WatchChapterRow: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let start: Double
    let end: Double

    /// The chapter whose `[start, end)` contains `time`; the last chapter also owns its
    /// end point. Same rule as `StandaloneSleepTimer.chapter(in:at:)`.
    static func current(in chapters: [WatchChapterRow], at time: Double) -> WatchChapterRow? {
        if let hit = chapters.first(where: { time >= $0.start && time < $0.end }) { return hit }
        if let last = chapters.last, time == last.end { return last }
        return nil
    }
}

/// A bookmark as the shared Bookmarks sheet shows it. `isPending` is standalone only: a
/// bookmark made offline that hasn't reached the server yet.
nonisolated struct WatchBookmarkRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let time: Double
    var isPending: Bool = false
}

/// Sleep timer copy shared by companion and standalone. Companion used to round to whole
/// minutes with a floor of one ("1m left" for the last 30 seconds) while standalone
/// counted seconds under a minute. Both now read the same.
nonisolated enum WatchSleepStatus {
    /// "12m left" at a minute or more (rounded up, so 14.5 minutes reads "15m left"),
    /// "45s left" under a minute, `nil` when nothing is left.
    static func remainingText(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let wholeSeconds = Int(seconds.rounded(.up))
        if wholeSeconds >= 60 {
            return String(localized: "\(Int((seconds / 60).rounded(.up)))m left", comment: "sleep timer remaining minutes, e.g. 12m left")
        }
        return String(localized: "\(wholeSeconds)s left", comment: "sleep timer remaining seconds, e.g. 45s left")
    }

    /// Batch 410: "23m" / "45s", for Now Playing's status line where "left" truncated.
    /// Same rounding as `remainingText`.
    static func shortText(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let wholeSeconds = Int(seconds.rounded(.up))
        if wholeSeconds >= 60 {
            return String(localized: "\(Int((seconds / 60).rounded(.up)))m", comment: "duration: minutes only, e.g. 12m")
        }
        return String(localized: "\(wholeSeconds)s", comment: "sleep timer remaining seconds, short, e.g. 45s")
    }
}

/// Time readouts for Now Playing. Under Always-On the screen updates rarely, so a
/// seconds readout would sit visibly wrong; the HIG's Always On guidance is to keep the
/// layout and make updates infrequent, so the same slots show minutes instead.
nonisolated enum WatchNowPlayingTime {
    /// "1:02:03" normally; "1h 2m" under Always-On. Elapsed rounds down.
    static func elapsed(_ seconds: Double, minuteLevel: Bool) -> String {
        minuteLevel ? minutes(seconds, roundUp: false) : seconds.watchFormattedTime
    }

    /// "-1:02:03" normally; "-1h 3m" under Always-On. Remaining rounds up, so the last
    /// partial minute never reads as "0m".
    static func remaining(_ seconds: Double, minuteLevel: Bool) -> String {
        let clamped = max(seconds, 0)
        return "-" + (minuteLevel ? minutes(clamped, roundUp: true) : clamped.watchFormattedTime)
    }

    private static func minutes(_ seconds: Double, roundUp: Bool) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(roundUp ? (seconds / 60).rounded(.up) : (seconds / 60).rounded(.down))
        let hours = total / 60
        let mins = total % 60
        return hours > 0 ? String(localized: "\(hours)h \(mins)m", comment: "duration: hours and minutes, e.g. 1h 2m") : String(localized: "\(mins)m", comment: "duration: minutes only, e.g. 12m")
    }
}

/// What tapping a book in standalone mode should do. Pushing a book used to start it at
/// once, which silently cut off a different book already playing on the Watch.
nonisolated enum StandalonePlayRequest: Equatable {
    /// Nothing loaded, or a different book that's paused: play it.
    case playNow
    /// This book is already loaded: show it, don't restart it.
    case alreadyLoaded
    /// A different book is playing right now: ask first.
    case confirmReplacing(currentTitle: String)

    static func decide(requestedItemId: String, loadedItemId: String?, isLoaded: Bool,
                       isPlaying: Bool, loadedTitle: String) -> StandalonePlayRequest {
        guard isLoaded, let loadedItemId else { return .playNow }
        if loadedItemId == requestedItemId { return .alreadyLoaded }
        return isPlaying ? .confirmReplacing(currentTitle: loadedTitle) : .playNow
    }
}

/// One downloaded book as the cold-launch resume decision sees it.
nonisolated struct WatchResumeInput: Equatable, Sendable {
    let itemId: String
    let title: String
    let author: String
    /// Seconds; 0 when unknown.
    let duration: Double
    let downloadedAt: Date
    /// The book's last known position, if anything has played it. Critique 2026-10-06
    /// (harden): was this Watch's own position only, so a book the iPhone had taken to
    /// 40% read as unstarted ("Start", 0:00). `WatchShelfView` (was `WatchHomeView`) now resolves it with
    /// `WatchResumePoint.resolve(...)` from this Watch's position *and* the server's (the
    /// download manifest's, or the iPhone's snapshot), newest wins.
    let lastPosition: Double?
    /// Epoch milliseconds of that position (`WatchPendingProgressQueue.Entry.updatedAt`'s unit).
    let lastPlayedAt: Double?
}

/// What the root hero offers when this Watch has nothing loaded.
nonisolated struct WatchResumeCandidate: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// A download this Watch has played part of.
        case resume
        /// No download is part-played; the newest unstarted download instead.
        case start
    }

    let itemId: String
    let title: String
    let author: String
    /// 0...1
    let progress: Double
    let kind: Kind
    /// Critique 2026-10-06 (harden): seconds left from the resume point, so the hero can
    /// say "Resume · 4h 12m left" rather than a bare verb. 0 when the duration is unknown.
    var remainingSeconds: Double = 0

    /// The hero's status text. A resume says how much is left (when known); an unstarted
    /// download says "Start".
    var actionLabel: String {
        switch kind {
        case .resume:
            return remainingSeconds > 0 ? String(localized: "Resume \u{00B7} \(WatchShortDuration.text(remainingSeconds)) left", comment: "%@ is a short duration like 4h 12m") : String(localized: "Resume", comment: "Button/status label to resume a download in progress")
        case .start:
            return String(localized: "Start", comment: "Button/status label to start an unstarted download")
        }
    }

    /// Within this many seconds of the end counts as finished, not in progress.
    static let finishedTailSeconds: Double = 30

    /// The most recently played in-progress download; failing that, the newest download
    /// not yet started; `nil` when every download is finished or there are none.
    /// Ties on play time go to the newer download so the answer is stable.
    static func pick(from inputs: [WatchResumeInput]) -> WatchResumeCandidate? {
        func isFinished(_ input: WatchResumeInput) -> Bool {
            guard let position = input.lastPosition, input.duration > 0 else { return false }
            return input.duration - position <= finishedTailSeconds
        }
        func progress(_ input: WatchResumeInput) -> Double {
            guard let position = input.lastPosition, input.duration > 0 else { return 0 }
            return min(max(position / input.duration, 0), 1)
        }

        let inProgress = inputs.filter { ($0.lastPosition ?? 0) > 0 && !isFinished($0) }
        if let best = inProgress.max(by: { a, b in
            let at = a.lastPlayedAt ?? 0, bt = b.lastPlayedAt ?? 0
            return at == bt ? a.downloadedAt < b.downloadedAt : at < bt
        }) {
            let remaining = best.duration > 0 ? max(0, best.duration - (best.lastPosition ?? 0)) : 0
            return WatchResumeCandidate(itemId: best.itemId, title: best.title, author: best.author,
                                        progress: progress(best), kind: .resume, remainingSeconds: remaining)
        }

        let unstarted = inputs.filter { ($0.lastPosition ?? 0) <= 0 }
        if let newest = unstarted.max(by: { $0.downloadedAt < $1.downloadedAt }) {
            return WatchResumeCandidate(itemId: newest.itemId, title: newest.title, author: newest.author,
                                        progress: 0, kind: .start, remainingSeconds: max(0, newest.duration))
        }
        return nil
    }
}

/// Colour maths for the Watch palette. The Watch target can't see the phone's
/// `ContrastInk`/`AppTheme.hueHarmonizedHex` (iOS-only `Extensions.swift`), so the two
/// pieces it needs are re-derived here the same way, Foundation-only.
nonisolated enum WatchPaletteMath {
    /// DESIGN.md's VU Amber, the default accent and the fallback before a phone snapshot.
    static let defaultAccentHex = "E8A838"
    /// DESIGN.md's Finished Teal (Dark) — the anchor `finished` rotates from.
    static let finishedAnchorHex = "2FB6A8"
    /// DESIGN.md's Burnt Orange (Dark) — the anchor `alert` rotates from.
    static let alertAnchorHex = "E0612F"

    nonisolated struct RGB: Equatable, Sendable { var r: Double; var g: Double; var b: Double }

    /// Critique 2026-10-06 (colorize, third pass): the lightest dark ground text sits on —
    /// the top of the Now Playing wash (`WatchTheme.nowPlayingBackground`, #2E2114). The
    /// card (#241B12) and black are darker, so text that clears 4.5:1 here clears it there.
    static let lightestGroundHex = "2E2114"
    static let minimumTextContrast: Double = 4.5

    /// WCAG contrast ratio between two colours.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The accent lifted toward white in small steps until it clears
    /// `minimumTextContrast` on `onHex` — the least change that reads, so the hue stays
    /// recognisable. The accent unchanged when it already clears (most do, by far).
    static func readableText(accentHex: String, onHex: String) -> RGB {
        let fallback = rgb(hex: defaultAccentHex) ?? RGB(r: 1, g: 1, b: 1)
        let accent = rgb(hex: accentHex) ?? fallback
        guard let ground = rgb(hex: onHex) else { return accent }
        var mix = 0.0
        var candidate = accent
        while contrastRatio(candidate, ground) < minimumTextContrast && mix < 1 {
            mix = min(1, mix + 0.02)
            candidate = RGB(r: accent.r + (1 - accent.r) * mix,
                            g: accent.g + (1 - accent.g) * mix,
                            b: accent.b + (1 - accent.b) * mix)
        }
        return candidate
    }

    static func rgb(hex: String) -> RGB? {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
        return RGB(r: Double((value >> 16) & 0xFF) / 255,
                   g: Double((value >> 8) & 0xFF) / 255,
                   b: Double(value & 0xFF) / 255)
    }

    /// WCAG relative luminance from sRGB components in 0...1.
    static func relativeLuminance(_ c: RGB) -> Double {
        func linearize(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    /// The near-black ink the phone draws on light fills (`ContrastInk.darkInkWhiteComponent`).
    static let darkInkWhite: Double = 0.08

    /// True when the near-black ink scores a higher contrast ratio than white on `background`.
    static func prefersDarkInk(on background: RGB) -> Bool {
        let bg = relativeLuminance(background)
        let dark = relativeLuminance(RGB(r: darkInkWhite, g: darkInkWhite, b: darkInkWhite))
        return (bg + 0.05) / (dark + 0.05) >= 1.05 / (bg + 0.05)
    }

    /// Rotates `anchorHex`'s hue by however far `accentHex` sits from the default accent,
    /// keeping the anchor's saturation and brightness — the phone's F1 rule, so teal and
    /// orange keep their interval to whatever accent the user picked. An achromatic accent,
    /// or the default accent itself, returns the anchor unchanged.
    static func harmonized(anchorHex: String, accentHex: String?) -> RGB {
        guard let anchor = rgb(hex: anchorHex) else { return RGB(r: 0, g: 0, b: 0) }
        guard let accentHex, let accent = rgb(hex: accentHex), let base = rgb(hex: defaultAccentHex) else {
            return anchor
        }
        let a = hsb(accent), d = hsb(base)
        guard a.s > 0.05, d.s > 0.05 else { return anchor }
        let delta = a.h - d.h
        guard abs(delta) > 0.0001 else { return anchor }
        let anchorHSB = hsb(anchor)
        var hue = (anchorHSB.h + delta).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return rgb(h: hue, s: anchorHSB.s, b: anchorHSB.b)
    }

    static func hsb(_ c: RGB) -> (h: Double, s: Double, b: Double) {
        let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b)
        let delta = maxV - minV
        var h: Double = 0
        if delta > 0 {
            if maxV == c.r { h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == c.g { h = (c.b - c.r) / delta + 2 }
            else { h = (c.r - c.g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : delta / maxV, maxV)
    }

    static func rgb(h: Double, s: Double, b: Double) -> RGB {
        let i = Int((h * 6).rounded(.down)) % 6
        let f = h * 6 - (h * 6).rounded(.down)
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch i {
        case 0: return RGB(r: b, g: t, b: p)
        case 1: return RGB(r: q, g: b, b: p)
        case 2: return RGB(r: p, g: b, b: t)
        case 3: return RGB(r: p, g: q, b: b)
        case 4: return RGB(r: t, g: p, b: b)
        default: return RGB(r: b, g: p, b: q)
        }
    }
}

// MARK: - Batch 490 (REVIEW 2026-11-11 quick wins)

/// Batch 490 (REVIEW 2026-11-11 W8): which haptic, if any, a result plays. The Watch used
/// to play `.success` on every phone reply on top of the button's own click, so a skip
/// buzzed twice and a bookmark three times. A routine command now relies on the click
/// alone; success is kept for the outcomes a person waits on, failure everywhere.
nonisolated enum WatchFeedbackHaptic: Equatable, Sendable {
    case success
    case failure

    /// The haptic for the phone's reply to `kind`. `nil` means play nothing.
    /// `.requestSnapshot` is background traffic; `.addBookmark` is played once by the
    /// Bookmarks outcome UI (`forBookmark(_:)`), not here as well.
    /// `@MainActor` because `WatchCommandKind` (shared with the phone, in `WatchModels.swift`)
    /// takes this target's default main-actor isolation; every caller is on the main actor.
    @MainActor
    static func forReply(to kind: WatchCommandKind, ok: Bool) -> WatchFeedbackHaptic? {
        switch kind {
        case .requestSnapshot, .addBookmark:
            return nil
        default:
            break
        }
        guard ok else { return .failure }
        switch kind {
        case .markFinished, .markItemFinished, .playItem:
            return .success
        default:
            return nil
        }
    }

    /// The one haptic a bookmark add plays, from its outcome. `.saving` plays nothing
    /// (the button's own click already acknowledged the press).
    static func forBookmark(_ outcome: WatchBookmarkOutcome) -> WatchFeedbackHaptic? {
        switch outcome {
        case .saving: return nil
        case .saved, .savedOffline: return .success
        case .failed: return .failure
        }
    }
}

/// Batch 490 (REVIEW 2026-11-11 W9): Crown scrub timing. The scrub used to drop focus as
/// soon as the 350 ms seek debounce fired, so a pause mid-scrub handed the Crown back to
/// volume. Now the seek still lands after `seekDebounce`, but the Crown stays on the
/// scrubber until the row is tapped again or `releaseAfterIdle` passes with no movement.
nonisolated enum WatchCrownScrub {
    static let seekDebounce: Double = 0.35
    static let releaseAfterIdle: Double = 3

    static func nanoseconds(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
}

/// Batch 490 (REVIEW 2026-11-11 F29): the Sleep sheet's "Add 15 Minutes" row. Shown
/// only while a countdown timer is running; an end-of-chapter timer is a boundary, not
/// a countdown, so it gets no row.
nonisolated enum WatchSleepExtend {
    static let seconds: Double = 15 * 60

    /// `@MainActor` for the same reason as `WatchFeedbackHaptic.forReply`.
    @MainActor
    static func isAvailable(option: WatchSleepTimerOption?, secondsLeft: Double?) -> Bool {
        guard case .minutes = option, let secondsLeft, secondsLeft.isFinite, secondsLeft > 0 else { return false }
        return true
    }
}

/// Batch 490 (REVIEW 2026-11-11 W5): whether the standalone Now Playing page should
/// switch to a book the engine has just loaded. The page was built for one item id, so
/// a book started from elsewhere (the Shelf, Siri, auto-resume) left the page showing
/// the old one with "Play" that would restart it.
nonisolated enum StandaloneNowPlayingFollow {
    static func shouldFollow(shownItemId: String, previousLoadedItemId: String?,
                             newLoadedItemId: String?, isLoaded: Bool, isConfirming: Bool) -> Bool {
        guard isLoaded, !isConfirming, let newLoadedItemId else { return false }
        return newLoadedItemId != shownItemId && newLoadedItemId != previousLoadedItemId
    }
}

/// Batch 490 (REVIEW 2026-11-11 F29): standalone chapter skip from the system Now
/// Playing controls and AirPods. Same rules as the phone's
/// `AudioPlayerService.nextChapterTarget`/`previousChapterTarget`.
nonisolated enum WatchChapterNavigation {
    /// Previous restarts the current chapter when more than this far into it.
    static let restartThreshold: Double = 3

    /// The next chapter's start; failing that, the end of the book when it's ahead;
    /// `nil` when there's nowhere to go.
    static func nextTarget(chapterStarts: [Double], bookEnd: Double, currentTime: Double) -> Double? {
        if let next = chapterStarts.sorted().first(where: { $0 > currentTime + 0.5 }) { return next }
        return bookEnd > currentTime + 0.5 ? bookEnd : nil
    }

    /// The current chapter's start when more than `restartThreshold` into it; otherwise
    /// the previous chapter's start (0 at the first chapter).
    static func previousTarget(chapterStarts: [Double], currentTime: Double) -> Double {
        let starts = chapterStarts.sorted()
        let currentStart = starts.last(where: { $0 <= currentTime }) ?? 0
        if currentTime - currentStart > restartThreshold { return currentStart }
        return starts.last(where: { $0 < currentStart - 0.5 }) ?? 0
    }
}

/// Batch 490 (REVIEW 2026-11-11 F29): whether standalone Now Playing shows the buffering
/// ring. Only a stream can stall on the network; a local download that is briefly
/// waiting (the first frames after a seek) never shows it.
nonisolated enum StandaloneBufferingDecision {
    static func showsBuffering(isStreaming: Bool, isWaitingToPlay: Bool) -> Bool {
        isStreaming && isWaitingToPlay
    }
}

/// REVIEW 2026-11-11 W3: taking the iPhone's book onto this Watch from companion Now
/// Playing, and not pretending a vanished phone is still counting.
nonisolated enum WatchPhoneLinkDecision {
    /// The book can start on this Watch: it's downloaded, or the Watch has its own
    /// session to stream with. Same two conditions the Details screen's "Play on Watch"
    /// is built from (`WatchBookPlayOptions`, `WatchBookDetailView.hasWatchSession`).
    static func canPlayOnWatch(isDownloaded: Bool, hasWatchSession: Bool) -> Bool {
        isDownloaded || hasWatchSession
    }

    /// The iPhone has stopped answering: not reachable and its snapshot has aged past
    /// `WatchStaleness.threshold`. A reachable phone with an old snapshot (paused for a
    /// while) is only "syncing"; a phone that just dropped is still within the threshold.
    static func isOutOfRange(isReachable: Bool, isStateStale: Bool) -> Bool {
        !isReachable && isStateStale
    }

    /// The "Syncing…" pill is for a reachable phone; out of range it is replaced by the
    /// persistent out-of-range line.
    static func showsSyncingBanner(isStateStale: Bool, isOutOfRange: Bool) -> Bool {
        isStateStale && !isOutOfRange
    }

    /// Whether the persistent out-of-range line shows, and whether it carries the button.
    /// The line stays as long as the phone is out of range (no timeout); the shorter
    /// "iPhone not reachable" notice after a failed command still appears while the
    /// phone only just dropped, and goes with its timer.
    static func notice(isOutOfRange: Bool, failedCommandNotice: Bool, canPlayOnWatch: Bool) -> Notice? {
        if isOutOfRange { return Notice(isOutOfRange: true, offersPlayOnWatch: canPlayOnWatch) }
        if failedCommandNotice { return Notice(isOutOfRange: false, offersPlayOnWatch: canPlayOnWatch) }
        return nil
    }

    struct Notice: Equatable, Sendable {
        let isOutOfRange: Bool
        let offersPlayOnWatch: Bool
    }

    /// The moment the mirrored position is extrapolated to. A fresh snapshot extrapolates
    /// to `now`; a stale one freezes at the last time the phone said anything (the later
    /// of the snapshot time and any local rebase), so the time stops counting for a phone
    /// that may have stopped.
    static func extrapolationDate(now: Date, lastUpdated: Date, isStateStale: Bool) -> Date {
        guard isStateStale else { return now }
        return min(now, lastUpdated)
    }
}
