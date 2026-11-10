import Foundation

/// Batch 459: pure layout maths for the Cassette Wall. No SwiftUI, so the year grouping and
/// spine colour seed can be unit-tested. Batch 464 parked the 3D wall and its shelf-packing
/// maths in `docs/parked/cassette-wall-3d-batch-459/`.
nonisolated enum CassetteWallLayout {

    struct YearGroup: Equatable, Sendable, Identifiable {
        let year: Int
        let books: [FinishedBook]
        var id: Int { year }
    }

    // MARK: - Grouping

    /// Books grouped by the calendar year they were finished: newest year first, and within a
    /// year newest first. Ties on date break on title then id so the order is stable.
    static func groupByYear(_ books: [FinishedBook], calendar: Calendar = .current) -> [YearGroup] {
        let sorted = books.sorted(by: isNewer)
        var order: [Int] = []
        var buckets: [Int: [FinishedBook]] = [:]
        for book in sorted {
            let year = calendar.component(.year, from: book.finishedAt)
            if buckets[year] == nil { order.append(year) }
            buckets[year, default: []].append(book)
        }
        return order.sorted(by: >).map { YearGroup(year: $0, books: buckets[$0] ?? []) }
    }

    static func isNewer(_ a: FinishedBook, _ b: FinishedBook) -> Bool {
        if a.finishedAt != b.finishedAt { return a.finishedAt > b.finishedAt }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }

    // MARK: - Spine colour

    /// A cassette shell colour as hue/saturation/brightness (0...1). Muted shell tones, never
    /// the accent: saturation and brightness stay inside a narrow band so ink reads on all of
    /// them and no spine competes with the app's one amber accent.
    struct ShellTone: Equatable, Sendable {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    /// Stable per book (FNV-1a via `ShareVisualSeed.stableHash`), so a book keeps its colour.
    static func shellTone(for bookId: String) -> ShellTone {
        let h = ShareVisualSeed.stableHash("cassette-spine|\(bookId)")
        return ShellTone(hue: Double(h % 360) / 360,
                         saturation: 0.22 + Double((h >> 9) % 30) / 100,      // 0.22...0.51
                         brightness: 0.34 + Double((h >> 17) % 26) / 100)     // 0.34...0.59
    }
}
