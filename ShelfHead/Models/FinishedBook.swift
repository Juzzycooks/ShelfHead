import Foundation

/// Batch 459: one finished book as the Cassette Wall (and, in Batch 463, the Listening
/// Passport) sees it. A plain value so it can be persisted as JSON per account and shared
/// between the wall, Year in Review and the passport. Metadata comes from the item fetch;
/// `finishedAt` comes from `/api/me`'s `mediaProgress[].finishedAt` (epoch milliseconds).
nonisolated struct FinishedBook: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var author: String
    /// The raw `narratorName` string as the server stores it (kept so a later re-split is lossless).
    var narratorName: String?
    var narrators: [String]
    var genres: [String]
    var publishedYear: Int?
    var finishedAt: Date
    /// Seconds. Zero when the server didn't report one.
    var duration: Double
    var coverPath: String?

    /// Splits a server `narratorName` ("A, B & C") into trimmed names. Commas and
    /// ampersands only: " and " is left alone because it appears inside real names.
    static func splitNarrators(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        return raw
            .replacingOccurrences(of: "&", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// `/api/me` sends epoch milliseconds; nil/zero/negative means "no date".
    static func date(fromMilliseconds ms: Int?) -> Date? {
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// "1998" or "1998-03-04" or any string starting with four digits.
    static func year(fromPublished raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4)
        guard digits.count == 4, let y = Int(digits), (1000...3000).contains(y) else { return nil }
        return y
    }
}

/// Batch 459: the id and date of a finished book before its metadata is fetched.
nonisolated struct FinishedRef: Equatable, Sendable {
    let itemId: String
    let finishedAt: Date

    /// Finished audiobook progress records, newest first. A missing `finishedAt` falls back
    /// to `lastUpdate`; a record with neither is skipped (no honest date to shelve it under).
    static func refs(from progress: [MediaProgress]) -> [FinishedRef] {
        var best: [String: FinishedRef] = [:]
        for p in progress where p.isFinished == true && p.episodeId == nil {
            guard let date = FinishedBook.date(fromMilliseconds: p.finishedAt)
                    ?? FinishedBook.date(fromMilliseconds: p.lastUpdate) else { continue }
            if let existing = best[p.libraryItemId], existing.finishedAt >= date { continue }
            best[p.libraryItemId] = FinishedRef(itemId: p.libraryItemId, finishedAt: date)
        }
        return best.values.sorted { $0.finishedAt > $1.finishedAt }
    }
}
