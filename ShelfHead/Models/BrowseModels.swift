import Foundation

// MARK: - Series

struct Series: Codable, Identifiable {
    let id: String
    let name: String?
    let books: [LibraryItem]?
    let addedAt: Int?
    let totalDuration: Double?

    var displayName: String { name ?? "Unknown Series" }
    var bookCount: Int { books?.count ?? 0 }
}

struct SeriesResponse: Codable {
    let results: [Series]
    let total: Int?
}

// MARK: - Filter data (authors, genres, etc. for a library)

struct NamedEntity: Codable, Identifiable {
    let id: String
    let name: String
}

struct LibraryFilterData: Codable {
    let authors: [NamedEntity]?
    let genres: [String]?
    let tags: [String]?
    let series: [NamedEntity]?
    let narrators: [String]?
    let languages: [String]?
}

struct LibraryDataResponse: Codable {
    let filterdata: LibraryFilterData?
}

// MARK: - Listening Stats

struct ListeningStats: Codable {
    let totalTime: Double?          // seconds
    let today: Double?              // seconds
    let days: [String: Double]?     // "YYYY-MM-DD" -> seconds
}

// MARK: - Sorting & Filtering options

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "media.metadata.title"
    case author = "media.metadata.authorName"
    case addedAt = "addedAt"
    case duration = "media.duration"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .addedAt: return "Date Added"
        case .duration: return "Duration"
        }
    }
}

enum LibraryProgressFilter: String, CaseIterable, Identifiable {
    case all
    case notStarted = "not-started"
    case inProgress = "in-progress"
    case finished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .finished: return "Finished"
        }
    }

    /// The encoded `filter` query value, or nil for "all".
    var filterValue: String? {
        guard self != .all else { return nil }
        return APIFilter.encode(group: "progress", value: rawValue)
    }
}

// MARK: - Collections & Playlists

struct BookCollection: Codable, Identifiable {
    let id: String
    let name: String?
    let books: [LibraryItem]?

    var displayName: String { name ?? "Untitled Collection" }
    var bookCount: Int { books?.count ?? 0 }
}

struct CollectionsResponse: Codable {
    let collections: [BookCollection]
}

struct Playlist: Codable, Identifiable {
    let id: String
    let name: String?
    let items: [PlaylistItem]?

    var displayName: String { name ?? "Untitled Playlist" }
    var libraryItems: [LibraryItem] { (items ?? []).compactMap { $0.libraryItem } }
}

struct PlaylistItem: Codable {
    let libraryItemId: String?
    let episodeId: String?
    let libraryItem: LibraryItem?
}

struct PlaylistsResponse: Codable {
    let playlists: [Playlist]
}

enum BrowseMode: String, CaseIterable, Identifiable {
    case books = "Books"
    case series = "Series"
    case authors = "Authors"
    case collections = "Collections"
    case playlists = "Playlists"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .books: return "books.vertical"
        case .series: return "square.stack.3d.up"
        case .authors: return "person.2"
        case .collections: return "rectangle.stack"
        case .playlists: return "music.note.list"
        }
    }
}

/// Helper for Audiobookshelf's `group.base64(value)` filter format.
enum APIFilter {
    static func encode(group: String, value: String) -> String {
        let base64 = Data(value.utf8).base64EncodedString()
        return "\(group).\(base64)"
    }
}
