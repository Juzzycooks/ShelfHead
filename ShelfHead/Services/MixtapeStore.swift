import Foundation

/// Batch 458: the user's mixtapes, one JSON file in Application Support holding every account's
/// list keyed by `DownloadManager.currentScopeKey()` (same scoping as `BookmarkNotesStore`).
/// Tiny file, rewritten on every change.
@MainActor
@Observable
final class MixtapeStore {
    static let shared = MixtapeStore()

    private var byScope: [String: [Mixtape]] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let scopeProvider: () -> String

    /// Bumped on every change so views observing `mixtapes` refresh even though the scope key is computed.
    private(set) var revision = 0

    init(fileURL: URL? = MixtapeStore.defaultFileURL,
         scopeProvider: @escaping () -> String = { DownloadManager.shared.currentScopeKey() }) {
        self.fileURL = fileURL
        self.scopeProvider = scopeProvider
    }

    nonisolated static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("ShelfHead", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mixtapes.json")
    }

    private var scope: String { scopeProvider() }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        byScope = (try? decoder.decode([String: [Mixtape]].self, from: data)) ?? [:]
    }

    private func save() {
        revision += 1
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(byScope) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Newest-edited first.
    var mixtapes: [Mixtape] {
        _ = revision
        loadIfNeeded()
        return (byScope[scope] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func mixtape(id: UUID) -> Mixtape? {
        loadIfNeeded()
        return byScope[scope]?.first { $0.id == id }
    }

    @discardableResult
    func create(title: String, clips: [MixtapeClip] = []) -> Mixtape {
        loadIfNeeded()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = Mixtape(title: trimmed.isEmpty ? String(localized: "Untitled Mixtape", comment: "Default title for a new mixtape") : trimmed,
                           clips: Array(clips.prefix(MixtapeOps.maxClips)))
        byScope[scope, default: []].append(made)
        save()
        return made
    }

    /// Replace by id (or insert when new, as an import does).
    func upsert(_ mixtape: Mixtape) {
        loadIfNeeded()
        var list = byScope[scope] ?? []
        if let i = list.firstIndex(where: { $0.id == mixtape.id }) { list[i] = mixtape } else { list.append(mixtape) }
        byScope[scope] = list
        save()
    }

    /// False when the mixtape is full (25 clips) or missing.
    @discardableResult
    func add(_ clip: MixtapeClip, to id: UUID) -> Bool {
        guard let current = mixtape(id: id), let updated = MixtapeOps.appending(clip, to: current) else { return false }
        upsert(updated)
        return true
    }

    func move(_ id: UUID, from source: IndexSet, to destination: Int) {
        guard let current = mixtape(id: id) else { return }
        upsert(MixtapeOps.moving(current, from: source, to: destination))
    }

    func removeClips(_ id: UUID, at offsets: IndexSet) {
        guard let current = mixtape(id: id) else { return }
        upsert(MixtapeOps.removing(current, at: offsets))
    }

    func rename(_ id: UUID, to title: String) {
        guard let current = mixtape(id: id) else { return }
        upsert(MixtapeOps.renamed(current, to: title))
    }

    func delete(_ id: UUID) {
        loadIfNeeded()
        byScope[scope]?.removeAll { $0.id == id }
        save()
    }
}
