import SwiftUI
import PDFKit
import QuickLook

/// In-app reader for a library item's ebook file.
///
/// Batch 430: on iOS 26+ an EPUB opens in `EPUBReaderView` (WebKit's SwiftUI `WebPage`,
/// reading straight from the cached file in `EbookStore`); the Quick Look paragraph below
/// still describes iOS 17–25 and CBZ.
///
/// Scope note: Audiobookshelf itself is format-agnostic about ebooks (PDF, EPUB, MOBI,
/// AZW3, CBZ, etc. all just live in `media.ebookFile`). PDF is rendered directly with
/// `PDFKit` (first-party, well-tested). EPUB and CBZ are handed to `QLPreviewController` —
/// the system's own Quick Look reader, which has a built-in EPUB reader and image-archive
/// support — rather than this app writing its own HTML/CSS-based reflowable-text renderer
/// from scratch, which isn't something to attempt blind in an environment with no
/// compiler/device to verify text layout, pagination, or font handling against. MOBI/AZW3
/// (Amazon's proprietary formats) have no reader anywhere in iOS, system or otherwise, so
/// those still get an explicit, honest "not supported" message rather than being handed
/// to Quick Look just to have it show its own "can't open this" screen.
///
/// P-15 (REVIEW_2026-09-14_DESIGN.md): reading position now syncs back to Audiobookshelf
/// for the PDF path only. `QLPreviewController` exposes no current-page/location API for
/// EPUB/CBZ, so nothing is written for those formats — see `persistPDFProgressIfNeeded()`.
struct EbookReaderView: View {
    let item: LibraryItem
    /// Batch 431: open the EPUB following the audio (the player's Read Along item).
    var followsPlayback = false
    /// Batch 431: Listen from Here in the EPUB reader (book time).
    var onListen: ((Double) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var downloadedFileURL: URL?
    /// The cached EPUB file (`EbookStore`) on iOS 26+. Never deleted on dismiss.
    @State private var epubFileURL: URL?
    @State private var pdfDocument: PDFDocument?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// Current page, 0-indexed, and the document's total page count — kept in sync by
    /// `PDFKitView.onPageChanged` as the user scrolls. `pdfPageCount` doubles as "do we
    /// have a PDF worth showing a page indicator / writing progress for" (0 until the
    /// document loads).
    @State private var currentPageIndex = 0
    @State private var pdfPageCount = 0
    /// The page to jump to once the document is loaded — the server's last-known
    /// `ebookLocation` for this item, when present and in range. Read once in `load()`.
    @State private var initialPageIndex: Int?
    /// The page index last written to the server, so `persistPDFProgressIfNeeded()` (called
    /// from both `onDisappear` and a scene-phase change) doesn't fire a redundant network
    /// request when nothing has actually moved since the last write.
    @State private var lastPersistedPageIndex = -1

    private var ebookFile: EbookFile? { item.media?.ebookFile }
    private var fileExtension: String { ebookFile?.metadata?.normalizedExtension ?? "" }
    private var usesEPUBReader: Bool {
        if #available(iOS 26.0, *) { return fileExtension == "epub" }
        return false
    }
    private var isPDF: Bool { fileExtension == "pdf" }
    /// Formats Quick Look can render a genuine preview for out of the box, on-device,
    /// with no bundled/third-party parsing on this app's part.
    private static let quickLookSupportedExtensions: Set<String> = ["epub", "cbz"]
    private var isQuickLookCandidate: Bool { Self.quickLookSupportedExtensions.contains(fileExtension) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                if isLoading {
                    // LS-13 (docs/design-review.md, Round 3): was a bare `ProgressView`
                    // with a caption-style label instead of the shared `LoadingView`
                    // treatment every other loading screen in the app uses.
                    LoadingView("Loading book…")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color.shelfAmberText)
                            // Decorative: the text below already says everything VoiceOver
                            // needs, and `.accessibilityElement(children: .combine)` on the
                            // VStack would otherwise still announce "warning" separately.
                            .accessibilityHidden(true)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(Color.shelfCream)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .accessibilityElement(children: .combine)
                } else if #available(iOS 26.0, *), let epubFileURL {
                    EPUBReaderView(item: item, fileURL: epubFileURL, followsPlayback: followsPlayback, onListen: onListen)
                } else if isPDF, let pdfDocument {
                    PDFKitView(
                        document: pdfDocument,
                        initialPageIndex: initialPageIndex,
                        onPageChanged: { pageIndex, pageCount in
                            currentPageIndex = pageIndex
                            pdfPageCount = pageCount
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        if pdfPageCount > 0 {
                            pageIndicator
                        }
                    }
                } else if let downloadedFileURL, isQuickLookCandidate {
                    QuickLookPreview(url: downloadedFileURL)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Couldn't open this file.")
                        .foregroundStyle(Color.shelfMuted)
                        .accessibilityLabel("Couldn't open this file.")
                }
            }
            .navigationTitle(item.media?.metadata?.title.map { Text(verbatim: $0) } ?? Text("Read", comment: "Navigation title of the ebook reader when the book has no title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // iPhone Duo (§2): system close button (symbol on iOS 26+) instead of text-only.
                    SheetCloseButton {
                        persistPDFProgressIfNeeded()
                        dismiss()
                    }
                    .monochromeToolbarItem()
                    .accessibilityHint("Closes the reader and returns to the book's details")
                }
                .shelfVisibilityPriority(.high)
            }
            .task { await load() }
            .onDisappear {
                persistPDFProgressIfNeeded()
                // Quick Look reads directly from disk (and, since P-15, so does PDFKit —
                // see `load()`), so a temp file was written for it — clean it up rather
                // than leaving it for the system's own temp-directory GC.
                if let downloadedFileURL {
                    try? FileManager.default.removeItem(at: downloadedFileURL)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Backgrounding the app is a common way to actually stop reading without
                // dismissing the sheet — `onDisappear` alone would miss that and lose
                // whatever page the user was last on if they don't return and tap Close.
                guard newPhase != .active else { return }
                persistPDFProgressIfNeeded()
            }
        }
    }

    /// Small "12 / 300" chip over the bottom trailing corner of the PDF page — N-4
    /// (REVIEW_2026-09-14_DESIGN.md): the reader had no page indicator at all before this,
    /// visually or for VoiceOver. `.accessibilityElement(children: .ignore)` collapses the
    /// two `Text` glyphs into one announcement rather than reading the "/" separately, and
    /// `.updatesFrequently` tells VoiceOver this value can change without a focus change,
    /// the same trait a stepper's value label would use.
    private var pageIndicator: some View {
        Typo.figure(Text("\(currentPageIndex + 1) / \(pdfPageCount)"))
            .foregroundStyle(Color.shelfCream)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.shelfBackground.opacity(0.85), in: Capsule())
            .padding(12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(currentPageIndex + 1) of \(pdfPageCount)")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func load() async {
        guard let ebookFile else {
            errorMessage = String(localized: "No ebook file found for this item.")
            isLoading = false
            return
        }
        guard isPDF || isQuickLookCandidate else {
            if let ext = ebookFile.metadata?.normalizedExtension.uppercased(), !ext.isEmpty {
                errorMessage = String(localized: "\(ext) isn't supported in ShelfHead's reader yet — PDF and EPUB are currently readable in-app.", comment: "%@ is a file extension such as MOBI")
            } else {
                errorMessage = String(localized: "This format isn't supported in ShelfHead's reader yet — PDF and EPUB are currently readable in-app.")
            }
            isLoading = false
            return
        }
        if usesEPUBReader {
            do {
                epubFileURL = try await EbookStore.fetch(item: item)
            } catch {
                errorMessage = Self.downloadFailureMessage(for: error)
            }
            isLoading = false
            return
        }
        guard let ino = ebookFile.ino else {
            errorMessage = String(localized: "This ebook file is missing required information.")
            isLoading = false
            return
        }
        let serverURL = AuthStore.shared.serverURL
        let path = "/api/items/\(item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.id)/file/\(ino.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ino)/download"
        guard let url = URL(string: "\(serverURL)\(path)") else {
            errorMessage = String(localized: "Couldn't build a download URL for this file.")
            isLoading = false
            return
        }
        do {
            // Item 6 (REVIEW-2026-09-09 remaining): was
            // `URLSession.shared.data(for: AuthStore.shared.authorizedRequest(url:))`.
            // That built the right headers (bearer + per-account custom headers) but had
            // no refresh-and-retry, so behind a reverse proxy — or simply with a
            // short-lived access token that had rotated since the last API call — opening
            // an ebook hard-failed with "The server couldn't provide this file" and kept
            // failing until something else refreshed the token or the app was restarted.
            // `authorizedData(for:)` builds the identical request via
            // `AuthStore.authorizedRequest(url:)` and adds the one silent refresh-and-retry
            // on 401 that every other authenticated call gets. It also validates the
            // status itself (throwing on any non-2xx), which is why the explicit
            // `HTTPURLResponse` check that used to live here is gone — that check is now
            // `validateStatus` inside the API type, surfaced through the `catch` below.
            let data = try await AudiobookshelfAPI.shared.authorizedData(for: url)
            // P-15 (REVIEW_2026-09-14_DESIGN.md): both formats now go through a URL-based
            // initializer (`PDFDocument(url:)`, Quick Look's `QLPreviewItem` URL) instead
            // of PDFKit keeping the raw response as a second, separate `Data` copy in
            // SwiftUI `@State` for the life of the reader. The initial fetch above still
            // brings the whole response into memory once — `AudiobookshelfAPI` has no
            // streaming download-to-disk entry point today, and adding one is beyond this
            // file-guarded pass (only this file and `AudiobookshelfAPI.swift`) — but
            // nothing holds onto that `Data` past this `write(to:)`.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL, options: .atomic)
            downloadedFileURL = tempURL

            if isPDF {
                guard let document = PDFDocument(url: tempURL) else {
                    errorMessage = String(localized: "Couldn't open this PDF.")
                    isLoading = false
                    return
                }
                pdfDocument = document
                // Resume where the server (or another device, or the web UI) last left
                // off, if it recorded a page that's actually in range for this document.
                // Best-effort: a failure here just means the reader opens at page one,
                // same as before this pass.
                if let stored = try? await AudiobookshelfAPI.shared.getEbookProgress(itemId: item.id),
                   let locationString = stored.location,
                   let page = Int(locationString), page >= 0, page < document.pageCount {
                    initialPageIndex = page
                    currentPageIndex = page
                    lastPersistedPageIndex = page
                }
            }
        } catch {
            errorMessage = Self.downloadFailureMessage(for: error)
        }
        isLoading = false
    }

    /// Writes the current PDF page back to Audiobookshelf so the web UI (and other
    /// devices) see where the user left off. Called on dismiss and whenever the app
    /// leaves the foreground while the reader is still open (see `onChange(of: scenePhase)`
    /// above) — `onDisappear` alone would miss "backgrounded the app without dismissing
    /// the sheet," a common way to actually stop reading.
    ///
    /// No equivalent exists for the Quick Look (EPUB/CBZ) path: `QLPreviewController`
    /// exposes no current-page/location API to read a real position back from, so this
    /// deliberately writes nothing for that format rather than inventing a fake one.
    ///
    /// Fire-and-forget on the happy path: the user is already leaving the screen either
    /// way, so this never blocks on the network. A failed write (offline, unreachable,
    /// refresh failure) is no longer just logged — it's `record`ed into
    /// `PendingProgressQueue` as an ebook entry (`Entry.ebook(...)`) so
    /// `AudioPlayerService.flushPendingProgress()`'s drain retries it once the app is back
    /// online, the same durable path an audio position already gets. See that type's
    /// `isEbook`/`ebook(...)` doc comments for why this needed a queue-schema change
    /// rather than reusing the audio entry shape as-is (no `currentTime` to reconcile).
    private func persistPDFProgressIfNeeded() {
        guard isPDF, pdfPageCount > 0, currentPageIndex != lastPersistedPageIndex else { return }
        let itemId = item.id
        let page = currentPageIndex
        let progress = Self.ebookProgressFraction(pageIndex: page, pageCount: pdfPageCount)
        lastPersistedPageIndex = page
        // Review Low (Sync) (30 October 2026): captured here, synchronously, not in the
        // catch below — by then the write has suspended and an account switch could have
        // changed the scope, filing this position under the wrong account.
        let scope = Self.currentProgressScope()
        let capturedAt = Date().timeIntervalSince1970
        Task {
            do {
                try await AudiobookshelfAPI.shared.updateEbookProgress(
                    itemId: itemId, location: String(page), progress: progress,
                    expectedScope: scope)  // Review 5 Low (expectedScope)
            } catch {
                ShelfLog.error(.sync, "Failed to sync ebook reading position for \(ShelfLog.redact(itemId)): \(error)")
                // Queued for retry (dedupe per item — `record` keeps only the newest
                // write for this scope/itemId, same as an audio position). Scope is
                // computed the same way `AudioPlayerService.currentProgressScope()` does,
                // duplicated here rather than reused: that method is `private` and this
                // pass's file scope doesn't include widening `AudioPlayerService` beyond
                // its drain path.
                let entry = PendingProgressQueue.Entry.ebook(
                    scope: scope, itemId: itemId, location: String(page),
                    progress: progress, updatedAt: capturedAt)
                await PendingProgressQueue.shared.record(entry)
            }
        }
    }

    /// Mirrors `AudioPlayerService.currentProgressScope()` (kept in sync with it
    /// deliberately — both describe "which server+account was this queued for"): the
    /// current server URL plus account id, or `"unscoped"` if signed out entirely. Must be
    /// called synchronously, before any `await`, by whoever is capturing a position to
    /// queue (see that method's doc comment for the account-switch race this avoids).
    private static func currentProgressScope() -> String {
        let server = AuthStore.shared.serverURL
        guard !server.isEmpty else { return "unscoped" }
        return DownloadManager.scopeKey(serverURL: server, accountId: AccountStore.currentAccountId ?? "unknown")
    }

    /// The message shown when fetching the ebook file fails.
    ///
    /// Item 6 (REVIEW-2026-09-09 remaining): `load()` used to inspect the
    /// `HTTPURLResponse` itself and show one flat "The server couldn't provide this file."
    /// for every non-2xx, with thrown transport errors getting a separate sentence.
    /// Now that the fetch goes through `AudiobookshelfAPI.authorizedData(for:)`, a non-2xx
    /// arrives as a thrown `APIError` instead, so that split lives here — and, since the
    /// error carries the actual status, the message can say *why* rather than shrugging.
    /// A 401 here means the refresh-and-retry inside `authorizedData` already ran and
    /// still failed, so pointing at the session is the honest advice. Anything that isn't
    /// an `APIError` (a transport failure, or the temp-file write for the Quick Look path)
    /// keeps the original wording verbatim.
    /// `nonisolated` because it's a pure `Error` → `String` mapping with no state: it
    /// stays callable (and unit-testable) from outside the main actor even though a
    /// SwiftUI `View`'s members are otherwise main-actor-isolated.
    nonisolated static func downloadFailureMessage(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return String(localized: "Couldn't download this file: \(error.localizedDescription)", comment: "%@ is a system error description")
        }
        switch apiError {
        case .unauthorized:
            return String(localized: "Your session has expired. Sign out and back in, then try again.")
        case .forbidden:
            return String(localized: "You don't have permission to download this file.")
        case .notFound:
            return String(localized: "The server couldn't find this file.")
        case .serverError(let code), .httpError(let code):
            return String(localized: "The server couldn't provide this file (HTTP \(code)).", comment: "%lld is an HTTP status code")
        case .invalidURL, .invalidResponse, .decodingError:
            return String(localized: "The server couldn't provide this file.")
        }
    }

    /// Pure page → progress-fraction mapping, pinned with a test
    /// (`ShelfHeadTests/EbookProgressTests.swift`) per this project's convention of
    /// extracting a pure function when a bug fix needs a regression test. `pageIndex` is
    /// 0-based (as PDFKit reports it); `pageCount` is guarded to at least 1 so a
    /// zero-page document can't divide by zero.
    nonisolated static func ebookProgressFraction(pageIndex: Int, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        let clampedPage = max(0, min(pageIndex, pageCount))
        return Double(clampedPage) / Double(pageCount)
    }
}

/// Thin `UIViewRepresentable` wrapper around `PDFKit.PDFView` — scrollable, pinch-to-zoom
/// PDF display with no custom chrome, matching what `PDFView`'s defaults already provide.
///
/// P-15 (REVIEW_2026-09-14_DESIGN.md): also the reading-position bridge — reports the
/// current page back to SwiftUI via `onPageChanged` (so `EbookReaderView` can write it to
/// Audiobookshelf on dismiss/backgrounding) and jumps to `initialPageIndex` once, on load
/// (the page Audiobookshelf last had recorded for this item, if any, already validated as
/// in-range by the caller). Deliberately doesn't touch `PDFView.isAccessibilityElement` —
/// `PDFView` already exposes its text to VoiceOver page-by-page on its own, and collapsing
/// it into one opaque element would make the reader *less* accessible, not more.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let initialPageIndex: Int?
    let onPageChanged: (_ pageIndex: Int, _ pageCount: Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        if let initialPageIndex, let page = document.page(at: initialPageIndex) {
            view.go(to: page)
        }
        context.coordinator.observe(view, onPageChanged: onPageChanged)
        // `.PDFViewPageChanged` only fires on a subsequent navigation — without this, the
        // SwiftUI-side page count/indicator would sit at zero until the user scrolls once.
        if let currentPage = view.currentPage {
            onPageChanged(document.index(for: currentPage), document.pageCount)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        private weak var observedView: PDFView?
        private var onPageChanged: ((Int, Int) -> Void)?

        func observe(_ view: PDFView, onPageChanged: @escaping (Int, Int) -> Void) {
            guard observedView !== view else { return }
            if let observedView {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: observedView)
            }
            observedView = view
            self.onPageChanged = onPageChanged
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageDidChange() {
            guard let observedView, let document = observedView.document,
                  let currentPage = observedView.currentPage else { return }
            onPageChanged?(document.index(for: currentPage), document.pageCount)
        }

        deinit {
            if let observedView {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: observedView)
            }
        }
    }
}

/// `UIViewControllerRepresentable` wrapper around `QLPreviewController` — the system's
/// Quick Look reader, used here for EPUB/CBZ rather than a from-scratch renderer. Reads
/// from a file URL (see `EbookReaderView.load()`), which is how `QLPreviewController`
/// determines which of its built-in viewers to use.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        // Guard the reload: `updateUIViewController` runs on every SwiftUI state change
        // that touches this view, not only when `url` changes. An unguarded
        // `reloadData()` throws `QLPreviewController` back to page one — losing scroll
        // position and zoom — on any unrelated invalidation while the user is mid-read.
        // Update the coordinator's copy first: `reloadData()` re-queries the data
        // source, which reads `coordinator.url`.
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
