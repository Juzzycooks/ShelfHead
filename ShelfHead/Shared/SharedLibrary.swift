import Foundation

/// A small, bounded set of books the widget is allowed to show, published into the App
/// Group by the main app.
///
/// The widget extension can't reach the library: `AudiobookshelfAPI` needs credentials and
/// a network round trip, and downloaded covers/manifests live in the app's *own*
/// Application Support container (`DownloadManager.applicationSupportDownloadsRoot()`),
/// not the shared one. Before this existed, the only thing crossing that boundary was
/// `SharedPlayback` — the current session plus a single `widget_cover.jpg` — which is why
/// the widget could only ever render "now playing".
///
/// This is the minimum needed for a `WidgetConfigurationIntent` to offer real choices:
/// enough metadata to draw a card, plus a per-book cover file. Deliberately **capped**
/// (`maxBooks`) and limited to books the user is actually part-way through, rather than
/// mirroring the catalogue — an unbounded mirror would grow the App Group container
/// without limit, go stale against the server, and duplicate cover bytes the app already
/// stores elsewhere.
///
/// Like `SharedPlayback.swift`, this single file is added to **both** the app and widget
/// targets' Sources build phases rather than being hand-copied. It still crosses a JSON
/// boundary between two independently-built targets, so a change here has to remain
/// something both sides can agree on — `Payload` decodes field-by-field with defaults for
/// exactly that reason.
enum SharedLibrary {

    /// At most this many books are offered in the widget's picker. Fifteen is roughly the
    /// depth of a real Continue Listening shelf; past that the picker stops being a list
    /// someone scans and the cover files stop being a rounding error.
    static let maxBooks = 15

    private static let key = "sharedLibrary"
    private static let coversDirectoryName = "widget_covers"

    /// One pickable book. Progress is carried as a snapshot rather than recomputed, since
    /// the widget has no way to refresh it — it is as current as the last publish.
    struct PinnableBook: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let author: String
        let currentTime: Double
        let duration: Double
        let updatedAt: Date

        var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }
    }

    struct Payload: Codable, Sendable, Equatable {
        var books: [PinnableBook] = []
        /// Ids of the Up Next queue, most immediate first. Every id here also appears in
        /// `books`, so the widget never has to resolve one against data it doesn't have.
        var upNextIds: [String] = []

        init(books: [PinnableBook] = [], upNextIds: [String] = []) {
            self.books = books
            self.upNextIds = upNextIds
        }

        /// Field-by-field with defaults: a payload written by an older or newer build must
        /// degrade to "fewer options" rather than failing to decode and blanking the
        /// widget's picker entirely.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            books = (try? c.decode([PinnableBook].self, forKey: .books)) ?? []
            upNextIds = (try? c.decode([String].self, forKey: .upNextIds)) ?? []
        }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedPlayback.appGroup) }
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedPlayback.appGroup)
    }
    private static var coversDirectory: URL? {
        containerURL?.appendingPathComponent(coversDirectoryName, isDirectory: true)
    }

    // MARK: - Payload

    static func write(_ payload: Payload) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }

    static func read() -> Payload {
        guard let data = defaults?.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return Payload() }
        return payload
    }

    /// Clears everything — payload and every cover file. Called on sign-out and account
    /// switch, so one account's books can never be offered while another is signed in.
    static func clear() {
        defaults?.removeObject(forKey: key)
        if let coversDirectory {
            try? FileManager.default.removeItem(at: coversDirectory)
        }
    }

    // MARK: - Covers

    /// Cover file for `itemId`. The id is hashed rather than used directly: it comes from
    /// the server, and this builds a path. `DownloadPaths.sanitizedPathComponent` already
    /// solves this on the app side, but it isn't in the widget target — and a hash is
    /// sufficient here because nothing needs to recover the id from the filename.
    private static func coverURL(for itemId: String) -> URL? {
        coversDirectory?.appendingPathComponent("\(stableFilename(for: itemId)).jpg")
    }

    /// FNV-1a over the id's UTF-8. Not cryptographic — it only needs to be stable across
    /// launches and both targets, and collision-resistant enough for a set capped at
    /// `maxBooks`.
    private static func stableFilename(for itemId: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in itemId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    static func writeCover(_ data: Data, for itemId: String) {
        guard let coversDirectory, let coverURL = coverURL(for: itemId) else { return }
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try? data.write(to: coverURL, options: .atomic)
    }

    static func readCover(for itemId: String) -> Data? {
        guard let coverURL = coverURL(for: itemId) else { return nil }
        return try? Data(contentsOf: coverURL)
    }

    static func hasCover(for itemId: String) -> Bool {
        guard let coverURL = coverURL(for: itemId) else { return false }
        return FileManager.default.fileExists(atPath: coverURL.path)
    }

    /// Deletes cover files for books no longer in the published set. Without this the
    /// directory would only ever grow, since a book leaving Continue Listening (finished,
    /// or pushed off the end) otherwise leaves its cover behind forever.
    static func pruneCovers(keeping ids: Set<String>) {
        guard let coversDirectory,
              let existing = try? FileManager.default.contentsOfDirectory(
                at: coversDirectory, includingPropertiesForKeys: nil) else { return }
        let keep = Set(ids.map { "\(stableFilename(for: $0)).jpg" })
        for file in existing where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
