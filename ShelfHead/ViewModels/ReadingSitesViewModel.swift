import SwiftUI
import UniformTypeIdentifiers

/// Batch 443: a CSV file handed to `ShareLink` (written to a temp file on demand).
struct FinishedBooksCSV: Transferable {
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfHead-finished-books.csv")
            try Data(file.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Batch 443: Settings › Reading Sites. Connect Hardcover, import want-to-read, export finished books.
@MainActor
@Observable
final class ReadingSitesViewModel {
    enum Phase: Equatable { case idle, working, done(String), failed(String) }

    var tokenInput = ""
    var username: String?
    var connectPhase: Phase = .idle
    var importPhase: Phase = .idle
    private(set) var wantToRead: [WantToReadEntry] = WantToReadStore.load()
    private(set) var isConnected = SettingsStore.readingSiteConnected

    private let api = HardcoverAPI.shared

    // MARK: Connection

    func connect() async {
        let token = HardcoverAPI.cleanedToken(tokenInput)
        guard !token.isEmpty else { return }
        connectPhase = .working
        do {
            try await api.saveToken(token)
            let name = try await api.me()
            username = name
            tokenInput = ""
            isConnected = true
            SettingsStore.readingSiteConnected = true
            connectPhase = .done(String(localized: "Connected as \(name)", comment: "Reading sites; %@ is a Hardcover username"))
        } catch {
            await api.deleteToken()
            isConnected = false
            SettingsStore.readingSiteConnected = false
            ShelfLog.error(.network, "Hardcover connect failed: \(error.localizedDescription)")
            connectPhase = .failed(String(localized: "Can’t reach Hardcover. Check your token and connection, then try again.", comment: "Reading sites; connect/test/import failed"))
        }
    }

    func testConnection() async {
        connectPhase = .working
        do {
            let name = try await api.me()
            username = name
            connectPhase = .done(String(localized: "Connected as \(name)", comment: "Reading sites; %@ is a Hardcover username"))
        } catch {
            ShelfLog.error(.network, "Hardcover connect failed: \(error.localizedDescription)")
            connectPhase = .failed(String(localized: "Can’t reach Hardcover. Check your token and connection, then try again.", comment: "Reading sites; connect/test/import failed"))
        }
    }

    func disconnect() async {
        await api.deleteToken()
        isConnected = false
        username = nil
        connectPhase = .idle
        SettingsStore.readingSiteConnected = false
        // Sync stays off until the user connects and turns it back on.
        for key in [SettingsKeys.readingSiteSyncProgress, SettingsKeys.readingSiteMarkFinished, SettingsKeys.readingSiteAskRating] {
            UserDefaults.standard.set(false, forKey: key)
        }
        ReadingSiteSync.shared.resetCache()
    }

    // MARK: Import

    func importFromHardcover() async {
        importPhase = .working
        do {
            let entries = try await api.wantToRead()
            absorb(entries)
        } catch {
            ShelfLog.error(.network, "Hardcover import failed: \(error.localizedDescription)")
            importPhase = .failed(String(localized: "Can’t reach Hardcover. Check your token and connection, then try again.", comment: "Reading sites; connect/test/import failed"))
        }
    }

    func importCSV(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            importPhase = .failed(String(localized: "Couldn’t read that file.", comment: "Reading sites import error"))
            return
        }
        let entries = ReadingListCSV.wantToRead(fromCSV: text)
        if entries.isEmpty {
            importPhase = .failed(String(localized: "No want-to-read books found. Use a Goodreads or StoryGraph export.", comment: "Reading sites import error"))
        } else {
            absorb(entries)
        }
    }

    private func absorb(_ entries: [WantToReadEntry]) {
        let merged = ReadingListCSV.merged(wantToRead, with: entries)
        let added = merged.count - wantToRead.count
        wantToRead = merged
        WantToReadStore.save(merged)
        importPhase = .done(String(localized: "Added \(added.formatted()) books to Want to Read.", comment: "Reading sites; number of books newly imported"))
    }

    func clearWantToRead() {
        wantToRead = []
        WantToReadStore.save([])
        importPhase = .idle
    }

    func remove(_ entry: WantToReadEntry) {
        wantToRead.removeAll { $0.id == entry.id }
        WantToReadStore.save(wantToRead)
    }

    // MARK: Export

    /// Finished books from the loaded library, as a Goodreads-format CSV.
    func finishedBooksCSV(library: LibraryViewModel) -> FinishedBooksCSV {
        let rows: [FinishedBookRow] = library.items.compactMap { item in
            guard !item.isPodcast else { return nil }
            let progress = library.progressFor(itemId: item.id) ?? item.mediaProgress
            guard progress?.isFinished == true else { return nil }
            let date = progress?.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            return FinishedBookRow(title: item.title, author: item.authorName, isbn: item.media?.metadata?.isbn,
                                   rating: nil, dateRead: date)
        }
        return FinishedBooksCSV(text: ReadingListCSV.exportFinished(items: rows))
    }

    func finishedCount(library: LibraryViewModel) -> Int {
        library.items.filter { !$0.isPodcast && (library.progressFor(itemId: $0.id) ?? $0.mediaProgress)?.isFinished == true }.count
    }
}

/// The imported want-to-read list, kept in Application Support.
enum WantToReadStore {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("want-to-read.json")
    }

    static func load() -> [WantToReadEntry] {
        guard let url, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([WantToReadEntry].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [WantToReadEntry]) {
        guard let url, let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
