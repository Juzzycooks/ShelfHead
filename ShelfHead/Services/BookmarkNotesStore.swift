import Foundation

/// Local-only free-text notes on a bookmark, keyed by the bookmark's `id`
/// (`"\(libraryItemId)-\(time.safeSeconds)"`) and scoped per account via
/// `DownloadManager.currentScopeKey()`.
///
/// The server's `AudioBookmark` only has `title` (which this app's edit UI already
/// calls a "note") and `time` — there's no field on the server for a longer free-text
/// note, so this exists to hold one locally rather than overload `title` further.
/// Small JSON file in Application Support; loaded lazily, saved on every change (the
/// file is tiny, so a debounced write isn't worth the complexity).
@MainActor
@Observable
final class BookmarkNotesStore {
    static let shared = BookmarkNotesStore()

    /// scopeKey -> (bookmark id -> note)
    private var notesByScope: [String: [String: String]] = [:]
    private var loaded = false

    private init() {}

    private static var storeURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("ShelfHead", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmark-notes.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url) else { return }
        notesByScope = (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func save() {
        loadIfNeeded()
        guard let url = Self.storeURL, let data = try? JSONEncoder().encode(notesByScope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private var scopeKey: String { DownloadManager.shared.currentScopeKey() }

    func note(for bookmark: AudioBookmark) -> String? {
        loadIfNeeded()
        return notesByScope[scopeKey]?[bookmark.id]
    }

    func setNote(_ note: String?, for bookmark: AudioBookmark) {
        loadIfNeeded()
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed?.isEmpty ?? true {
            notesByScope[scopeKey]?.removeValue(forKey: bookmark.id)
        } else {
            notesByScope[scopeKey, default: [:]][bookmark.id] = trimmed
        }
        save()
    }

    /// Every stored note for a given book, keyed by bookmark id — bookmark ids embed
    /// their `libraryItemId` as a prefix (see `AudioBookmark.id`), so this filters on that.
    func notes(forItemId itemId: String) -> [String: String] {
        loadIfNeeded()
        let scoped = notesByScope[scopeKey] ?? [:]
        return scoped.filter { $0.key.hasPrefix("\(itemId)-") }
    }
}

// MARK: - Markdown export

/// Pure formatting/file-writing helpers, split from the store above so they're testable
/// without touching the actor-isolated singleton or the filesystem-backed store.
enum BookmarkMarkdownExporter {
    /// "# <title>\n_<author>_\n\n" then one bookmark line (+ optional note quote lines)
    /// per bookmark, sorted by time. No chapter parenthetical when `chapters` is empty
    /// or none covers a given bookmark's time.
    nonisolated static func markdown(
        bookTitle: String, author: String?, chapters: [Chapter],
        bookmarks: [AudioBookmark], notes: [String: String]
    ) -> String {
        var lines: [String] = ["# \(bookTitle)"]
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("_\(author)_")
        }
        lines.append("")

        let sorted = bookmarks.sorted { $0.time < $1.time }
        for bookmark in sorted {
            var line = "- **\(bookmark.time.formattedTime)**"
            if let chapter = chapters.last(where: { $0.start <= bookmark.time }) {
                let relative = (bookmark.time - chapter.start).formattedTime
                line += " (\(chapter.title) · \(relative))"
            }
            line += " — \(bookmark.title)"
            lines.append(line)
            if let note = notes[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                for noteLine in note.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  > \(noteLine)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Writes `<sanitized stem>-bookmarks.md` to the temp directory for sharing via
    /// `ActivityView`. The stem is sanitised to letters/digits/dashes so an arbitrary
    /// book title can't produce an invalid or surprising filename.
    nonisolated static func writeExportFile(markdown: String, filenameStem: String) -> URL? {
        let sanitizedChars = filenameStem.map { (ch: Character) -> Character in
            (ch.isLetter || ch.isNumber || ch == "-") ? ch : "-"
        }
        var stem = String(sanitizedChars)
        while stem.contains("--") { stem = stem.replacingOccurrences(of: "--", with: "-") }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if stem.isEmpty { stem = "bookmarks" }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)-bookmarks.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
