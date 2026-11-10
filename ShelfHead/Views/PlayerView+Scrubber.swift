import SwiftUI

// MARK: - Progress cluster (Item 10, REVIEW-2026-09-09.md)

// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
// the view below is verbatim what lived at the bottom of that file. It is no longer
// `private` only because `PlayerView.body`, now in a different file, constructs it.

/// The full player's progress cluster: the "THIS CHAPTER" scrubber and its
/// elapsed/remaining counters, the "WHOLE BOOK" orientation rail and time-left line, and
/// the transient "Jump back" undo chip.
///
/// Item 10 (REVIEW-2026-09-09.md): moved out of `PlayerView` as a real child view, in the
/// same spirit as `StatsView`'s `HeroPaceLine` (formerly `PaceCard`). Every playback-position read on this screen
/// lives in here — `chapterProgress`, `progress`, `chapterElapsed`, `chapterLength`,
/// `currentTime`, `remainingListeningTime`, `estimatedFinishDate` — and as computed
/// properties of `PlayerView` they were inlined into *its* body, so the scrubber advancing
/// invalidated the whole full player (cover art, transport row, bottom toolbar, the
/// accessibility scroll column) roughly twice a second. Nothing here changed but where it
/// lives: same views, same order, same modifiers, same accessibility labels.
///
/// The drag state moved with it, because it is only ever read by the scrubber and the two
/// counters — no other part of `PlayerView` ever touched `isDragging`/`dragProgress`.
struct PlayerProgressSection: View {
    /// False when the cover has been squeezed below ~72 pt (`PlayerView.progressCaptionsHidden`):
    /// the two caps captions (~36 pt) give way before the book does (critique 2026-10-05,
    /// fourth run). The scrubber and rail still read without them.
    var showsCaptions: Bool = true
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Live scrub state: `isDragging` makes the counters follow the finger instead of
    /// playback, and `dragProgress` is the fraction the seek commits on release.
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            // "THIS CHAPTER" cluster: the interactive scrubber above, elapsed/remaining
            // counters right beneath it — both chapter-scoped, both under one caption.
            //
            // Fixed after user testing ("the scrubber text doesn't make sense"): this
            // caption used to sit between the *book-level* rail above it and these
            // counters below it, with nothing separating it from the rail — so it read
            // as mislabeling the rail rather than the counters two clusters away, which
            // is what it actually describes. Grouping the caption immediately above the
            // one thing it labels (mirroring "WHOLE BOOK" below, its book-scoped
            // counterpart) removes that ambiguity entirely: each caption now sits right
            // next to its own cluster, not floating between two unrelated ones.
            VStack(spacing: 6) {
                if playerViewModel.hasChapters && showsCaptions {
                    progressCaption("THIS CHAPTER")
                }

                TapeScrubber(
                    value: Binding(
                        get: {
                            if isDragging { return dragProgress }
                            return playerViewModel.hasChapters ? playerViewModel.chapterProgress
                                                               : playerViewModel.progress
                        },
                        set: { newValue in
                            dragProgress = newValue
                            isDragging = true
                        }
                    ),
                    onEditingChanged: { editing in
                        if !editing {
                            if playerViewModel.hasChapters {
                                playerViewModel.seekWithinChapter(fraction: dragProgress)
                            } else {
                                playerViewModel.seek(to: dragProgress * playerViewModel.duration)
                            }
                            isDragging = false
                        }
                    },
                    // D3: a chapterless multi-hour book would otherwise step 5% per
                    // VoiceOver swipe (36 minutes on a 12-hour book) — give it a
                    // time-based ~30s step instead. Chapter-scoped books keep 5% of the
                    // chapter, which is already a reasonable granularity at typical
                    // chapter lengths.
                    accessibilityStepFraction: playerViewModel.hasChapters
                        ? 0.05
                        : (30 / max(playerViewModel.duration, 1)),
                    // P-1 (REVIEW_2026-09-14_DESIGN.md): real chapter boundaries,
                    // expressed as fractions of whatever range the scrubber is bound to
                    // right above — the chapter when there is one, the whole book when
                    // there isn't. See `scrubberChapterTicks` for why a chapter-scoped
                    // scrubber legitimately gets an empty array here. These arrived as
                    // the replacement for the bar texture and now coexist with it (the
                    // user asked for the waveform look back after seeing the plain rail
                    // on device); the scrubber draws them as marks over the bars.
                    chapterTicks: PlayerView.scrubberChapterTicks(
                        chapters: playerViewModel.chapters,
                        rangeStart: playerViewModel.hasChapters ? playerViewModel.chapterStart : 0,
                        rangeEnd: playerViewModel.hasChapters ? playerViewModel.chapterEnd
                                                              : playerViewModel.duration),
                    // Keys the deterministic bar texture to the book being played, so it
                    // is stable for a book and different between books. Decoration, not
                    // audio analysis — `TapeScrubber`'s own section comment is explicit
                    // about that. Note this goes through `TapeScrubber.waveformSeed(_:)`
                    // rather than the `id.hashValue` the pre-318 call site used: string
                    // hashing is seeded per process in Swift, so the old seed changed on
                    // every app launch and the texture was never actually stable.
                    waveformSeed: TapeScrubber.waveformSeed(forBookID: playerViewModel.currentBook?.id),
                    // P-3: the spoken value, built from the very same two figures the
                    // counters below render — so what VoiceOver says and what the screen
                    // shows can't drift apart.
                    accessibilityValueText: PlayerView.scrubberAccessibilityValue(
                        elapsed: elapsedSeconds, remaining: remainingSeconds)
                )

                HStack {
                    // P-2: `.plain`, not the default LCD chip. The two chips were the
                    // highest-contrast elements on the screen — cream on near-black over
                    // a warm background — which put the eye on a timestamp before the
                    // play button on a screen that already carried five time readouts.
                    TapeCounter(text: currentTimeDisplay, style: .plain)
                    Spacer()
                    TapeCounter(text: remainingTimeDisplay, style: .plain)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .ignore)
                // P-3: spoken durations here too, for the same reason as the scrubber's
                // own value above — "12:44" is read out as a pair of numbers separated by
                // a colon, not as a length of time.
                .accessibilityLabel(playerViewModel.hasChapters
                    ? String(localized: "\(PlayerView.spokenTime(elapsedSeconds)) into this chapter, \(PlayerView.spokenTime(remainingSeconds)) left in this chapter",
                             comment: "VoiceOver label for the time counters. First %@ is the spoken elapsed time in the chapter, second the spoken time left")
                    : String(localized: "\(PlayerView.spokenTime(elapsedSeconds)) elapsed, \(PlayerView.spokenTime(remainingSeconds)) remaining",
                             comment: "VoiceOver label for the time counters. First %@ is the spoken elapsed time, second the spoken time remaining"))
            }

            // "WHOLE BOOK" cluster: the non-interactive orientation rail (D3) plus how
            // much of the whole book — not just this chapter — is left. Only shown for
            // chapter-scoped books, since a chapterless book's "THIS CHAPTER" cluster
            // above is already whole-book-scoped and would just duplicate this one.
            if playerViewModel.hasChapters {
                VStack(spacing: 6) {
                    if showsCaptions { progressCaption("WHOLE BOOK") }
                    BookPositionRail(
                        chapters: playerViewModel.chapters,
                        duration: playerViewModel.duration,
                        progress: playerViewModel.progress,
                        currentChapter: playerViewModel.currentChapter
                    )
                    timeLeftLine
                }
                // P-6: a deliberate 2pt hairline inset so the WHOLE BOOK rail's rounded
                // caps clear the scrubber's knob travel at 0 and 1. Not a margin; no
                // `Space.*` token is this small.
                .padding(.horizontal, 2)
            } else {
                timeLeftLine
            }

            // Critique 2026-10-05 (third run): the "Jump back" chip used to be its own row
            // here. It now shares the one status line with the sleep and Up Next chips
            // (`StatusChipRow`, PlayerView+BottomRegion.swift), so the busy state costs one
            // chip row instead of two and the cover keeps its room on small phones.
        }
    }

    /// Small tracked-caps caption used above each of this section's two clusters
    /// ("THIS CHAPTER" / "WHOLE BOOK") — pulled out so both clusters render their
    /// caption identically rather than risking the two drifting apart over time.
    private func progressCaption(_ text: LocalizedStringResource) -> some View {
        // Design-direction pass (17 Aug 2026): was its own independent 11pt/caption2
        // spelling of the exact same "small tracked-caps group label" role
        // `RetroSectionHeader` already names as `Typo.sectionTitle` (12pt/caption) —
        // two call sites quietly drifting apart on size/text-style for one role. Now
        // shares that token; still keeps its own muted (not cream) color and tracking,
        // since this is a quieter, sub-cluster label rather than a top-level section
        // header, and the token intentionally leaves color/tracking to the caller.
        Typo.sectionTitle(Text(text))
            .tracking(LocalizedText.tracking(1.5))
            // Critique 2026-10-05 (typeset): at AX3 "THIS CHAPTER" grew into a headline
            // over a scrubber that doesn't grow with it. Clamped at `.accessibility1`, the
            // app's existing cap for fixed-layout labels (see the speed grid, `CassetteTile`).
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            // U3 (REVIEW_2026-08-20_UI_SECURITY.md): 0.7 was tuned for the old 11pt
            // caption2 spelling of this label and never re-measured after the 17 Aug
            // design-direction pass moved it to 12pt bold (not WCAG "large text", so the
            // 4.5:1 floor applies) — it measured 3.02:1 Light / 3.66:1 Dark, failing both
            // themes. Full `shelfMuted` measures 5.60:1 / 6.24:1.
            .foregroundStyle(Color.shelfMuted)
    }

    /// Whole-book time left at the current speed, plus a projected finish time while
    /// playing (e.g. "≈3h 20m left · finishes 9:40 PM at 1.5×").
    @ViewBuilder
    private var timeLeftLine: some View {
        let remaining = playerViewModel.remainingListeningTime
        if remaining > 1 {
            // Spell out "in book" once there's a chapter-scoped counter above it to
            // disambiguate from — otherwise the two figures are identical and the
            // plain "left" reads fine on its own.
            let base = playerViewModel.hasChapters
                ? String(localized: "≈\(remaining.formattedDuration) left in book", comment: "Time-left line under the scrubber when the book has chapters. %@ is a duration such as 3h 20m")
                : String(localized: "≈\(remaining.formattedDuration) left", comment: "Time-left line under the scrubber. %@ is a duration such as 3h 20m")
            // P3-13 (third-pass review, 14 Aug 2026): `estimatedFinishDate` is a
            // computed property — reading it a second time for the accessibility
            // label (previously force-unwrapped there, `playerViewModel
            // .estimatedFinishDate!`, guarded only by a separate `!= nil` check next to
            // it) risked a genuinely different result than the `if let` above if the
            // computation isn't perfectly stable between the two reads, and the force
            // unwrap itself was one un-obvious crash away from a nil that slips through
            // between them. Read once, reuse for both `text` and the label below.
            //
            // Critique 2026-10-05 (clarify): the clock now carries "tomorrow" when it
            // crosses midnight, is dropped beyond 12 hours, and is dropped while a sleep
            // timer will stop playback first (`finishClockPhrase`).
            let finishClock = playerViewModel.estimatedFinishDate.flatMap {
                PlayerView.finishClockPhrase(finish: $0, now: Date(), sleepTimer: playerViewModel.sleepTimerOption)
            }
            let text: String = {
                if let finishClock {
                    return String(localized: "\(base) · finishes \(finishClock) at \(playerViewModel.playbackRateLabel)",
                                  comment: "Time-left line with a projected finish. First %@ is the time-left text, second the finish clock (e.g. 9:40 PM or 'tomorrow 1:10 AM'), third the playback speed (e.g. 1.5×)")
                }
                return base
            }()
            Text(text)
                .scaledFont(11, weight: .medium, design: .rounded, relativeTo: .caption)
                // Review 2026-08-19: PlayerView is NOT theme-pinned (see ContentView's
                // own note — only the cassette hardware in RetroComponents is), so this
                // renders on Light theme's warm paper too, where `.opacity(0.6)`
                // measured 4.09:1 — under AA for an 11pt line. 0.7 (5.56:1) matches
                // `transportButton`'s already-correct "quiet secondary" value on this
                // same screen, so this doesn't invent a new opacity step.
                .foregroundStyle(Color.shelfCream.opacity(0.7))
                // Critique 2026-10-05 (typeset): one line truncated at AX3; the AX layout
                // scrolls, so it can take a second line there.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(finishClock.map {
                    String(localized: "About \(remaining.formattedDuration) left, finishing around \($0) at \(playerViewModel.playbackRateLabel)",
                           comment: "VoiceOver time-left line. First %@ is a duration, second the finish clock, third the playback speed")
                } ?? String(localized: "About \(remaining.formattedDuration) of listening left", comment: "VoiceOver time-left line. %@ is a duration"))
        }
    }

    /// Elapsed within the current chapter (or whole-book when no chapters), in seconds.
    ///
    /// P-3 (REVIEW_2026-09-14_DESIGN.md): the two display strings below used to each
    /// recompute this inline. They still render exactly what they did — `formattedTime`,
    /// same clamping, same drag handling — but the VoiceOver value now needs the raw
    /// seconds too (a spoken duration can't be recovered from "12:44" without reparsing
    /// it), so the arithmetic lives in one place and everything downstream reads it.
    private var elapsedSeconds: Double {
        if playerViewModel.hasChapters {
            return isDragging ? dragProgress * playerViewModel.chapterLength
                              : playerViewModel.chapterElapsed
        }
        return isDragging ? (dragProgress * playerViewModel.duration) : playerViewModel.currentTime
    }

    /// Remaining within the current chapter (or whole-book when no chapters), in seconds.
    private var remainingSeconds: Double {
        let total = playerViewModel.hasChapters ? playerViewModel.chapterLength
                                                : playerViewModel.duration
        return max(0, total - elapsedSeconds)
    }

    /// Elapsed within the current chapter (or whole-book when no chapters).
    private var currentTimeDisplay: String { elapsedSeconds.formattedTime }

    /// Remaining within the current chapter (or whole-book when no chapters).
    private var remainingTimeDisplay: String { "-\(remainingSeconds.formattedTime)" }
}
