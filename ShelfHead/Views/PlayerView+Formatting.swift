import SwiftUI

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
/// every helper below keeps its exact name, signature and behaviour, which matters here
/// more than anywhere else in the split: `FormattingAndModelsTests` and
/// `PlayerScrubberFormattingTests` call all four of these directly as `PlayerView.<name>`.
///
/// This file is the player's pure, view-free helpers — the chapter orientation label, the
/// spoken (VoiceOver) duration formatter, the scrubber's spoken value, and the scrubber's
/// chapter-boundary tick positions. `PlayerFold` (end of file) is the fold reading the full
/// player and Driving Mode share on iPhone Duo.
extension PlayerView {
    /// G3 (REVIEW_2026-09-04_UI.md): this caption read "Chapter 65 of 82" directly under
    /// a chapter title that said "63. Something Incredibly Questionable" — the title
    /// carries the author's numbering, the caption carried the array index, and the
    /// intro/credits tracks most books ship with make the two disagree. Two numbering
    /// schemes a line apart read as a bug. A remaining count gives the same orientation
    /// with no second number for the title to argue with. `nil` when there's nothing
    /// to say (no chapters, or an index outside the list).
    ///
    /// P-2 (REVIEW_2026-09-14_DESIGN.md): no longer *drawn* — the player carried five
    /// separate time/position readouts at once, and this was the weakest of them (the
    /// WHOLE BOOK rail directly below says the same thing with a position rather than a
    /// count). It is still the chapter caption's VoiceOver label, where it costs no screen
    /// real estate and genuinely adds orientation a sighted user gets from the rail.
    static func chapterOrientationLabel(index: Int, count: Int) -> String? {
        guard count > 0, index >= 0, index < count else { return nil }
        let remaining = count - index - 1
        switch remaining {
        case 0: return String(localized: "Last chapter", comment: "VoiceOver label for the chapter caption when the current chapter is the final one")
        case 1: return String(localized: "1 chapter left", comment: "VoiceOver label for the chapter caption: exactly one chapter remains after this one")
        default: return String(localized: "\(remaining) chapters left", comment: "VoiceOver label for the chapter caption. %lld is the number of chapters remaining after this one")
        }
    }

    /// P-3 (REVIEW_2026-09-14_DESIGN.md): a playback time spoken the way a person would
    /// say it — "12 minutes 44 seconds", "1 hour 5 minutes". VoiceOver reads the displayed
    /// "12:44" as two numbers with a colon between them, so the scrubber's value and the
    /// counters beneath it were announced as coordinates rather than as durations.
    ///
    /// Deliberately hand-built rather than `DateComponentsFormatter(.spellOut)`: the whole
    /// app's durations already go through `formattedDuration`/`formattedTime`'s own
    /// arithmetic (including `safeSeconds`, which is what stops a hostile or broken server
    /// handing `Int(_:)` a NaN and crashing the render), and this keeps that one source of
    /// clamping. Zero-valued components are dropped, except when everything is zero.
    ///
    /// Unit words go through `String(localized:)` (singular and plural as separate keys);
    /// the joining space between components is not localised.
    static func spokenTime(_ seconds: Double) -> String {
        let total = seconds.safeSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(hours == 1 ? String(localized: "1 hour", comment: "Spoken duration component: one hour")
                                    : String(localized: "\(hours) hours", comment: "Spoken duration component. %lld is a count of hours (not 1)"))
        }
        if minutes > 0 {
            parts.append(minutes == 1 ? String(localized: "1 minute", comment: "Spoken duration component: one minute")
                                      : String(localized: "\(minutes) minutes", comment: "Spoken duration component. %lld is a count of minutes (not 1)"))
        }
        // Seconds are dropped once we're past an hour: "3 hours 2 minutes 17 seconds" is
        // more to listen through than it is to act on, and the scrubber can't be placed
        // to that precision by swiping anyway.
        if secs > 0 && hours == 0 {
            parts.append(secs == 1 ? String(localized: "1 second", comment: "Spoken duration component: one second")
                                   : String(localized: "\(secs) seconds", comment: "Spoken duration component. %lld is a count of seconds (not 1)"))
        }
        if parts.isEmpty { return String(localized: "0 seconds", comment: "Spoken duration when the time is zero") }
        return parts.joined(separator: " ")
    }

    /// P-3: the scrubber's whole spoken value — "12 minutes 44 seconds, 2 minutes 28
    /// seconds remaining". Both halves are the same two figures the counters under the
    /// scrubber render, so the two can't disagree.
    static func scrubberAccessibilityValue(elapsed: Double, remaining: Double) -> String {
        String(localized: "\(spokenTime(elapsed)), \(spokenTime(remaining)) remaining",
               comment: "VoiceOver value of the scrubber. First %@ is the spoken elapsed time, second %@ the spoken time remaining")
    }

    /// Cleanup pass (Batch N-5 redundancy close-out): the bottom toolbar's speed column
    /// (`PlayerView+BottomRegion.swift`) and `SpeedSheet`'s own preset/readout labels
    /// (`PlayerView+Sheets.swift`) each independently formatted a playback rate the same
    /// way — a whole number renders as "1×"/"2×"/"3×", anything else with up to two
    /// fraction digits ("1.5×", "1.75×"). One shared helper instead of two copies that
    /// could quietly drift apart.
    static func speedLabel(_ rate: Double) -> String {
        if rate == rate.rounded() { return "\(Int(rate))×" }
        return "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// P-1 (REVIEW_2026-09-14_DESIGN.md): chapter-boundary tick positions for
    /// `TapeScrubber`, as 0...1 fractions of the `rangeStart...rangeEnd` window the
    /// scrubber currently represents.
    ///
    /// Only *interior* boundaries are returned — a boundary sitting exactly on either end
    /// of the window is the rail's own end cap, not a mark within it. That has a real
    /// consequence worth stating plainly rather than burying: while a book has chapters
    /// the scrubber is bound to the current chapter (see `PlayerProgressSection`), so its
    /// window is one chapter and there is nothing inside it to mark — this returns empty,
    /// and the rail is just a rail. Ticks appear in the whole-book case, which is a book
    /// whose chapter list didn't resolve to a current chapter. The whole-book tick marks a
    /// chaptered book *does* get are `BookPositionRail`'s, right below the scrubber; this
    /// exists so the scrubber draws real marks whenever it has any, instead of the
    /// fabricated waveform it used to draw always.
    ///
    /// Above 80 interior boundaries this returns empty rather than a solid smear of
    /// ticks — the same density cap, and the same reasoning, as `BookPositionRail`.
    static func scrubberChapterTicks(chapters: [Chapter], rangeStart: Double, rangeEnd: Double) -> [Double] {
        let span = rangeEnd - rangeStart
        guard span > 0, span.isFinite, rangeStart.isFinite, chapters.count > 1 else { return [] }
        var ticks: [Double] = []
        for chapter in chapters {
            let fraction = (chapter.start - rangeStart) / span
            guard fraction.isFinite, fraction > 0.001, fraction < 0.999 else { continue }
            ticks.append(fraction)
        }
        return ticks.count > 80 ? [] : ticks
    }

    // MARK: - Critique 2026-10-05 (clarify)

    /// What the drag-handle strip says about the transport. It used to read "CONTINUE
    /// LISTENING" for the whole session of any book with earlier progress (most
    /// audiobooks), borrowing Home's call to action for what is the close strip, and it
    /// never said anything during a long stall.
    enum HeaderStatus: Equatable {
        case nowPlaying, loading, waitingForServer, paused

        var text: String {
            switch self {
            case .nowPlaying:       return String(localized: "NOW PLAYING", comment: "Player drag-handle status, shown in capitals")
            case .loading:          return String(localized: "LOADING", comment: "Player drag-handle status while audio is buffering, shown in capitals")
            case .waitingForServer: return String(localized: "WAITING FOR SERVER", comment: "Player drag-handle status when a stream has stalled, shown in capitals")
            case .paused:           return String(localized: "PAUSED", comment: "Player drag-handle status when playback is paused, shown in capitals")
            }
        }

        /// Amber marks live state only (DESIGN.md, the One Light Rule); paused is muted.
        var isLive: Bool { self != .paused }

        /// Sentence case for VoiceOver (the visible word is tracked caps).
        var spokenText: String {
            switch self {
            case .nowPlaying:       return String(localized: "Now playing", comment: "VoiceOver status of the player header")
            case .loading:          return String(localized: "Loading", comment: "VoiceOver status of the player header while audio is buffering")
            case .waitingForServer: return String(localized: "Waiting for your server", comment: "VoiceOver status when a stream has stalled")
            case .paused:           return String(localized: "Paused", comment: "VoiceOver status of the player header when playback is paused")
            }
        }
    }

    /// `stalled` is true once the transport has been waiting for longer than the strip's
    /// patience (10 s, see `PlayerView+Header`). Only a streamed book blames the server; a
    /// downloaded one that stalls just says it's loading.
    static func headerStatus(isPlaying: Bool, isWaiting: Bool, stalled: Bool, isStreaming: Bool) -> HeaderStatus {
        if isWaiting { return stalled && isStreaming ? .waitingForServer : .loading }
        return isPlaying ? .nowPlaying : .paused
    }

    /// The "finishes …" clause of the time-left line, or `nil` to leave it off. The old
    /// line said "finishes 6:11 am" with 15 hours to go and no day, and kept promising a
    /// finish time while a sleep timer was going to stop playback first.
    ///
    /// - Same calendar day: "9:40 PM".
    /// - Next day and no more than 12 hours away: "tomorrow 1:10 AM".
    /// - Further out: `nil`, because an estimate that assumes non-stop listening for half a
    ///   day isn't a time anyone will finish at.
    /// - A sleep timer other than end-of-book is armed: `nil`, because playback stops first.
    static func finishClockPhrase(finish: Date, now: Date, sleepTimer: SleepTimerOption,
                                  calendar: Calendar = .current) -> String? {
        switch sleepTimer {
        case .off, .endOfBook: break
        default: return nil
        }
        let interval = finish.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        let clock = finish.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(finish, inSameDayAs: now) { return clock }
        guard interval <= 12 * 3600,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              calendar.isDate(finish, inSameDayAs: tomorrow) else { return nil }
        return String(localized: "tomorrow \(clock)", comment: "Finish-time phrase for a finish on the next day. %@ is a clock time such as 1:10 AM")
    }

    /// Driving Mode's status line (critique 2026-10-05, second run). Driving Mode is a
    /// full-screen cover above the app's connectivity banner and toasts, so it has to say
    /// for itself what a driver needs at a glance: offline, server unreachable, or a stall.
    /// `nil` when everything is fine — the line only appears when there's news.
    ///
    /// Critique 2026-10-05 (third run): a failed start is shown here first, because the
    /// app's alert can't present over this full-screen cover. "Loading" only appears once
    /// buffering has lasted 2 s (`showsLoading`) — every ⟳30 on a stream buffers briefly,
    /// and flashing the alarm colour on each skip read as a fault.
    static func drivingStatusLine(reachability: ReachabilityStore.Status, header: HeaderStatus,
                                  isStreaming: Bool, startFailure: String? = nil,
                                  showsLoading: Bool = true) -> String? {
        if let startFailure { return startFailure }
        // Critique 2026-10-06 (clarify): one shared wording with the banner.
        if let line = ConnectivityCopy.message(for: reachability, usingDownload: !isStreaming) { return line }
        switch header {
        case .waitingForServer: return String(localized: "Waiting for your server", comment: "Driving Mode status line when a stream has stalled")
        case .loading:          return showsLoading ? String(localized: "Loading", comment: "Driving Mode status line while audio is buffering") : nil
        case .nowPlaying, .paused: return nil
        }
    }

    /// Critique 2026-10-06 (clarify): true when `drivingStatusLine`'s connectivity line is the
    /// calm "using your download" one, which shows in muted text rather than alarm orange.
    static func drivingStatusIsQuiet(reachability: ReachabilityStore.Status, isStreaming: Bool,
                                     startFailure: String? = nil) -> Bool {
        startFailure == nil && reachability != .ok && !isStreaming
    }

    /// A chapter title as the player shows it. Many books ship chapter titles that are only
    /// a number ("002"); on its own beside a chevron that read as a stray code. Purely
    /// numeric titles become "Chapter 2"; anything else is shown as-is.
    static func displayChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let n = Int(trimmed) else { return title }
        return String(localized: "Chapter \(String(n))", comment: "Display title for a chapter whose title is only a number. %@ is the chapter number (an identifier, never digit-grouped: Chapter 1984)")
    }

    /// The "Jump back" chip's text, in the same scheme as the counters beside it
    /// (critique 2026-10-05, second run: it used to print whole-book time, so in chapter 30
    /// it said "Jump back to 7:42:10" next to "12:44 / −8:03"). Within the current chapter
    /// it's the chapter-relative time; from another chapter it names that chapter.
    ///
    /// Critique 2026-10-05 (third run): this used to say "chapter \(index + 1)" — the
    /// array position, which an opening-credits track throws off by one against the
    /// author's own numbering. That was the exact two-numbering-schemes contradiction G3
    /// removed in September. It now uses the same `displayChapterTitle` as the caption, the
    /// chapter list and the bookmarks. `verb` is "Return to" for the redo offer.
    static func jumpBackLabel(undoTime: Double, chapters: [Chapter], currentChapterId: Int?,
                              verb: String = String(localized: "Jump back to", comment: "Undo-chip verb before a time or chapter, e.g. 'Jump back to 12:44'")) -> String {
        guard let chapter = chapters.last(where: { $0.start <= undoTime }) else {
            return "\(verb) \(undoTime.formattedTime)"
        }
        let relative = (undoTime - chapter.start).formattedTime
        if chapter.id == currentChapterId { return "\(verb) \(relative)" }
        return "\(verb) \(displayChapterTitle(chapter.title)) · \(relative)"
    }

    /// The compact "Jump back" text when the full chip doesn't fit beside the sleep chip:
    /// just the chapter-relative time ("0:29"), next to the direction arrow.
    static func jumpBackCompactLabel(undoTime: Double, chapters: [Chapter]) -> String {
        guard let chapter = chapters.last(where: { $0.start <= undoTime }) else { return undoTime.formattedTime }
        return (undoTime - chapter.start).formattedTime
    }

    /// Whether the progress captions ("THIS CHAPTER" / "WHOLE BOOK") give way to the cover.
    /// Hide below 72 pt; show again only at 120 pt or more, so freeing their ~36 pt (which
    /// grows the cover) can't flip them straight back on — a plain threshold would
    /// oscillate. Pure; pinned by `CoverFloorTests` (critique 2026-10-05, fourth run).
    static func progressCaptionsHidden(currentlyHidden: Bool, artworkSize: CGFloat) -> Bool {
        currentlyHidden ? artworkSize < 120 : artworkSize < 72
    }

    /// The player cover's corner radius: `Radius.panel` (IC-1's player value) normally, and
    /// the same size scale every other cover uses once it's small — a fixed 14 pt on a 54 pt
    /// square read as an app icon (fourth run).
    static func playerCoverRadius(_ side: CGFloat) -> CGFloat {
        side > 80 ? Radius.panel : Radius.cover(side: side)
    }
}

// MARK: - iPhone Duo fold

/// iPhone Duo (§4, docs/iphone-duo-readiness-2026-10-22.md): an active fold across a player
/// surface — the hinge's `.division` reserved region (iOS 27.1) — in the local coordinates
/// of the view it was read from. `nil` everywhere else: flat, fully open, closed, any other
/// iPhone, any OS before 27.1, and any SDK older than 27.1 (CI's Xcode 26), so the layouts
/// that read it keep their existing branch untouched whenever there is no fold.
///
/// Apple's `ReservedRegion` page ("Split your content at a division"): a division "is active
/// only when the device is partially open"; compare the frame's width and height "to find
/// which direction the fold runs"; size each pane to its own side and leave the division's
/// size clear between them; the frame "already includes the region's margins". Read it "in
/// the view that positions the content, so the frames you read use the same coordinates".
/// Frames are mirrored for right-to-left by default, so `minX` is always the leading side.
nonisolated struct PlayerFold: Equatable, Sendable {
    /// True when the fold runs top to bottom (folded like a book): the panes sit side by
    /// side. False when it runs across (folded like a laptop): the panes stack.
    let runsVertically: Bool
    /// The division, margins included, in the reading view's coordinates.
    let frame: CGRect

    /// Pure, so the axis rule can be pinned without a folding device.
    init(divisionFrame frame: CGRect) {
        runsVertically = frame.height > frame.width
        self.frame = frame
    }

    /// The first active division across `geometry`'s view (iPhone Duo has one fold), or nil.
    static func current(in geometry: GeometryProxy) -> PlayerFold? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            // Default options return active regions only, and only those overlapping this
            // view, so a fully open or flat device returns none (Apple docs, above).
            if let division = geometry.reservedRegions(kind: .division).first {
                return PlayerFold(divisionFrame: division.frame)
            }
        }
        #endif
        return nil
    }

    /// The leading/top pane, the clear gap, and the trailing/bottom pane along the axis
    /// the fold splits, clamped to `size` so the three always add up to exactly its width
    /// (book) or height (laptop) and the panes never overlap the fold.
    func panes(in size: CGSize) -> (first: CGFloat, gap: CGFloat, second: CGFloat) {
        let total = max(0, runsVertically ? size.width : size.height)
        let start = runsVertically ? frame.minX : frame.minY
        let end = runsVertically ? frame.maxX : frame.maxY
        let first = min(max(0, start), total)
        let second = min(max(0, total - end), total - first)
        return (first, total - first - second, second)
    }
}
