import Foundation

/// Batch 444: small server calls beside the multipart upload (`uploadMultipart` in
/// `AudiobookshelfAPI.swift`).
extension AudiobookshelfAPI {

    /// `POST /api/libraries/:id/scan`. The server needs a root/admin account (a 403 otherwise) and
    /// answers `{ "success": true }`-style JSON once the scan is queued. An uploaded book only shows
    /// up in the library after a scan (or the server's folder watcher, which many installs run
    /// without); confirmed on the local test server.
    func scanLibrary(libraryId: String) async throws {
        let escaped = libraryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? libraryId
        _ = try await send(path: "/api/libraries/\(escaped)/scan", method: "POST")
    }
}
