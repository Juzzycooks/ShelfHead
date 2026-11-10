import Foundation

/// Pure geometry over a book's tracks (+ optional chapters): converts an absolute
/// book-time offset to a (track index, offset within that track) position, and looks
/// up which chapter a given time falls in.
///
/// Extracted from three independent hand-rolled "walk the tracks, accumulate
/// duration" loops that used to live directly in `AudioPlayerService`
/// (`startPlayback`'s track-selection loop, `seek(to:)`'s track-selection loop, and a
/// third in an earlier version of this file) — each used the same exclusive upper
/// bound, `time < trackStart + trackDuration`, to decide which track a time falls in.
/// For `time == duration` on the *last* track, that comparison is false by
/// construction (the book's total duration IS that track's end), so every one of
/// those loops matched no track and silently did nothing. Concretely, that meant:
///
/// - **ARCH-1**: once a user was within one skip interval of the end of a book,
///   skip-forward, "next chapter" (whose fallback is `seek(to: duration)`), and the
///   lock-screen/CarPlay/AirPods equivalents all went silently dead — no seek, no
///   track advance, no visible change.
/// - **ARCH-9**: resuming a book whose saved position is at-or-past its duration (a
///   finished book reopened from the library, a Handoff resume, or a manifest whose
///   `currentTime` rounds slightly past `duration`) matched no track either, so
///   playback silently started over at track 0 / time 0 — which then got synced to
///   the server as a fresh position, wiping the completed listen.
///
/// `position(atAbsoluteTime:)` fixes both by resolving to "the end of the last track"
/// instead of "no match" for any time at or past the book's total duration, and by
/// giving a `nil`-duration track a sensible bound (the next track's start) instead of
/// letting it silently swallow every seek/resume that lands past its own start.
struct TrackTimeline {
    struct Position: Equatable {
        let trackIndex: Int
        let offsetInTrack: Double
    }

    let tracks: [AudioTrack]
    let chapters: [Chapter]

    /// Absolute start offset of every track: each track's own `startOffset` if
    /// present, else the accumulated end of every prior track (a `nil` duration
    /// contributes 0 to that running total, same as the original call sites).
    private var trackStarts: [Double] {
        var out: [Double] = []
        out.reserveCapacity(tracks.count)
        var accumulated: Double = 0
        for track in tracks {
            let start = track.startOffset ?? accumulated
            out.append(start)
            accumulated = start + (track.duration ?? 0)
        }
        return out
    }

    /// End offset of `tracks[index]`: the *next* track's own reported start if there
    /// is one, else its own `startOffset + duration` if the duration is known, else
    /// — a `nil`-duration *last* track — unbounded, since there's nothing to bound
    /// it with and the caller (`position(atAbsoluteTime:)`) already treats the last
    /// track as open-ended on its high side regardless.
    ///
    /// NEW-10 (follow-up review, 14 Aug 2026): this used to check own-duration
    /// first and next-start second. When a server disagrees ever so slightly
    /// between "this track's start + duration" and "the next track's own start" (a
    /// stitch-point rounding difference, or non-monotonic `startOffset`s), that
    /// order left a gap between the two boundaries matching neither track in
    /// `position(atAbsoluteTime:)`'s loop, falling through to its own failure
    /// branch — silently resolving to (track 0, offset 0), i.e. ARCH-9 all over
    /// again, for exactly the class of bug that fix exists to close. Prioritising
    /// the next track's actual start makes every consecutive pair share exactly
    /// one boundary with no gap between them, by construction, regardless of
    /// whether the two independently-reported values agree. This doesn't change
    /// `totalDuration`'s own behaviour: its only call site is the LAST track,
    /// where `index + 1 < starts.count` is always false, so it already fell
    /// through to the own-duration-or-infinity path either way.
    private func trackEnd(at index: Int, starts: [Double]) -> Double {
        // P3-11 (third-pass review, 14 Aug 2026): guard against non-monotonic starts —
        // a `startOffset` that goes backward or stays flat between two tracks (bad or
        // hostile server data) previously still passed straight through as this
        // track's end, producing a zero-or-negative-width range that
        // `position(atAbsoluteTime:)`'s `clamped >= start && clamped < end` check could
        // never match, falling through to that function's own last-resort branch
        // regardless of how good this track's own duration is. Only trust the next
        // track's start when it's actually after this one; otherwise fall back to
        // this track's own duration (or infinity), same as if there were no next
        // track's start to consult at all.
        if index + 1 < starts.count, starts[index + 1] > starts[index] { return starts[index + 1] }
        if let duration = tracks[index].duration { return starts[index] + duration }
        return .infinity
    }

    /// Total book duration, derived from the tracks themselves (may differ slightly
    /// from a server-reported duration if a track's own duration is unknown or the
    /// two disagree by rounding — callers that need the authoritative value should
    /// keep using their own `session.duration`, this is only for internal bucketing).
    var totalDuration: Double {
        guard let lastIndex = tracks.indices.last else { return 0 }
        let starts = trackStarts
        let end = trackEnd(at: lastIndex, starts: starts)
        return end.isFinite ? end : starts[lastIndex]
    }

    /// Resolves an absolute book-time offset to a (track, offset-within-track)
    /// position. Always resolves to *some* track when `tracks` is non-empty — times
    /// at or past the book's total duration resolve to the last track (offset capped
    /// to that track's own duration when known, so a wildly-out-of-range time like
    /// `duration + 500` doesn't hand back an offset AVPlayer would have to clamp
    /// itself); negative times clamp to the very start of the first track.
    func position(atAbsoluteTime time: Double) -> Position {
        guard !tracks.isEmpty else { return Position(trackIndex: 0, offsetInTrack: 0) }
        let clamped = max(0, time)
        let starts = trackStarts

        for index in tracks.indices {
            let start = starts[index]
            let isLastTrack = index == tracks.count - 1

            if isLastTrack {
                guard clamped >= start else { continue }
                let rawOffset = clamped - start
                let offset = tracks[index].duration.map { min(rawOffset, $0) } ?? rawOffset
                return Position(trackIndex: index, offsetInTrack: offset)
            }

            let end = trackEnd(at: index, starts: starts)
            if clamped >= start && clamped < end {
                // P3-11 (third-pass review, 14 Aug 2026): NEW-10 made `trackEnd` prefer
                // the *next* track's own reported start over this track's own
                // start+duration, to close the ARCH-9 gap-between-boundaries failure —
                // but that means a real gap between two tracks' independently-reported
                // boundaries (track 0: start 0, duration 100; track 1: start 200) let a
                // time like 150 match track 0's range (`0 <= 150 < 200`) with NO cap
                // against track 0's own 100s duration. The uncapped offset (150) landed
                // past the end of a 100s file — AVPlayer clamps the seek, reports the
                // asset finished, and `moveToNextTrack()` fires immediately, landing at
                // 200 instead of the intended 150. The last-track branch above already
                // caps this way; non-last tracks need the identical cap.
                let rawOffset = clamped - start
                let offset = tracks[index].duration.map { min(rawOffset, $0) } ?? rawOffset
                return Position(trackIndex: index, offsetInTrack: offset)
            }
        }
        // Only reachable if `clamped` somehow falls before the first track's start
        // (shouldn't happen once clamped to >= 0 with a track list starting at 0),
        // or — NEW-10 (follow-up review, 14 Aug 2026) — a gap between two tracks'
        // independently-reported boundaries still slips through despite the
        // next-start-first bounding in `trackEnd` above (e.g. non-monotonic starts
        // from a hostile or buggy server). Resolving to the LAST track whose start
        // is still `<= clamped` is a far safer failure mode than always snapping to
        // track 0: track 0 discards the entire saved position outright — exactly
        // the ARCH-9 failure this file exists to prevent — whereas resolving to the
        // correct-ish neighbouring track only risks a few seconds' misalignment
        // right at the stitch point.
        if let fallbackIndex = tracks.indices.last(where: { starts[$0] <= clamped }) {
            return Position(trackIndex: fallbackIndex, offsetInTrack: max(0, clamped - starts[fallbackIndex]))
        }
        return Position(trackIndex: 0, offsetInTrack: 0)
    }

    /// The chapter containing `time`, if any.
    func chapter(at time: Double) -> Chapter? {
        chapters.first { time >= $0.start && time < $0.end }
    }
}
