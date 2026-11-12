import Foundation

/// Podcast episode endpoints (episode progress, played state). Routes go through `send(...)` so they
/// share auth headers and the 401 refresh-and-retry.
extension AudiobookshelfAPI {

    /// Marks one podcast episode played or unplayed on the server.
    /// `PATCH /api/me/progress/:libraryItemId/:episodeId` with `{ isFinished }`
    /// (ApiRouter `createUpdateMediaProgress`; checked against the server source).
    /// Returns the progress record afterwards via `GET /api/me/progress/:id/:episodeId`
    /// so the caller can update its cache; nil if that read fails (the PATCH already succeeded).
    func setEpisodeFinished(itemId: String, episodeId: String, isFinished: Bool) async throws -> MediaProgress? {
        struct Body: Encodable { let isFinished: Bool }
        _ = try await send(path: "/api/me/progress/\(Self.encodedSegment(itemId))/\(Self.encodedSegment(episodeId))", method: "PATCH",
                           body: try JSONEncoder().encode(Body(isFinished: isFinished)))
        let data = try? await send(path: "/api/me/progress/\(Self.encodedSegment(itemId))/\(Self.encodedSegment(episodeId))", method: "GET")
        return data.flatMap { try? JSONDecoder().decode(MediaProgress.self, from: $0) }
    }

    /// Same percent-encoding as the file-private `pc` in AudiobookshelfAPI.swift.
    private static func encodedSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
