import Foundation

/// On-device transcript of one audiobook (Phase 1, "The app understands the book
/// itself"). Produced by `TranscriptionService` from the downloaded audio, stored by
/// `TranscriptStore` outside the downloads tree so it survives deleting the download,
/// and read by search, captions, clips, auto-chapters, book intelligence and
/// read-along.
///
/// All times are **book time** in seconds (track `startOffset` + time in track), the
/// same clock as `AudioPlayerService.currentTime` and `Chapter.start/end`, so a
/// transcript made from the download still lines up while streaming.
///
/// This is the shared core every Phase 1 feature builds on. Change it only with a
/// `version` bump and a decode path for the old shape.
struct Transcript: Codable, Equatable, Sendable {
    /// Bump when the stored shape or the segmenting rules change in a way old files
    /// can't be read under. `TranscriptStore` treats an older version as absent.
    static let currentVersion = 1

    var version: Int
    var itemId: String
    /// BCP-47 identifier of the locale the transcriber ran with (e.g. "en-US", "zh-CN").
    var localeIdentifier: String
    /// Number of audio tracks in the book when transcription started.
    var trackCount: Int
    /// Fingerprint of the tracks' durations; a mismatch means the download was replaced
    /// by different audio and the transcript must be redone.
    var audioSignature: String
    /// Track indices whose audio has been fully transcribed. Work resumes from the first
    /// index not in this set.
    var completedTracks: [Int]
    /// Checkpoint inside a track that isn't finished yet, so a long single-file book
    /// (one 10-hour m4b) doesn't restart from zero when a background task expires.
    /// Segments up to `secondsInTrack` of that track are already in `segments`.
    var partial: PartialProgress?
    /// Sentence-level segments, sorted by `start`, non-overlapping.
    var segments: [TranscriptSegment]
    var createdAt: Date
    var updatedAt: Date

    var isComplete: Bool { Set(completedTracks).count >= trackCount && trackCount > 0 }

    /// Book time covered so far: the end of the last segment.
    var coveredUntil: Double { segments.last?.end ?? 0 }

    init(
        itemId: String,
        localeIdentifier: String,
        trackCount: Int,
        audioSignature: String,
        completedTracks: [Int] = [],
        partial: PartialProgress? = nil,
        segments: [TranscriptSegment] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.version = Transcript.currentVersion
        self.itemId = itemId
        self.localeIdentifier = localeIdentifier
        self.trackCount = trackCount
        self.audioSignature = audioSignature
        self.completedTracks = completedTracks
        self.partial = partial
        self.segments = segments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Fingerprint of a book's audio from its track durations (rounded to 0.1 s).
    nonisolated static func audioSignature(trackDurations: [Double]) -> String {
        trackDurations.map { String(format: "%.1f", $0) }.joined(separator: "|")
    }
}

/// Where an unfinished track's transcription got to.
struct PartialProgress: Codable, Equatable, Sendable {
    var trackIndex: Int
    /// Seconds into the track (track time, not book time) transcribed so far.
    var secondsInTrack: Double
}

/// One sentence (or sentence-like run) of speech.
struct TranscriptSegment: Codable, Equatable, Sendable {
    /// Book time the segment starts, seconds.
    var start: Double
    /// Book time the segment ends, seconds.
    var end: Double
    /// The text, already joined with the right spacing for its script.
    var text: String
    /// Start time of each word, as an offset in seconds from `start`. Same count as
    /// `wordOffsets`. May be empty when the transcriber gave no word timing.
    var wordStarts: [Float]
    /// Where each word begins in `text`, in UTF-16 code units (`NSString` / `NSRange`
    /// indexing), so a caption can highlight the word being spoken.
    var wordOffsets: [Int32]

    enum CodingKeys: String, CodingKey {
        case start = "s", end = "e", text = "t", wordStarts = "ws", wordOffsets = "wo"
    }

    init(start: Double, end: Double, text: String, wordStarts: [Float] = [], wordOffsets: [Int32] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.wordStarts = wordStarts
        self.wordOffsets = wordOffsets
    }

    var duration: Double { max(0, end - start) }
}

/// Pure lookups over a transcript's sorted segments. No I/O; unit-tested.
enum TranscriptLookup {
    /// Index of the segment playing at `time`: the last segment whose `start <= time`,
    /// provided `time` is no more than `gapTolerance` seconds past its `end` (so a long
    /// silence shows no caption). Nil before the first segment or inside a long gap.
    nonisolated static func segmentIndex(
        in segments: [TranscriptSegment],
        at time: Double,
        gapTolerance: Double = 1.5
    ) -> Int? {
        guard !segments.isEmpty, time.isFinite else { return nil }
        var low = 0
        var high = segments.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { return nil }
        return time <= segments[found].end + gapTolerance ? found : nil
    }

    /// Index of the word being spoken at `time` within `segment`, or nil when the
    /// segment has no word timing or `time` is before its first word.
    nonisolated static func wordIndex(in segment: TranscriptSegment, at time: Double) -> Int? {
        guard !segment.wordStarts.isEmpty else { return nil }
        let offset = Float(time - segment.start)
        var low = 0
        var high = segment.wordStarts.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if segment.wordStarts[mid] <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found >= 0 ? found : nil
    }

    /// UTF-16 range of word `index` in `segment.text`, ending where the next word begins
    /// (trailing spaces/punctuation trimmed). Nil when out of range.
    nonisolated static func wordRange(in segment: TranscriptSegment, wordIndex index: Int) -> NSRange? {
        guard index >= 0, index < segment.wordOffsets.count else { return nil }
        let ns = segment.text as NSString
        let start = Int(segment.wordOffsets[index])
        let next = index + 1 < segment.wordOffsets.count ? Int(segment.wordOffsets[index + 1]) : ns.length
        guard start >= 0, start <= next, next <= ns.length else { return nil }
        var end = next
        while end > start {
            let ch = ns.character(at: end - 1)
            guard let scalar = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Indices of the segments that overlap `[from, to]`.
    nonisolated static func segmentIndices(in segments: [TranscriptSegment], from: Double, to: Double) -> Range<Int> {
        guard !segments.isEmpty, from <= to else { return 0..<0 }
        let first = segments.firstIndex { $0.end > from } ?? segments.count
        var last = first
        while last < segments.count, segments[last].start < to { last += 1 }
        return first..<last
    }
}
