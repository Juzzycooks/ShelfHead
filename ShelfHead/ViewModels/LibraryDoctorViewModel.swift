import Foundation

/// Batch 441: drives the Library Doctor screen. Loads the whole library once (through
/// `AudiobookshelfAPI.fetchAllLibraryItems`, the same paged fetch the smart filters use), runs
/// `LibraryDoctor` over it, and applies confirmed fixes. Nothing is ever deleted; each write goes
/// through `AudiobookshelfAPI`, then that one item is re-fetched and the findings recomputed.
@MainActor
@Observable
final class LibraryDoctorViewModel {

    enum Phase: Equatable {
        case idle
        case checkingAccess
        /// The signed-in user can't update the library.
        case notPermitted
        case scanning(loaded: Int, total: Int)
        case ready
        case failed(String)
    }

    /// A write waiting for the user's confirmation, with its before and after.
    struct PendingChange: Identifiable, Equatable {
        enum Kind: Equatable {
            case cover(URL)
            case sequence(series: String, value: String)
            case chapters([Chapter])
        }
        let id = UUID()
        let itemId: String
        let title: String
        let kind: Kind
        let before: String
        let after: String

        static func == (a: PendingChange, b: PendingChange) -> Bool { a.id == b.id }
    }

    var phase: Phase = .idle
    private(set) var findings: [DoctorFinding] = []
    private(set) var scannedCount = 0
    /// Set while a write is in flight.
    var isApplying = false
    /// A message about the last write, shown in the fix sheet.
    var actionError: String?

    // Cover search
    var coverCandidates: [URL] = []
    var isSearchingCovers = false
    var coverSearchNote: String?

    private var items: [String: LibraryItem] = [:]
    private var order: [String] = []
    private var scanTask: Task<Void, Never>?
    private let libraryId: String?

    init(libraryId: String?) { self.libraryId = libraryId }

    var grouped: [(kind: DoctorFindingKind, findings: [DoctorFinding])] {
        DoctorFindingKind.allCases.compactMap { kind in
            let list = findings.filter { $0.kind == kind }
            return list.isEmpty ? nil : (kind, list)
        }
    }

    func item(_ id: String) -> LibraryItem? { items[id] }

    func title(_ id: String) -> String {
        items[id]?.media?.metadata?.title ?? items[id]?.title ?? id
    }

    // MARK: Scan

    func start(user: User?) {
        guard phase == .idle || phase == .notPermitted || isFailed else { return }
        scanTask?.cancel()
        scanTask = Task { await run(user: user) }
    }

    func rescan() {
        scanTask?.cancel()
        scanTask = Task { await run(user: nil, skipAccessCheck: true) }
    }

    func cancel() { scanTask?.cancel() }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private func run(user: User?, skipAccessCheck: Bool = false) async {
        guard let libraryId else { phase = .failed(String(localized: "No library is selected.")); return }
        if !skipAccessCheck {
            phase = .checkingAccess
            var resolved = user
            if resolved?.permissions == nil && resolved?.type == nil {
                resolved = try? await AudiobookshelfAPI.shared.getCurrentUser()
            }
            guard resolved?.canUpdateLibrary == true else { phase = .notPermitted; return }
        }
        phase = .scanning(loaded: 0, total: 0)
        do {
            let fetched = try await AudiobookshelfAPI.shared.fetchAllLibraryItems(libraryId: libraryId) { [weak self] loaded, total in
                Task { @MainActor [weak self] in
                    guard let self, case .scanning = self.phase else { return }
                    self.phase = .scanning(loaded: loaded, total: total)
                }
            }
            try Task.checkCancellation()
            items = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            order = fetched.map(\.id)
            scannedCount = fetched.count
            recompute()
            phase = .ready
        } catch is CancellationError {
            if case .scanning = phase { phase = .idle }
        } catch {
            if (error as? URLError)?.code == .cancelled { phase = .idle; return }
            phase = Self.phase(for: error)
        }
    }

    private static func phase(for error: Error) -> Phase {
        if case APIError.forbidden = error { return .notPermitted }
        return .failed(error.localizedDescription)
    }

    private func recompute() {
        let books = order.compactMap { items[$0] }
        findings = LibraryDoctor.diagnose(items: books)
    }

    // MARK: Cover fix

    func searchCovers(for itemId: String) async {
        coverCandidates = []
        coverSearchNote = nil
        guard let item = items[itemId], let title = item.media?.metadata?.title else { return }
        isSearchingCovers = true
        defer { isSearchingCovers = false }
        let author = item.media?.metadata?.authorName
        var found: [URL] = []
        var failedProviders = 0
        for provider in ["audible", "google"] {
            do {
                for url in try await AudiobookshelfAPI.shared.searchCovers(title: title, author: author, provider: provider)
                where !found.contains(url) {
                    found.append(url)
                }
            } catch {
                failedProviders += 1
            }
            if found.count >= 12 { break }
        }
        coverCandidates = Array(found.prefix(24))
        if found.isEmpty {
            coverSearchNote = failedProviders == 2
                ? String(localized: "Cover search failed. Check the server's connection to Audible and Google.")
                : String(localized: "No covers found for this title.")
        }
    }

    func proposeCover(itemId: String, url: URL) -> PendingChange {
        PendingChange(itemId: itemId, title: title(itemId), kind: .cover(url),
                      before: String(localized: "No cover"), after: url.host ?? url.absoluteString)
    }

    // MARK: Sequence fix

    func proposeSequence(itemId: String, series: String, value: String) -> PendingChange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed.replacingOccurrences(of: ",", with: ".")), number.isFinite, number >= 0 else { return nil }
        let formatted = SeriesSequenceFormat.string(number)
        return PendingChange(itemId: itemId, title: title(itemId), kind: .sequence(series: series, value: formatted),
                             before: String(localized: "\(series): no number"),
                             after: "\(series) #\(formatted)")
    }

    func proposedSequence(for finding: DoctorFinding) -> String {
        if case .setSequence(_, _, let value)? = finding.fix { return SeriesSequenceFormat.string(value) }
        return ""
    }

    // MARK: Chapter fix

    /// The chapters accepted on this device for the book, if any.
    func localChapters(itemId: String) -> [Chapter]? {
        guard let override = ChapterOverrideStore.load(itemId: itemId), !override.chapters.isEmpty else { return nil }
        return override.chapters
    }

    func proposeChapters(itemId: String) -> PendingChange? {
        guard let chapters = localChapters(itemId: itemId) else { return nil }
        let current = items[itemId]?.media?.chapters?.count ?? items[itemId]?.media?.numChapters ?? 0
        return PendingChange(itemId: itemId, title: title(itemId), kind: .chapters(chapters),
                             before: String(localized: "\(current) chapters on the server"),
                             after: String(localized: "\(chapters.count) chapters from this device"))
    }

    // MARK: Apply

    /// Sends the confirmed change. Returns true on success.
    @discardableResult
    func apply(_ change: PendingChange) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        actionError = nil
        defer { isApplying = false }
        let api = AudiobookshelfAPI.shared
        do {
            switch change.kind {
            case .cover(let url):
                try await api.setCover(itemId: change.itemId, url: url)
            case .sequence(let series, let value):
                try await api.setSeriesSequence(itemId: change.itemId, seriesName: series, sequence: value)
            case .chapters(let chapters):
                try await api.setChapters(itemId: change.itemId, chapters: chapters)
            }
        } catch {
            actionError = Self.message(for: error)
            ShelfLog.error(.network, "Library Doctor write failed: \(error.localizedDescription)")
            return false
        }
        // Refresh just this item, then recheck. A failed refresh leaves the write done but the list stale.
        if let fresh = try? await api.getItem(itemId: change.itemId) {
            items[change.itemId] = fresh
            recompute()
        }
        return true
    }

    static func message(for error: Error) -> String {
        if case APIError.forbidden = error {
            return String(localized: "The server says this account isn\u{2019}t allowed to do that. Changing covers needs the upload permission; metadata and chapters need the update permission.")
        }
        return error.localizedDescription
    }
}
