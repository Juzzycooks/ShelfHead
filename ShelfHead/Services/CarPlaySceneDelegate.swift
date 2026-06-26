import Foundation
import CarPlay

/// CarPlay entry point. Shows "Continue Listening" and "Downloaded" lists and
/// drives playback through the shared `AudioPlayerService`.
///
/// NOTE: To activate CarPlay you must (1) add the `com.apple.developer.carplay-audio`
/// entitlement (requested from Apple), and (2) declare this class as the
/// `CPTemplateApplicationSceneSessionRoleApplication` scene delegate in Info.plist.
/// See CHANGES_IMPLEMENTED.md for the exact steps. Until then this file simply
/// compiles and is unused.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let listTemplate = makeRootTemplate()
        interfaceController.setRootTemplate(listTemplate, animated: true, completion: nil)
        Task { await reload(listTemplate) }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    private func makeRootTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "ShelfHead", sections: [])
        template.emptyViewSubtitleVariants = ["Loading your books…"]
        return template
    }

    @MainActor
    private func reload(_ template: CPListTemplate) async {
        var sections: [CPListSection] = []

        // Downloaded books (always available, even offline).
        let downloadedItems = DownloadManager.shared.downloadedItems.compactMap {
            DownloadManager.shared.manifest(for: $0)
        }
        if !downloadedItems.isEmpty {
            let items = downloadedItems.map { book -> CPListItem in
                let item = CPListItem(text: book.title, detailText: book.author)
                item.handler = { [weak self] _, completion in
                    self?.playDownloaded(book)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Downloaded", sectionIndexTitle: nil))
        }

        // Continue Listening from the server (best effort).
        if let continueItems = await fetchContinueListening(), !continueItems.isEmpty {
            let items = continueItems.map { libraryItem -> CPListItem in
                let item = CPListItem(text: libraryItem.title, detailText: libraryItem.authorName)
                item.handler = { [weak self] _, completion in
                    self?.playFromServer(libraryItem)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Continue Listening", sectionIndexTitle: nil))
        }

        template.updateSections(sections)
    }

    // MARK: - Data

    private func fetchContinueListening() async -> [LibraryItem]? {
        guard AuthStore.shared.isConfigured else { return nil }
        guard let library = try? await AudiobookshelfAPI.shared.getLibraries().first else { return nil }
        guard let shelves = try? await AudiobookshelfAPI.shared.getPersonalizedView(libraryId: library.id) else { return nil }
        return shelves.first(where: { $0.labelStringKey == "LabelContinueListening" })?.entities
    }

    // MARK: - Playback

    private func playFromServer(_ item: LibraryItem) {
        Task {
            do {
                let session = try await AudiobookshelfAPI.shared.startPlaybackSession(itemId: item.id)
                await MainActor.run {
                    AudioPlayerService.shared.startPlayback(session: session, startTime: session.currentTime)
                    self.pushNowPlaying()
                }
            } catch {
                if let session = DownloadManager.shared.localSession(for: item.id) {
                    await MainActor.run {
                        AudioPlayerService.shared.startPlayback(session: session, startTime: session.currentTime)
                        self.pushNowPlaying()
                    }
                }
            }
        }
    }

    private func playDownloaded(_ book: DownloadedBook) {
        guard let session = DownloadManager.shared.localSession(for: book.id) else { return }
        AudioPlayerService.shared.startPlayback(session: session, startTime: session.currentTime)
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
