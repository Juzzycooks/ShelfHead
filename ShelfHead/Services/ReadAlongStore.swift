import Foundation

/// Batch 431: builds and caches the read-along map (`ReadAlongMap`) for a book, in the
/// book's transcript folder (`readalong.json`).
enum ReadAlongStore {
    private nonisolated static func fileURL(itemId: String, scopeKey: String) -> URL {
        TranscriptStore.itemDirectory(itemId: itemId, scopeKey: scopeKey)
            .appendingPathComponent("readalong.json")
    }

    /// The cached map if its key matches.
    nonisolated static func cachedMap(itemId: String, key: String) -> ReadAlongMap? {
        let url = fileURL(itemId: itemId, scopeKey: TranscriptStore.currentScopeKey())
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode(ReadAlongMap.self, from: data),
              map.version == ReadAlongMap.currentVersion, map.key == key else { return nil }
        return map
    }

    /// The cached map, or a freshly built and saved one. Nil if the ebook can't be read.
    @concurrent nonisolated static func map(itemId: String, ebookURL: URL, transcript: Transcript) async -> ReadAlongMap? {
        let scopeKey = TranscriptStore.currentScopeKey() // Review 4 Low (scope at save time): capture before the long work
        let size = (try? FileManager.default.attributesOfItem(atPath: ebookURL.path)[.size] as? Int) ?? 0
        let key = ReadAlongMapBuilder.fingerprint(transcript: transcript, ebookByteCount: size)
        if let cached = cachedMap(itemId: itemId, key: key) { return cached }
        let started = Date()
        do {
            let data = try Data(contentsOf: ebookURL, options: .mappedIfSafe)
            let zip = try ZipReader(data: data)
            let package = try EPUBPackage(zip: zip)
            var spineBlocks: [[String]] = []
            spineBlocks.reserveCapacity(package.spine.count)
            for item in package.spine {
                if let xhtml = try? zip.data(for: item.href) {
                    spineBlocks.append(EPUBTextExtractor.blocks(fromXHTML: xhtml))
                } else {
                    spineBlocks.append([])
                }
            }
            let map = ReadAlongMapBuilder.build(segments: transcript.segments, spineBlocks: spineBlocks, key: key)
            save(map, itemId: itemId, scopeKey: scopeKey)
            ShelfLog.info(.storage, "Read-along map built in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, matched \(Int(map.matchedFraction * 100))%")
            return map
        } catch {
            ShelfLog.error(.storage, "Read-along map failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func save(_ map: ReadAlongMap, itemId: String, scopeKey: String) {
        let url = fileURL(itemId: itemId, scopeKey: scopeKey)
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            ShelfLog.error(.storage, "Read-along map save failed: \(error.localizedDescription)")
        }
    }
}
