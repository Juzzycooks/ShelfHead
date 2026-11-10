import Foundation
import Observation

/// Batch 444: files handed to the app from outside ("Open in ShelfHead", Share sheet) wait here until
/// the Upload screen takes them. `ContentView` appends from `.onOpenURL` (after App Lock) and
/// presents the screen; `UploadView` drains `pendingFiles` into its view model.
@MainActor @Observable
final class UploadInbox {
    static let shared = UploadInbox()
    var pendingFiles: [URL] = []

    func receive(_ urls: [URL]) {
        for url in urls where url.isFileURL && !pendingFiles.contains(url) { pendingFiles.append(url) }
    }

    func drain() -> [URL] {
        defer { pendingFiles = [] }
        return pendingFiles
    }

    /// True for the document types the app declares it can open for upload.
    nonisolated static func isUploadable(_ url: URL) -> Bool {
        url.isFileURL && UploadViewModel.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Batch 444: one file queued for upload.
struct UploadFileEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let size: Int64
    var name: String { url.lastPathComponent }
}

/// Batch 444: state behind the Upload screen. Only usable by an account that may upload
/// (`User.canUpload`); the screen shows an explanation otherwise.
@MainActor @Observable
final class UploadViewModel {

    enum Phase: Equatable {
        case loading
        case notPermitted
        case editing
        case preparing
        case uploading(sent: Int64, total: Int64)
        case done
        case failed(String)
    }

    /// Audio, EPUB and PDF: what Audiobookshelf's own upload accepts for books.
    nonisolated static let supportedExtensions: Set<String> = [
        "m4b", "m4a", "mp3", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "mp4",
        "epub", "pdf", "cue", "jpg", "jpeg", "png",
    ]

    private(set) var phase: Phase = .loading
    private(set) var libraries: [Library] = []
    private(set) var files: [UploadFileEntry] = []
    private(set) var isAdmin = false
    private(set) var isScanning = false
    private(set) var scanned = false
    private(set) var suggestedSequence: String?

    var libraryId = ""
    var folderId = ""
    var title = ""
    var author = ""
    var series = ""

    /// The user edited a field by hand, so a later metadata read must not overwrite it.
    private var edited: Set<String> = []
    // Review 2 Medium 9 (30 October 2026): ignored + nonisolated(unsafe) so `deinit` can clean up
    // when the view lets go of the model (a real dismissal), not when a tab switch hides it.
    @ObservationIgnored nonisolated(unsafe) private var scopedURLs: [URL] = []
    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var bodyFile: URL?
    @ObservationIgnored private var uploadRun: UUID?   // Review 5 Low (stale upload task)

    // Review 4 Medium 4: cancel an in-flight upload when the account changes.
    @ObservationIgnored nonisolated(unsafe) private var accountObserver: NSObjectProtocol?

    init() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .shelfheadAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        }
    }

    nonisolated private static let accountChangedMessage = String(localized: "The account changed, so the upload was cancelled.",
                                                      comment: "Upload screen error when the user switches server accounts mid-upload")

    /// Bumped on an account change; a `load` that started before it drops its result.
    @ObservationIgnored private var loadGeneration = 0

    private func accountChanged() {
        // Review 5 Low (upload back): drop the old account's ids so the form can't submit them.
        libraries = []; libraryId = ""; folderId = ""; isAdmin = false
        loadGeneration += 1   // Review 5 Low (upload back): an old account's load still in flight drops its result
        switch phase {
        case .preparing, .uploading:
            task?.cancel()
            task = nil
            uploadRun = nil
            phase = .failed(Self.accountChangedMessage)
        case .editing, .done, .notPermitted, .loading:
            phase = .loading
            Task { await load(user: nil, preferredLibraryId: nil) }
        default: break
        }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        task?.cancel()
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) }
    }

    var selectedLibrary: Library? { libraries.first { $0.id == libraryId } }
    var folders: [LibraryFolder] { selectedLibrary?.folders ?? [] }
    var isPodcastLibrary: Bool { selectedLibrary?.mediaType == "podcast" }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    var form: UploadForm {
        UploadForm(title: title, author: isPodcastLibrary ? "" : author, series: isPodcastLibrary ? "" : series,
                   libraryId: libraryId, folderId: folderId,
                   files: files.map { UploadForm.File(url: $0.url, filename: $0.name) })
    }

    var canStart: Bool { phase == .editing && form.isValid }

    // MARK: Loading

    func load(user: User?, preferredLibraryId: String?) async {
        guard phase == .loading else { return }
        let myGeneration = loadGeneration
        let me: User?
        if let user { me = user } else { me = try? await AudiobookshelfAPI.shared.getCurrentUser() }
        guard myGeneration == loadGeneration else { return }
        guard let me, me.canUpload else { phase = .notPermitted; return }
        isAdmin = me.isAdmin
        do {
            let fetched = try await AudiobookshelfAPI.shared.getLibraries().filter { !($0.folders ?? []).isEmpty }
            guard myGeneration == loadGeneration else { return }
            libraries = fetched
        } catch {
            guard myGeneration == loadGeneration else { return }
            phase = .failed(Self.message(for: error))
            return
        }
        guard !libraries.isEmpty else { phase = .failed(String(localized: "This server has no library folders to upload into.")); return }
        libraryId = libraries.first { $0.id == preferredLibraryId }?.id ?? libraries[0].id
        selectFirstFolder()
        phase = .editing
    }

    func libraryChanged() { selectFirstFolder() }

    private func selectFirstFolder() {
        if !folders.contains(where: { $0.id == folderId }) { folderId = folders.first?.id ?? "" }
    }

    // MARK: Files

    /// Adds picked or incoming files. Holds each URL's security scope open until the upload ends
    /// or the file is removed, so the multipart body can be written straight from the original.
    func addFiles(_ urls: [URL]) {
        var added = false
        for url in urls where url.isFileURL && !files.contains(where: { $0.url == url }) {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            files.append(UploadFileEntry(url: url, size: size))
            added = true
        }
        if added { suggestFromFiles() }
    }

    func remove(_ entry: UploadFileEntry) {
        files.removeAll { $0.id == entry.id }
        release(entry.url)
        if files.isEmpty { clearUnedited() } else { suggestFromFiles() }
    }

    private func release(_ url: URL) {
        if let i = scopedURLs.firstIndex(of: url) {
            url.stopAccessingSecurityScopedResource()
            scopedURLs.remove(at: i)
        }
    }

    func markEdited(_ field: String) { edited.insert(field) }

    private func clearUnedited() {
        if !edited.contains("title") { title = "" }
        if !edited.contains("author") { author = "" }
        if !edited.contains("series") { series = "" }
        suggestedSequence = nil
    }

    private func suggestFromFiles() {
        let urls = files.map(\.url)
        Task {
            let found = await UploadMetadataReader.read(files: urls)
            guard urls == files.map(\.url) else { return }   // the list changed while reading
            if !edited.contains("title"), let t = found.title { title = t }
            if !edited.contains("author"), let a = found.author { author = a }
            if !edited.contains("series"), let s = found.series { series = s }
            suggestedSequence = found.sequence
        }
    }

    // MARK: Upload

    func start() {
        guard canStart else { return }
        let form = self.form
        let scope = PendingBookmarkQueue.currentScope() // Review 4 Medium 4
        phase = .preparing
        let run = UUID()
        uploadRun = run
        task = Task { [weak self] in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).body")
            self?.bodyFile = temp
            // Review Medium 32 (30 October 2026): delete the temporary copy however this task
            // ends, including when the view model is already gone and `finish` can't run.
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let body = MultipartBody(parts: form.parts)
                // Written off the main actor: a 500 MB copy takes a while.
                let total = try await Task.detached(priority: .userInitiated) { try body.write(to: temp) }.value
                try Task.checkCancellation()
                self?.phase = .uploading(sent: 0, total: total)
                try await AudiobookshelfAPI.shared.uploadMultipart(body: body, bodyFile: temp, expectedScope: scope) { sent, expected in
                    Task { @MainActor in self?.progressed(sent: sent, expected: expected) }
                }
                self?.finish(.done, removing: temp, run: run)
            } catch is CancellationError {
                self?.finish(.editing, removing: temp, run: run)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(.editing, removing: temp, run: run)
            } catch {
                self?.finish(.failed(Self.message(for: error)), removing: temp, run: run)
            }
        }
    }

    private func progressed(sent: Int64, expected: Int64) {
        guard case .uploading = phase else { return }
        phase = .uploading(sent: sent, total: expected)
    }

    private func finish(_ phase: Phase, removing temp: URL, run: UUID) {
        try? FileManager.default.removeItem(at: temp)
        guard run == uploadRun else { return }   // Review 5 Low (stale upload task): superseded run
        bodyFile = nil
        // Review 4 Medium 4: a cancel caused by an account switch already set its own message.
        if case .failed = self.phase, phase == .editing { return }
        self.phase = phase
        if phase == .done { releaseAll() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Back to the form after an error, keeping every field and file.
    func backToEditing() {
        // Review 5 Low (upload back): after an account change the old libraries are gone; reload for the new account.
        if libraries.isEmpty {
            phase = .loading
            Task { await load(user: nil, preferredLibraryId: nil) }
        } else {
            phase = .editing
        }
    }

    /// After a success: ready for another upload.
    func reset() {
        files = []
        edited = []
        title = ""; author = ""; series = ""
        suggestedSequence = nil
        scanned = false
        phase = .editing
    }

    func scanLibrary() async {
        guard !libraryId.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try await AudiobookshelfAPI.shared.scanLibrary(libraryId: libraryId)
            scanned = true
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func releaseAll() {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    // Review 3 Low (upload): `tearDown()` removed, dead since Batch 473.

    // MARK: Errors

    nonisolated static func message(for error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .forbidden:
                return String(localized: "This account isn't allowed to upload to that library.")
            case .notFound:
                return String(localized: "The library or folder no longer exists on the server.")
            case .httpError(400):
                return String(localized: "The server rejected the upload. Check the title and files.")
            case .serverError:
                return String(localized: "The server couldn't save the files. Check its disk space and permissions.")
            default:
                return api.errorDescription ?? error.localizedDescription
            }
        }
        if error is AccountChangedError { return accountChangedMessage }   // Review 5 Low (upload error text)
        return error.localizedDescription
    }
}
