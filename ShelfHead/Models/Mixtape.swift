import Foundation

/// Batch 458: a user-made, titled, ordered list of clips from books on one Audiobookshelf server.
/// Codable with stable UUID ids and `updatedAt` so a later batch can mirror it to the household.

/// One passage of one book, in book seconds.
nonisolated struct MixtapeClip: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var itemId: String
    var start: Double
    var end: Double
    var label: String?
    /// Transcript text of the passage, when one existed.
    var quote: String?
    /// Cached for display, so a row never needs the server.
    var title: String?
    var author: String?

    init(id: UUID = UUID(), itemId: String, start: Double, end: Double, label: String? = nil,
         quote: String? = nil, title: String? = nil, author: String? = nil) {
        self.id = id
        self.itemId = itemId
        self.start = start
        self.end = end
        self.label = label
        self.quote = quote
        self.title = title
        self.author = author
    }

    var duration: Double { max(0, end - start) }
}

nonisolated struct Mixtape: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var clips: [MixtapeClip]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, clips: [MixtapeClip] = [],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.clips = clips
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }
}

/// Pure list edits, shared by the store and the tests.
nonisolated enum MixtapeOps {
    static let maxClips = 25

    static func appending(_ clip: MixtapeClip, to mixtape: Mixtape, now: Date = Date()) -> Mixtape? {
        guard mixtape.clips.count < maxClips else { return nil }
        var out = mixtape
        out.clips.append(clip)
        out.updatedAt = now
        return out
    }

    static func moving(_ mixtape: Mixtape, from source: IndexSet, to destination: Int, now: Date = Date()) -> Mixtape {
        var out = mixtape
        // Same semantics as `Array.move(fromOffsets:toOffset:)` without importing SwiftUI.
        let moved = source.sorted().compactMap { out.clips.indices.contains($0) ? out.clips[$0] : nil }
        guard !moved.isEmpty else { return mixtape }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where out.clips.indices.contains(index) { out.clips.remove(at: index) }
        let target = min(max(destination - before, 0), out.clips.count)
        out.clips.insert(contentsOf: moved, at: target)
        out.updatedAt = now
        return out
    }

    static func removing(_ mixtape: Mixtape, at offsets: IndexSet, now: Date = Date()) -> Mixtape {
        var out = mixtape
        for index in offsets.sorted(by: >) where out.clips.indices.contains(index) { out.clips.remove(at: index) }
        out.updatedAt = now
        return out
    }

    static func renamed(_ mixtape: Mixtape, to title: String, now: Date = Date()) -> Mixtape {
        var out = mixtape
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return mixtape }
        out.title = trimmed
        out.updatedAt = now
        return out
    }
}
