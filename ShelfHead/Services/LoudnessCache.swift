import Foundation

/// Batch 438: per-book integrated loudness (LUFS), measured once from a downloaded file by
/// `LoudnessMeter` and kept as a small JSON file in Application Support. The leveller uses it as its
/// starting gain so a book begins matched instead of converging over the first seconds.
nonisolated final class LoudnessCache: @unchecked Sendable {
    static let shared = LoudnessCache()

    struct Entry: Codable, Equatable {
        var lufs: Double
        var measuredSeconds: Double
        var date: Date
    }

    private struct FileModel: Codable {
        var version = 1
        var items: [String: Entry] = [:]
    }

    /// Cap so the file stays small however many books are played.
    static let maxEntries = 500

    private let lock = NSLock()
    private var model = FileModel()
    private var loaded = false
    private var inFlight: Set<String> = []
    private let url: URL?

    init(url: URL? = LoudnessCache.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LoudnessCache.json")
    }

    /// Gain (dB) that brings `lufs` to `target`, limited to +/-`maxGain`. Pure.
    static func startingGainDB(forLoudness lufs: Double, target: Double = -18, maxGain: Double = 9) -> Double {
        LoudnessLeveller.clampedGain(target: target, measured: lufs, max: maxGain)
    }

    func loudness(forItem itemId: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return model.items[itemId]?.lufs
    }

    func store(_ lufs: Double, measuredSeconds: Double, forItem itemId: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        model.items[itemId] = Entry(lufs: lufs, measuredSeconds: measuredSeconds, date: Date())
        if model.items.count > Self.maxEntries {
            let oldest = model.items.sorted { $0.value.date < $1.value.date }.prefix(model.items.count - Self.maxEntries)
            for (key, _) in oldest { model.items.removeValue(forKey: key) }
        }
        save()
    }

    func remove(itemId: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if model.items.removeValue(forKey: itemId) != nil { save() }
    }

    /// Measures `fileURL` in the background if the book has no cached figure yet and stores the result.
    /// Returns the loudness (cached or fresh), or nil if it couldn't be measured.
    @discardableResult
    func ensureMeasured(itemId: String, fileURL: URL, maxSeconds: Double = 600) async -> Double? {
        if let cached = loudness(forItem: itemId) { return cached }
        guard beginFlight(itemId) else { return nil }
        defer { endFlight(itemId) }
        let lufs = await Task.detached(priority: .utility) {
            LoudnessMeter.measure(fileURL: fileURL, maxSeconds: maxSeconds)
        }.value
        guard let lufs else { return nil }
        store(lufs, measuredSeconds: maxSeconds, forItem: itemId)
        return lufs
    }

    private func beginFlight(_ itemId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(itemId).inserted
    }

    private func endFlight(_ itemId: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(itemId)
    }

    // Callers hold `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FileModel.self, from: data) else { return }
        model = decoded
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(model) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
