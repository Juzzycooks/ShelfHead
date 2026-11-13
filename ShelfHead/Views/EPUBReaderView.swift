import SwiftUI
import WebKit

// Batch 430 (Section G part 1): the in-app EPUB reader, iOS 26+ only (SwiftUI `WebPage` +
// `WebView`, Apple docs `WebKit/WebPage`). iOS 17–25 and CBZ keep Quick Look.
//
// Deliberate choice: one spine item at a time, scrolled vertically, with no CSS-column
// pagination. Continuous scroll per chapter is what Apple Books' "Scrolling View" does, and
// it works with VoiceOver and Dynamic Type. The book is read straight out of the zip by a
// `shelfhead-epub://book/<zip path>` scheme handler, so nothing is unpacked to disk.
// Content JavaScript is off for the book's own scripts; the reader's own JS runs in
// `WKContentWorld.defaultClient`. DOM changes are shared across worlds.

// MARK: - Shared state between the scheme handler and the model

/// The zip and the current stylesheet, shared with the scheme handler (which is created
/// before the book has been parsed). Lock-protected because WebKit calls the handler off
/// the main actor.
nonisolated final class EPUBBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var _zip: ZipReader?
    private var _css = ""

    var zip: ZipReader? {
        get { lock.lock(); defer { lock.unlock() }; return _zip }
        set { lock.lock(); defer { lock.unlock() }; _zip = newValue }
    }

    var css: String {
        get { lock.lock(); defer { lock.unlock() }; return _css }
        set { lock.lock(); defer { lock.unlock() }; _css = newValue }
    }
}

@available(iOS 26.0, *)
nonisolated struct EPUBSchemeHandler: URLSchemeHandler {
    let backing: EPUBBacking

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url, let zip = backing.zip else {
                continuation.finish(throwing: URLError(.fileDoesNotExist))
                return
            }
            let path = String(url.path.dropFirst())
            do {
                var data = try zip.data(for: path)
                let mime = EPUBPath.mimeType(forPath: path)
                let isMarkup = mime.contains("html")
                if isMarkup { data = Self.injectingStyle(into: data, css: backing.css) }
                let isText = isMarkup || mime.hasPrefix("text/") || mime.hasSuffix("xml") || mime == "image/svg+xml"
                let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                           textEncodingName: isText ? "utf-8" : nil)
                continuation.yield(.response(response))
                continuation.yield(.data(data))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Review 6 Low (EPUB CSP): the book may only load its own package parts (and data: URIs), so
    /// remote images/CSS/fonts and scripts are blocked. The reader's own JS runs through
    /// `callJavaScript` in `WKContentWorld.defaultClient`, which page CSP does not apply to.
    nonisolated static let contentSecurityPolicy =
        "default-src \(EPUBReaderModel.schemeName): data:; "
        + "style-src \(EPUBReaderModel.schemeName): data: 'unsafe-inline'; "
        + "img-src \(EPUBReaderModel.schemeName): data:; font-src \(EPUBReaderModel.schemeName): data:"

    /// Adds the viewport meta, a CSP meta and a `#shelfhead-style` element (already holding the current
    /// CSS, so there is no unstyled flash) right after the opening `<head>` tag, so the CSP covers
    /// every head resource. Without a head it goes after `<html>` (in a new `<head>`), else after any
    /// XML declaration / doctype. Documents that aren't UTF-8 are served unchanged.
    static func injectingStyle(into data: Data, css: String) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let block = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"/>"
            + "<style id=\"shelfhead-style\">/*<![CDATA[*/\(css)/*]]>*/</style>"
        return Data(injecting(block: block, into: text).utf8)
    }

    // Review 7 Low (CSP placement / no head)
    nonisolated static func injecting(block: String, into text: String) -> String {
        var text = text
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        if let head = text.range(of: "<head(\\s[^>]*)?/?>", options: opts) {
            if text[head].hasSuffix("/>") {   // self-closing <head/>
                text.replaceSubrange(head, with: "<head>" + block + "</head>")
            } else {
                text.insert(contentsOf: block, at: head.upperBound)
            }
        } else if let html = text.range(of: "<html(\\s[^>]*)?/?>", options: opts) {
            if text[html].hasSuffix("/>") {
                text.replaceSubrange(html, with: "<html><head>" + block + "</head></html>")
            } else {
                text.insert(contentsOf: "<head>" + block + "</head>", at: html.upperBound)
            }
        } else {
            var index = text.startIndex
            for pattern in ["^\\s*<\\?xml[^>]*\\?>", "^\\s*<!DOCTYPE[^>]*>"] {
                if let r = text.range(of: pattern, options: opts, range: index..<text.endIndex) { index = r.upperBound }
            }
            text.insert(contentsOf: block, at: index)
        }
        return text
    }
}

/// Lets the (value-type) navigation decider reach the model that doesn't exist yet when the
/// `WebPage` is built.
@MainActor final class EPUBLinkRouter {
    var onInternal: ((URL) -> Void)?
    var onExternal: ((URL) -> Void)?
}

@available(iOS 26.0, *)
struct EPUBNavigationDecider: WebPage.NavigationDeciding {
    let router: EPUBLinkRouter

    mutating func decidePolicy(for action: WebPage.NavigationAction,
                               preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        if scheme == "about" { return .allow }
        let tapped = action.navigationType == .linkActivated
        if scheme == EPUBReaderModel.schemeName {
            if tapped {
                router.onInternal?(url)
                return .cancel
            }
            return .allow
        }
        if tapped, let scheme, ["http", "https", "mailto"].contains(scheme) {
            router.onExternal?(url)
        }
        return .cancel
    }
}

// MARK: - Model

@available(iOS 26.0, *)
@Observable @MainActor
final class EPUBReaderModel {
    nonisolated static let schemeName = "shelfhead-epub"

    let itemId: String
    let fileURL: URL
    let page: WebPage
    private(set) var package: EPUBPackage?
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private(set) var currentSpineIndex = 0
    private(set) var position = EPUBPosition(spineIndex: 0, fraction: 0)
    var style: EPUBReaderStyle { didSet { if style != oldValue { restyle() } } }
    /// Batch 490 (REVIEW 2026-11-11 F31): CSS appended after `style.css` (line spacing).
    /// `EPUBReaderStyle` lives in `EPUBPackage.swift`, so the reader's extras ride here.
    var extraCSS: String { didSet { if extraCSS != oldValue { restyle() } } }
    private var fullCSS: String { style.css + extraCSS }

    // Batch 431: read-along state.
    enum ReadAlongState: Equatable { case unavailable, matching, ready, mismatch }
    private(set) var readAlongState: ReadAlongState = .unavailable
    private(set) var readAlongMap: ReadAlongMap?
    private(set) var segments: [TranscriptSegment] = []
    /// Whether the reader scrolls (and turns chapters) to keep the spoken sentence in view.
    var isFollowing = false
    /// Shows the "doesn't match" note; the view clears it after a few seconds.
    var mismatchNoteVisible = false
    @ObservationIgnored var smoothScroll = true
    @ObservationIgnored private var highlighted: ReadAlongLocation?
    @ObservationIgnored private var lastTickSegment: Int?

    @ObservationIgnored private let backing = EPUBBacking()
    @ObservationIgnored private let router = EPUBLinkRouter()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastSaved: EPUBPosition?
    @ObservationIgnored var openExternal: ((URL) -> Void)? {
        get { router.onExternal }
        set { router.onExternal = newValue }
    }

    private static let jsWorld = WKContentWorld.defaultClient

    init(itemId: String, fileURL: URL, style: EPUBReaderStyle, extraCSS: String = "") {
        self.itemId = itemId
        self.fileURL = fileURL
        self.style = style
        self.extraCSS = extraCSS
        var config = WebPage.Configuration()
        config.defaultNavigationPreferences.allowsContentJavaScript = false
        if let scheme = URLScheme(Self.schemeName) {
            config.urlSchemeHandlers[scheme] = EPUBSchemeHandler(backing: backing)
        }
        page = WebPage(configuration: config, navigationDecider: EPUBNavigationDecider(router: router))
        backing.css = fullCSS
        router.onInternal = { [weak self] url in self?.followInternal(url) }
    }

    // MARK: Opening

    @concurrent
    nonisolated private static func parse(_ url: URL) async throws -> (ZipReader, EPUBPackage) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let zip = try ZipReader(data: data)
        return (zip, try EPUBPackage(zip: zip))
    }

    func open() async {
        guard package == nil else { return }
        do {
            let (zip, parsed) = try await Self.parse(fileURL)
            guard !parsed.spine.isEmpty else { throw ZipError.corrupt }
            backing.zip = zip
            package = parsed
            var saved = EbookStore.position(itemId: itemId)
            // Batch 495 (REVIEW 2026-11-11 L12): with iCloud position sync on, a newer position
            // from the listener's other device wins, and is kept here with its own time.
            let cloud = CloudPositionStore.shared.epubPosition(forItemId: itemId)
            let localSavedAt = saved == nil ? nil : EbookStore.positionSavedAt(itemId: itemId)
            if let cloud, CloudPositionStore.shouldAdoptCloudEPUBPosition(cloud: cloud, localSavedAt: localSavedAt) {
                let adopted = EPUBPosition(spineIndex: cloud.spineIndex, fraction: cloud.fraction)
                EbookStore.savePosition(adopted, itemId: itemId, savedAt: cloud.updatedAt)
                lastSaved = adopted
                saved = adopted
            }
            // Batch 497 (L11): a replaced file may have fewer chapters; clamp, don't discard.
            let valid = EbookStore.clampedPosition(saved, spineCount: parsed.spine.count)
            isReady = true
            await show(spineIndex: valid?.spineIndex ?? 0, fraction: valid?.fraction)
        } catch {
            ShelfLog.error(.storage, "EPUB open failed: \(error.localizedDescription)")
            EbookStore.delete(itemId: itemId)
            errorMessage = String(localized: "Couldn't open this EPUB. The file may be damaged; try again to download it afresh.")
        }
    }

    // MARK: Navigation

    /// Loads one spine item, then styles it and restores `fraction` (or jumps to `fragment`).
    func show(spineIndex: Int, fraction: Double? = nil, fragment: String? = nil) async {
        guard let package, package.spine.indices.contains(spineIndex) else { return }
        generation += 1
        let mine = generation
        currentSpineIndex = spineIndex
        position = EPUBPosition(spineIndex: spineIndex, fraction: fraction ?? 0)
        var components = URLComponents()
        components.scheme = Self.schemeName
        components.host = "book"
        components.path = "/" + package.spine[spineIndex].href
        guard let url = components.url else { return }
        do {
            for try await _ in page.load(URLRequest(url: url)) {}
        } catch {
            ShelfLog.error(.storage, "EPUB page load failed: \(error.localizedDescription)")
            return
        }
        guard mine == generation else { return }
        await applyStyle()
        await installChapterNav(spineIndex: spineIndex)
        if let fragment, !fragment.isEmpty {
            _ = try? await evaluate("document.getElementById(id)?.scrollIntoView(); return null;",
                                    arguments: ["id": fragment])
        } else if let fraction, fraction > 0 {
            _ = try? await evaluate(
                "window.scrollTo(0, f * Math.max(0, document.documentElement.scrollHeight - window.innerHeight)); return null;",
                arguments: ["f": min(1, max(0, fraction))])
        }
        if let highlighted, highlighted.spineIndex == spineIndex {
            await applyHighlight(highlighted, scroll: isFollowing)
        }
    }

    func next() async {
        guard let package, currentSpineIndex + 1 < package.spine.count else { return }
        await show(spineIndex: currentSpineIndex + 1)
    }

    func previous() async {
        guard currentSpineIndex > 0 else { return }
        await show(spineIndex: currentSpineIndex - 1)
    }

    var canGoPrevious: Bool { currentSpineIndex > 0 }
    var canGoNext: Bool { (package?.spine.count ?? 0) > currentSpineIndex + 1 }

    /// Batch 495 (REVIEW 2026-11-11 L13): the reader scrolls one chapter at a time, and the
    /// end of a chapter offered nothing; the next-chapter control was only in the bottom bar.
    /// Real links (Next Chapter: <title>, then Previous Chapter) are appended after the
    /// chapter's text, so they read as part of the page and VoiceOver reaches them in order.
    /// A tap goes through the navigation decider like any internal link (`followInternal`).
    /// They are `<a>` in a `<nav>`, neither of which is a read-along block (`ReadAlongScript`
    /// selects p, h1–h6, li, …), and they come last, so no block index shifts.
    private func installChapterNav(spineIndex: Int) async {
        guard let package else { return }
        let spineHrefs = package.spine.map(\.href)
        func link(_ index: Int) -> String {
            guard spineHrefs.indices.contains(index) else { return "" }
            var components = URLComponents()
            components.scheme = Self.schemeName
            components.host = "book"
            components.path = "/" + spineHrefs[index]
            return components.url?.absoluteString ?? ""
        }
        let nextTitle = EPUBChapterNav.title(forSpineIndex: spineIndex + 1, spineHrefs: spineHrefs, toc: package.toc)
        let nextText = nextTitle.map {
            String(localized: "Next Chapter: \($0)", comment: "Link at the end of a chapter in the ebook reader; %@ is the next chapter's title")
        } ?? String(localized: "Next Chapter", comment: "Link at the end of a chapter in the ebook reader")
        _ = try? await evaluate(EPUBChapterNav.script, arguments: [
            "nextHref": link(spineIndex + 1),
            "nextText": nextText,
            "prevHref": link(spineIndex - 1),
            "prevText": String(localized: "Previous Chapter", comment: "Link at the end of a chapter in the ebook reader"),
            "label": String(localized: "Chapter navigation", comment: "VoiceOver label for the next/previous chapter links at the end of a chapter"),
        ])
    }

    /// Opens a table-of-contents `href` (full zip path, fragment kept).
    func show(href: String) async {
        guard let package else { return }
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        let fragment = href.contains("#") ? String(href.drop { $0 != "#" }.dropFirst()) : nil
        guard let index = package.spineIndex(forPath: path) else { return }
        if index == currentSpineIndex, let fragment, !fragment.isEmpty {
            _ = try? await evaluate("document.getElementById(id)?.scrollIntoView(); return null;",
                                    arguments: ["id": fragment])
        } else {
            await show(spineIndex: index, fragment: fragment)
        }
    }

    private func followInternal(_ url: URL) {
        let fragment = url.fragment.map { "#" + $0 } ?? ""
        let path = String(url.path.dropFirst())
        Task { await show(href: path + fragment) }
    }

    // MARK: Style and position

    private func restyle() {
        backing.css = fullCSS
        Task { await applyStyle() }
    }

    private func applyStyle() async {
        _ = try? await evaluate("document.getElementById('shelfhead-style').textContent = css; return null;",
                                arguments: ["css": fullCSS])
        // A new size reflows the text; keep the spoken sentence marked (and in view when following).
        if let highlighted, highlighted.spineIndex == currentSpineIndex {
            await applyHighlight(highlighted, scroll: isFollowing)
        }
    }

    /// Runs a JS function body in the reader's world (`callJavaScript`: arguments are in scope).
    func evaluate(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.callJavaScript(body, arguments: arguments, contentWorld: Self.jsWorld)
    }

    // MARK: Read-along (Batch 431)

    var readAlongAvailable: Bool { readAlongState == .ready }

    @concurrent
    nonisolated private static func loadTranscript(itemId: String) async -> Transcript? {
        TranscriptStore.load(itemId: itemId)
    }

    /// Loads the transcript and the (cached or built) map. No transcript: stays unavailable.
    func loadReadAlong() async {
        guard readAlongState == .unavailable else { return }
        guard let transcript = await Self.loadTranscript(itemId: itemId), !transcript.segments.isEmpty else { return }
        readAlongState = .matching
        guard let map = await ReadAlongStore.map(itemId: itemId, ebookURL: fileURL, transcript: transcript) else {
            readAlongState = .unavailable
            return
        }
        guard map.locations.count == transcript.segments.count else {
            readAlongState = .unavailable
            return
        }
        segments = transcript.segments
        readAlongMap = map
        if map.matchedFraction < 0.2 {
            readAlongState = .mismatch
            mismatchNoteVisible = true
        } else {
            readAlongState = .ready
        }
    }

    func dismissMismatchNote() { mismatchNoteVisible = false }

    /// Called every ~0.5 s with the player's book time while this book is loaded.
    func followTick(time: Double) async {
        guard readAlongState == .ready, let map = readAlongMap else { return }
        let index = TranscriptLookup.segmentIndex(in: segments, at: time)
        guard index != lastTickSegment else { return }
        lastTickSegment = index
        guard let index, let location = map.location(forSegment: index) else { return }
        await place(location, scroll: isFollowing, turnChapter: isFollowing)
    }

    /// Turns following on and moves to the sentence spoken at `time`.
    func followNow(time: Double) async {
        isFollowing = true
        guard readAlongState == .ready, let map = readAlongMap else { return }
        let index = TranscriptLookup.segmentIndex(in: segments, at: time)
        lastTickSegment = index
        guard let index, let location = map.location(forSegment: index) else { return }
        await place(location, scroll: true, turnChapter: true)
    }

    /// Marks a segment the listener chose (Listen from Here) and starts following it.
    func follow(segment index: Int) async {
        isFollowing = true
        lastTickSegment = index
        guard let map = readAlongMap, let location = map.location(forSegment: index) else { return }
        await place(location, scroll: true, turnChapter: true)
    }

    /// The segment for the current selection (or the first visible paragraph) and its start time.
    func segmentUnderReader() async -> (index: Int, start: Double)? {
        guard readAlongState == .ready, let map = readAlongMap,
              let result = try? await evaluate(ReadAlongScript.locate),
              let pair = result as? [Any], pair.count == 2,
              let block = (pair[0] as? NSNumber)?.intValue,
              let offset = (pair[1] as? NSNumber)?.intValue,
              let index = map.segmentIndex(spineIndex: currentSpineIndex, block: block, offset: offset),
              segments.indices.contains(index) else { return nil }
        return (index, segments[index].start)
    }

    private func place(_ location: ReadAlongLocation, scroll: Bool, turnChapter: Bool) async {
        highlighted = location
        if location.spineIndex != currentSpineIndex {
            if turnChapter {
                await show(spineIndex: location.spineIndex)   // re-applies the highlight on load
            } else {
                _ = try? await evaluate(ReadAlongScript.clear)
            }
            return
        }
        await applyHighlight(location, scroll: scroll)
    }

    private func applyHighlight(_ location: ReadAlongLocation, scroll: Bool) async {
        let lengths = readAlongMap?.blockLengths ?? []
        let spine = lengths.indices.contains(location.spineIndex) ? lengths[location.spineIndex] : []
        func length(_ block: Int) -> Int { spine.indices.contains(block) ? spine[block] : -1 }
        _ = try? await evaluate(ReadAlongScript.highlight, arguments: [
            "startBlock": location.startBlock, "startOffset": location.startOffset,
            "endBlock": location.endBlock, "endOffset": location.endOffset,
            "startLength": length(location.startBlock), "endLength": length(location.endBlock),
            "scroll": scroll, "smooth": smoothScroll,
        ])
    }

    /// Reads the scroll fraction back and saves it when it moved. `isFinal` (close,
    /// backgrounding) forces the iCloud write and sends any remaining progress change.
    func capturePosition(isFinal: Bool = false) async {
        guard isReady else { return }
        let value = try? await evaluate(
            "return window.scrollY / Math.max(1, document.documentElement.scrollHeight - window.innerHeight);")
        guard let number = value as? Double, number.isFinite else { return }
        let current = EPUBPosition(spineIndex: currentSpineIndex, fraction: min(1, max(0, number)))
        position = current
        let moved = current != lastSaved
        if moved {
            lastSaved = current
            EbookStore.savePosition(current, itemId: itemId)
        }
        // Batch 495 (REVIEW 2026-11-11 L12): the spine position to the listener's other
        // devices (opt-in iCloud position sync; throttled to 20 s unless final), and the
        // whole-book fraction to the server.
        if moved || isFinal {
            CloudPositionStore.shared.recordEPUB(itemId: itemId, spineIndex: current.spineIndex,
                                                 fraction: current.fraction, force: isFinal)
        }
        sendReadingProgress(isFinal: isFinal)
    }

    // MARK: Reading progress to the server (Batch 495, REVIEW 2026-11-11 L12)

    /// The fraction last attempted, and last confirmed by the server. Seeded on open with the
    /// server's known value, so simply opening a book sends nothing.
    @ObservationIgnored var lastSentReadingProgress: Double?
    @ObservationIgnored private var lastConfirmedReadingProgress: Double?

    func seedReadingProgress(_ known: Double?) {
        lastSentReadingProgress = known
        lastConfirmedReadingProgress = known
    }

    /// Sends `ebookProgress` only (never `ebookLocation`: Batch 430, the web reader keeps a
    /// CFI there). While reading it compares against the last attempt, so an offline reader
    /// doesn't retry every 2 s; on close it compares against the last confirmed write, so a
    /// failed one is tried again then. Not queued in `PendingProgressQueue`: that queue's
    /// ebook entries need a location to replay, and the next open or close sends again.
    private func sendReadingProgress(isFinal: Bool) {
        guard package != nil else { return }
        let progress = overallProgress
        let baseline = isFinal ? lastConfirmedReadingProgress : lastSentReadingProgress
        guard EbookStore.shouldSendReadingProgress(current: progress, lastSent: baseline, isFinal: isFinal) else { return }
        lastSentReadingProgress = progress
        let itemId = itemId
        let scope = EbookReaderView.currentProgressScope()   // captured before any await
        Task { @MainActor [weak self] in
            do {
                try await AudiobookshelfAPI.shared.updateEbookReadingProgress(
                    itemId: itemId, progress: progress, expectedScope: scope)
                self?.lastConfirmedReadingProgress = progress
            } catch {
                ShelfLog.error(.sync, "Failed to sync EPUB reading progress for \(ShelfLog.redact(itemId)): \(error)")
            }
        }
    }

    /// Whole-book progress, 0...1.
    var overallProgress: Double {
        guard let package else { return 0 }
        return position.overallProgress(weights: package.spineWeights)
    }
}

// MARK: - View

@available(iOS 26.0, *)
struct EPUBReaderView: View {
    let item: LibraryItem
    let fileURL: URL
    /// Batch 431: open following the audio (the player's Read Along item).
    var followsPlayback = false
    /// Listen from Here: receives the book time to play from. Nil: seek the loaded book directly.
    var onListen: ((Double) -> Void)? = nil

    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("epubReader.fontScale") private var storedScale = 0.0
    @AppStorage("epubReader.serif") private var serif = true
    /// Batch 490 (REVIEW 2026-11-11 F31): page colour and line spacing, by raw value.
    @AppStorage("epubReader.theme") private var pageTheme = EPUBPageTheme.matchApp.rawValue
    @AppStorage("epubReader.lineSpacing") private var lineSpacing = EPUBLineSpacing.normal.rawValue

    @State private var model: EPUBReaderModel?
    @State private var showContents = false

    var body: some View {
        ZStack {
            Color.shelfBackground.ignoresSafeArea()
            if let model {
                if let message = model.errorMessage {
                    errorView(message)
                } else {
                    content(model)
                }
            } else {
                LoadingView("Opening book\u{2026}")
            }
        }
        .task(id: item.id) {
            let created = EPUBReaderModel(itemId: item.id, fileURL: fileURL, style: makeStyle(),
                                          extraCSS: currentLineSpacing.css)
            created.openExternal = { openURL($0) }
            created.smoothScroll = !reduceMotion
            created.seedReadingProgress(item.mediaProgress?.ebookProgress)   // Batch 495 (L12)
            model = created
            await created.open()
            await created.loadReadAlong()
            if followsPlayback, created.readAlongAvailable, isThisBookLoaded {
                await created.followNow(time: playerViewModel.currentTime)
            }
        }
        .task(id: model?.readAlongAvailable) {
            // Follow along: poll the player's book time while this book is the one loaded.
            guard let model, model.readAlongAvailable else { return }
            while !Task.isCancelled {
                if isThisBookLoaded {
                    await model.followTick(time: playerViewModel.currentTime)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task(id: model?.mismatchNoteVisible) {
            guard model?.mismatchNoteVisible == true else { return }
            try? await Task.sleep(for: .seconds(8))
            model?.dismissMismatchNote()
        }
        .onChange(of: reduceMotion) { _, value in model?.smoothScroll = !value }
        .task(id: model?.isReady) {
            guard let model, model.isReady else { return }
            // Read the scroll position back every ~2 s while the reader is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.capturePosition()
            }
        }
        .onChange(of: colorScheme) { _, _ in model?.style = makeStyle() }
        // Until the reader picks its own size, the text follows Dynamic Type.
        .onChange(of: dynamicTypeSize) { _, _ in model?.style = makeStyle() }
        .onChange(of: storedScale) { _, _ in model?.style = makeStyle() }
        .onChange(of: serif) { _, _ in model?.style = makeStyle() }
        .onChange(of: pageTheme) { _, _ in model?.style = makeStyle() }
        .onChange(of: lineSpacing) { _, _ in model?.extraCSS = currentLineSpacing.css }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await model?.capturePosition(isFinal: true) }
        }
        .onDisappear { Task { await model?.capturePosition(isFinal: true) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                appearanceMenu
                    .monochromeToolbarItem()
            }
        }
    }

    private var isThisBookLoaded: Bool { playerViewModel.currentBook?.id == item.id }

    // MARK: Pieces

    private func content(_ model: EPUBReaderModel) -> some View {
        WebView(model.page)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(model) }
            .sheet(isPresented: $showContents) { contentsSheet(model) }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.shelfAmberText)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.shelfCream)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
    }

    private func bottomBar(_ model: EPUBReaderModel) -> some View {
        let percent = Int((model.overallProgress * 100).rounded())
        return VStack(spacing: 0) {
            readAlongStatus(model)
            controlRow(model, percent: percent)
        }
        .background(Color.shelfBackground)
    }

    @ViewBuilder
    private func readAlongStatus(_ model: EPUBReaderModel) -> some View {
        let text: Text? = switch model.readAlongState {
        case .matching: Text("Matching the book to the audio\u{2026}", comment: "Status in the ebook reader while the transcript is being matched to the book's text")
        case .mismatch where model.mismatchNoteVisible: Text("This ebook doesn't match the audio closely enough to read along.", comment: "Note in the ebook reader when the book's text doesn't line up with the audiobook transcript")
        default: nil
        }
        if let text {
            Typo.supporting(text)
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func controlRow(_ model: EPUBReaderModel, percent: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                Haptics.selection()
                model.isFollowing = false
                Task { await model.previous() }
            } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!model.canGoPrevious)
            .accessibilityLabel("Previous Chapter")

            Button {
                Haptics.selection()
                model.isFollowing = false
                showContents = true
            } label: {
                Image(systemName: "list.bullet").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Contents")

            Button {
                Haptics.selection()
                model.isFollowing = false
                Task { await model.next() }
            } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!model.canGoNext)
            .accessibilityLabel("Next Chapter")

            if model.readAlongAvailable {
                if isThisBookLoaded {
                    Button {
                        Haptics.selection()
                        Task { await model.followNow(time: playerViewModel.currentTime) }
                    } label: {
                        Image(systemName: "scope")
                            .foregroundStyle(model.isFollowing ? Color.shelfAmberText : Color.shelfCream)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Follow Along")
                    .accessibilityAddTraits(model.isFollowing ? .isSelected : [])
                }
                Button {
                    Haptics.selection()
                    Task { await listenFromHere(model) }
                } label: {
                    Image(systemName: "headphones").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Listen from Here")
                .accessibilityHint("Plays the audiobook from the selected text, or from the top of the screen")
            }

            Spacer()

            Typo.figure(Text("\(percent)%"))
                .foregroundStyle(Color.shelfCream)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(percent)% read")
                .accessibilityAddTraits(.updatesFrequently)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.shelfCream)
        .padding(.horizontal, 12)
    }

    /// Plays from the selection (or first visible paragraph) and starts following.
    private func listenFromHere(_ model: EPUBReaderModel) async {
        guard let target = await model.segmentUnderReader() else { return }
        if let onListen {
            onListen(target.start)
        } else if isThisBookLoaded {
            playerViewModel.seek(to: target.start, reason: .readAlong)
        } else {
            return
        }
        // "Listen" means play: a paused book starts from the spot (a book still loading starts on its own).
        if isThisBookLoaded, !playerViewModel.isPlaying {
            playerViewModel.togglePlayPause()
        }
        await model.follow(segment: target.index)
    }

    private var appearanceMenu: some View {
        Menu {
            Button {
                storedScale = max(0.8, (currentScale - 0.1).rounded(toPlaces: 1))
            } label: {
                Label("Smaller Text", systemImage: "textformat.size.smaller")
            }
            .disabled(currentScale <= 0.8)
            // Batch 490 (REVIEW 2026-11-11 F31): the menu stays open so the size can be
            // stepped more than once (iOS 16.4+, under the iOS 26 gate here).
            .menuActionDismissBehavior(.disabled)
            Button {
                storedScale = min(2.5, (currentScale + 0.1).rounded(toPlaces: 1))
            } label: {
                Label("Larger Text", systemImage: "textformat.size.larger")
            }
            .disabled(currentScale >= 2.5)
            .menuActionDismissBehavior(.disabled)
            Toggle(isOn: $serif) {
                Label("Serif", systemImage: "textformat")
            }
            // Batch 490 (REVIEW 2026-11-11 F31): page colour and line spacing as inline
            // submenus (HIG Menus: a picker in a menu for one-of-several choices).
            Picker(selection: $pageTheme) {
                Text("Match App").tag(EPUBPageTheme.matchApp.rawValue)
                Text("Sepia").tag(EPUBPageTheme.sepia.rawValue)
                Text("Black").tag(EPUBPageTheme.black.rawValue)
            } label: {
                Label("Page Colour", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)
            Picker(selection: $lineSpacing) {
                Text("Normal").tag(EPUBLineSpacing.normal.rawValue)
                Text("Relaxed").tag(EPUBLineSpacing.relaxed.rawValue)
            } label: {
                Label("Line Spacing", systemImage: "text.alignleft")
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Appearance")
    }

    private func contentsSheet(_ model: EPUBReaderModel) -> some View {
        NavigationStack {
            List {
                if let package = model.package {
                    if package.toc.isEmpty {
                        ForEach(package.spine.indices, id: \.self) { index in
                            Button {
                                showContents = false
                                model.isFollowing = false
                                Task { await model.show(spineIndex: index) }
                            } label: {
                                Text("Section \(index + 1)")
                                    .foregroundStyle(Color.shelfCream)
                            }
                        }
                    } else {
                        ForEach(Array(package.toc.enumerated()), id: \.offset) { _, entry in
                            Button {
                                showContents = false
                                model.isFollowing = false
                                Task { await model.show(href: entry.href) }
                            } label: {
                                Text(verbatim: entry.title)
                                    .foregroundStyle(Color.shelfCream)
                                    .padding(.leading, CGFloat(max(0, entry.level)) * 16)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton { showContents = false }
                        .monochromeToolbarItem()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Style

    /// The stored scale, or one derived from Dynamic Type (.large = 1.0, about 0.1 per step).
    private var currentScale: Double {
        if storedScale > 0 { return storedScale }
        let sizes = Array(DynamicTypeSize.allCases)
        let steps = (sizes.firstIndex(of: dynamicTypeSize) ?? 0) - (sizes.firstIndex(of: .large) ?? 0)
        return min(2.5, max(0.8, (1.0 + 0.1 * Double(steps)).rounded(toPlaces: 1)))
    }

    private var currentLineSpacing: EPUBLineSpacing {
        EPUBLineSpacing(rawValue: lineSpacing) ?? .normal
    }

    private func makeStyle() -> EPUBReaderStyle {
        // Batch 490 (REVIEW 2026-11-11 F31): Black uses the app's dark-appearance ink and
        // accent; Sepia uses fixed paper colours (see `EPUBPageTheme.colours`).
        let theme = EPUBPageTheme(rawValue: pageTheme) ?? .matchApp
        let scheme: ColorScheme = theme == .black ? .dark : colorScheme
        let colours = theme.colours(app: (background: hex(.shelfBackground, scheme: scheme),
                                          text: hex(.shelfCream, scheme: scheme),
                                          accent: hex(.shelfAmberText, scheme: scheme)))
        return EPUBReaderStyle(
            backgroundHex: colours.background,
            textHex: colours.text,
            accentHex: colours.accent,
            fontScale: currentScale,
            serif: serif)
    }

    /// Resolves a theme colour for the given (default: current) appearance as `#RRGGBB`.
    private func hex(_ color: Color, scheme: ColorScheme? = nil) -> String {
        let traits = UITraitCollection(userInterfaceStyle: (scheme ?? colorScheme) == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}

/// Batch 490 (REVIEW 2026-11-11 F31): the EPUB page colour. Pure and not gated on iOS 26
/// so `QuickWinsBookDetailTests` can pin it. Stored by raw value in `epubReader.theme`.
nonisolated enum EPUBPageTheme: String, CaseIterable, Sendable {
    case matchApp, sepia, black

    typealias Colours = (background: String, text: String, accent: String)

    /// Sepia: #5B4636 text on #F4ECD8 is about 7.5:1, the #8B5A12 link about 5.0:1 (WCAG AA
    /// for body text). Black: a true #000000 page with the app's dark-appearance ink and
    /// accent (`app` already resolved for dark by the caller).
    func colours(app: Colours) -> Colours {
        switch self {
        case .matchApp: return app
        case .sepia: return (background: "#F4ECD8", text: "#5B4636", accent: "#8B5A12")
        case .black: return (background: "#000000", text: app.text, accent: app.accent)
        }
    }
}

/// Batch 495 (REVIEW 2026-11-11 L13): the next/previous chapter links appended after each
/// chapter's text. Pure and not gated on iOS 26, so `Batch495ReaderNavTests` can pin it.
nonisolated enum EPUBChapterNav {
    /// The contents title for a spine item: the first contents entry (in book order) whose
    /// path, fragment dropped, is that item. Nil when out of range or the contents don't
    /// name it (the link then just says Next Chapter).
    static func title(forSpineIndex index: Int, spineHrefs: [String], toc: [EPUBTOCEntry]) -> String? {
        guard spineHrefs.indices.contains(index) else { return nil }
        let target = spineHrefs[index]
        for entry in toc {
            let path = entry.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? entry.href
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if path == target, !title.isEmpty { return title }
        }
        return nil
    }

    /// Run in the reader's JS world with `nextHref`, `nextText`, `prevHref`, `prevText` and
    /// `label` in scope. An empty href leaves that link out; with neither, nothing is added.
    /// Replaces an earlier copy, so a reload or restyle never doubles it. Inline styles are
    /// allowed by the reader's CSP (`style-src … 'unsafe-inline'`); the links take the
    /// reader's accent colour from its own stylesheet, and are at least 44 pt tall.
    static let script = #"""
    const old = document.getElementById('shelfhead-chapter-nav');
    if (old) { old.remove(); }
    if (!document.body || (!nextHref && !prevHref)) { return null; }
    const nav = document.createElement('nav');
    nav.id = 'shelfhead-chapter-nav';
    nav.setAttribute('aria-label', label);
    nav.setAttribute('style', 'margin: 3em 0 2em; padding: 0; text-indent: 0;');
    function add(href, text, strong) {
        if (!href) { return; }
        const a = document.createElement('a');
        a.href = href;
        a.textContent = text;
        a.setAttribute('style', 'display: block; box-sizing: border-box; min-height: 44px; padding: 0.75em 0; '
            + 'text-align: center; text-decoration: none; text-indent: 0; font-weight: ' + (strong ? '600' : '400') + ';');
        nav.appendChild(a);
    }
    add(nextHref, nextText, true);
    add(prevHref, prevText, false);
    document.body.appendChild(nav);
    return null;
    """#
}

/// Batch 490 (REVIEW 2026-11-11 F31): the EPUB line spacing. `EPUBReaderStyle.css` sets
/// 1.6 on the body; Relaxed overrides it (and the book's own paragraph rules) with 1.9.
nonisolated enum EPUBLineSpacing: String, CaseIterable, Sendable {
    case normal, relaxed

    var css: String {
        switch self {
        case .normal: return ""
        case .relaxed: return "\nbody, body p, body li, body div, body blockquote { line-height: 1.9 !important; }"
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
