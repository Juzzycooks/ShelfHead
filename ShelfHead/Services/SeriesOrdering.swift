import Foundation

/// "Which book comes next in this series?" — extracted because three call sites were
/// each answering it independently and had drifted apart:
///
///   - `LibraryViewModel.nextInSeries` correctly restricted candidates to books *later*
///     in the series than the one in hand, preferring a downloaded copy.
///   - `PlayerViewModel.maybeAutoDownloadNextInSeries` and
///     `PlayerViewModel.maybeAutoQueueNextInSeries` both took the first unfinished book
///     in the *whole* series with no sequence comparison at all — so finishing book 5
///     with book 2 still unfinished queued (and auto-downloaded) book 2.
///
/// The sequence comparator itself was copy-pasted at five sites, which is what let the
/// three answers diverge silently. Keeping the decision here — pure, `Sendable`, and
/// free of any `DownloadManager`/`@MainActor` dependency — means it can be unit-tested
/// directly (see `SeriesOrderingTests.swift`) rather than only through a view model.
///
/// Following `ProgressReconciler`'s shape: this decides *which* candidate wins; callers
/// still act on it with their own context (starting a download, appending to Up Next).
enum SeriesOrdering {
    /// The minimum a caller has to know about a book for these decisions. Deliberately
    /// not `LibraryItem` — that type drags in the whole media/chapters/audioFiles graph
    /// and, through `isDownloaded`, the `DownloadManager` singleton, none of which this
    /// logic needs. `Array<LibraryItem>`'s own convenience wrappers do the mapping.
    struct Candidate: Equatable, Sendable {
        let id: String
        /// This book's position within the *specific* series being ordered — a book can
        /// belong to several series at different sequence numbers, so this is always
        /// resolved against one series name by the caller. `nil` for a book the server
        /// has no sequence for.
        let sequence: Double?
        let isFinished: Bool
        let isDownloaded: Bool

        init(id: String, sequence: Double?, isFinished: Bool, isDownloaded: Bool = false) {
            self.id = id
            self.sequence = sequence
            self.isFinished = isFinished
            self.isDownloaded = isDownloaded
        }
    }

    /// The comparator all five original copies open-coded: ascending by sequence, with
    /// unsequenced books last.
    ///
    /// Every unsequenced book compares equal to every other, and `sorted(by:)` is not
    /// guaranteed stable, so their order relative to each other is unspecified. That
    /// matches the original behaviour; it is called out here rather than silently relied
    /// upon. Exposed so callers holding `LibraryItem`s can sort them in place instead of
    /// round-tripping through `Candidate` just to reuse this one line.
    static func precedes(_ lhs: Double?, _ rhs: Double?) -> Bool {
        (lhs ?? .greatestFiniteMagnitude) < (rhs ?? .greatestFiniteMagnitude)
    }

    /// Sequence order, with unsequenced books last.
    static func sortedBySequence(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { precedes($0.sequence, $1.sequence) }
    }

    /// Books positioned after `currentSequence`, in sequence order, excluding the book
    /// itself.
    ///
    /// When either side has no sequence number the comparison can't be made, so the
    /// candidate is kept (self still excluded by id). That is the permissive branch the
    /// correct original implementation used: with no ordering data at all, "everything
    /// else in the series" is a more useful answer than "nothing".
    static func laterInSeries(
        after currentId: String, currentSequence: Double?, in candidates: [Candidate]
    ) -> [Candidate] {
        sortedBySequence(candidates).filter { candidate in
            guard candidate.id != currentId else { return false }
            guard let currentSequence, let candidateSequence = candidate.sequence else { return true }
            return candidateSequence > currentSequence
        }
    }

    /// The next unfinished book after this one.
    ///
    /// `preferDownloaded` picks an already-downloaded book over an earlier streamed one —
    /// wanted when choosing what to *offer* the user ("Next in Series"), but not when
    /// choosing what to *fetch*, where the point is to reach something not yet on disk.
    static func nextUnfinished(
        after currentId: String, currentSequence: Double?, in candidates: [Candidate],
        preferDownloaded: Bool = false
    ) -> Candidate? {
        let unfinished = laterInSeries(after: currentId, currentSequence: currentSequence, in: candidates)
            .filter { !$0.isFinished }
        if preferDownloaded, let downloaded = unfinished.first(where: { $0.isDownloaded }) {
            return downloaded
        }
        return unfinished.first
    }

    /// The next book after this one regardless of progress — the fallback for "Next in
    /// Series" when every later book is already finished.
    static func nextAvailable(
        after currentId: String, currentSequence: Double?, in candidates: [Candidate]
    ) -> Candidate? {
        laterInSeries(after: currentId, currentSequence: currentSequence, in: candidates).first
    }
}
