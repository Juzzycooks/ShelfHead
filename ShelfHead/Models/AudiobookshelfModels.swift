import Foundation
import UIKit

// MARK: - Authentication

struct LoginRequest: Codable {
    let username: String
    let password: String
}

struct LoginResponse: Codable {
    let user: User
    let userDefaultLibraryId: String?
    let serverSettings: ServerSettings?

    enum CodingKeys: String, CodingKey {
        case user
        case userDefaultLibraryId
        case serverSettings
    }
}

struct User: Codable, Identifiable {
    let id: String
    let username: String
    /// Legacy permanent token. Kept by the server for backwards compatibility,
    /// but `accessToken` should be preferred on v2.26+ servers.
    let token: String?
    /// Short-lived JWT access token (ABS v2.26+). Used as the Bearer token.
    let accessToken: String?
    /// Long-lived refresh token, returned in the body only when the request
    /// sends the `x-return-tokens: true` header (mobile clients).
    let refreshToken: String?
    let type: String?
    let isActive: Bool?
    let mediaProgress: [MediaProgress]?
    let bookmarks: [AudioBookmark]?

    /// The token to use for authenticated requests, preferring the new access token.
    var effectiveAccessToken: String? {
        accessToken ?? token
    }
}

struct AudioBookmark: Codable, Identifiable {
    let libraryItemId: String
    let title: String
    let time: Double            // seconds
    let createdAt: Int?

    var id: String { "\(libraryItemId)-\(Int(time))" }
}

struct ServerSettings: Codable {
    let buildNumber: Int?
    let version: String?
}

// MARK: - Libraries

struct Library: Codable, Identifiable {
    let id: String
    let name: String
    let mediaType: String?
    let icon: String?
    let folders: [LibraryFolder]?
}

struct LibraryFolder: Codable, Identifiable {
    let id: String
    let fullPath: String?
}

struct LibraryItemsResponse: Codable {
    let results: [LibraryItem]
    let total: Int
    let limit: Int
    let page: Int
}

// MARK: - Library Items

struct LibraryItem: Codable, Identifiable {
    let id: String
    let ino: String?
    let libraryId: String?
    let mediaType: String?
    let media: Media?
    let numFiles: Int?
    let size: Int?
    let addedAt: Int?
    let updatedAt: Int?
    let mediaProgress: MediaProgress?

    enum CodingKeys: String, CodingKey {
        case id, ino, libraryId, mediaType, media
        case numFiles, size, addedAt, updatedAt
        case mediaProgress = "userMediaProgress"
    }
}

struct Media: Codable {
    let metadata: MediaMetadata?
    let coverPath: String?
    let duration: Double?
    let chapters: [Chapter]?
    let audioFiles: [AudioFile]?
    let numChapters: Int?
    let numAudioFiles: Int?
}

struct MediaMetadata: Codable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let description: String?
    let publishedYear: String?
    let publisher: String?
    let language: String?
    let genres: [String]?
    let isbn: String?
    let asin: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, description
        case authorName, narratorName, seriesName
        case publishedYear, publisher, language
        case genres, isbn, asin
    }
}

struct Chapter: Codable, Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
}

struct AudioFile: Codable, Identifiable {
    // Stable identity: never mint a fresh UUID per access (that breaks ForEach diffing).
    var id: String { ino ?? metadata?.filename ?? "\(index ?? 0)" }
    let ino: String?
    let index: Int?
    let duration: Double?
    let metadata: AudioFileMetadata?
}

struct AudioFileMetadata: Codable {
    let filename: String?
    let ext: String?
    let path: String?
    let size: Int?
}

// MARK: - Media Progress

struct MediaProgress: Codable, Identifiable {
    let id: String
    let libraryItemId: String
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Int?
    let startedAt: Int?
    let finishedAt: Int?
}

// MARK: - Playback Session

struct PlaybackSessionRequest: Codable {
    let deviceInfo: DeviceInfo
    let forceDirectPlay: Bool
    let forceTranscode: Bool
    let mediaPlayer: String
    let supportedMimeTypes: [String]

    init() {
        self.deviceInfo = DeviceInfo()
        self.forceDirectPlay = true
        self.forceTranscode = false
        self.mediaPlayer = "ShelfHead"
        self.supportedMimeTypes = [
            "audio/mpeg",
            "audio/mp4",
            "audio/aac",
            "audio/x-m4a",
            "audio/x-m4b",
            "audio/ogg",
            "audio/flac"
        ]
    }
}

struct DeviceInfo: Codable {
    let deviceId: String
    let clientName: String
    let clientVersion: String
    let manufacturer: String
    let model: String
    let sdkVersion: Int

    init() {
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        self.clientName = "ShelfHead"
        self.clientVersion = "1.0.0"
        self.manufacturer = "Apple"
        self.model = UIDevice.current.model
        self.sdkVersion = 17
    }
}

struct PlaybackSession: Codable, Identifiable {
    let id: String
    let libraryItemId: String?
    let mediaType: String?
    let duration: Double?
    let playMethod: Int?
    let audioTracks: [AudioTrack]?
    let currentTime: Double?
    let startTime: Double?
    let chapters: [Chapter]?
    let libraryItem: LibraryItem?
}

struct AudioTrack: Codable, Identifiable {
    var id: String { "\(index ?? 0)" }
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let title: String?
    let contentUrl: String?
    let mimeType: String?
    let codec: String?
}

struct SyncSessionRequest: Codable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

// MARK: - Personalized View

struct PersonalizedView: Codable, Identifiable {
    var id: String { labelStringKey }
    let label: String
    let labelStringKey: String
    let type: String?
    let entities: [LibraryItem]?

    /// Only "book"/"podcast" shelves contain real LibraryItems we can render as tiles.
    /// "series"/"authors"/"episode" shelves carry different entity shapes and are
    /// browsed from the Library tab instead.
    var isBookShelf: Bool {
        guard let type else { return true }
        return type == "book" || type == "podcast"
    }
}

// MARK: - Progress Update

struct ProgressUpdate: Codable {
    let progress: Double
    let currentTime: Double
    let isFinished: Bool
    let duration: Double
}

// MARK: - Convenience Extensions

extension LibraryItem {
    var title: String {
        media?.metadata?.title ?? "Unknown Title"
    }

    var authorName: String {
        media?.metadata?.authorName ?? "Unknown Author"
    }

    var narratorName: String? {
        media?.metadata?.narratorName
    }

    var seriesName: String? {
        media?.metadata?.seriesName
    }

    var duration: Double {
        media?.duration ?? 0
    }

    var description: String? {
        media?.metadata?.description
    }

    var chapters: [Chapter] {
        media?.chapters ?? []
    }

    var progressPercent: Double {
        mediaProgress?.progress ?? 0
    }

    var currentTime: Double {
        mediaProgress?.currentTime ?? 0
    }

    var isFinished: Bool {
        mediaProgress?.isFinished ?? false
    }
}

extension Double {
    var formattedDuration: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var formattedTime: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        let seconds = Int(self) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
