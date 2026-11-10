import Foundation
import CarPlay
import UIKit

// =============================================================================
// ShelfHead • CarPlay template builders
// =============================================================================

/// Setup is a read-only status screen. CarPlay has no in-car sign-in flow, so it
/// only reports status and defers account changes to the phone.
///
/// NOTE: it is a `CPListTemplate`, NOT a `CPInformationTemplate`. Only templates
/// conforming to `CPBarButtonProviding` (list/grid) are valid tabs inside a
/// `CPTabBarTemplate`; using `CPInformationTemplate` as a tab makes
/// `-[CPTabBarTemplate validateTemplates:]` throw at launch.
enum SetupTemplateBuilder {
    // `make()` reads `AudioPlayerService.shared.playbackRate`, which is main-actor
    // isolated now that `AudioPlayerService` is `@MainActor` — mark this `@MainActor`
    // too rather than `await`ing, since its only caller (`CarPlayCoordinator.start()`)
    // is itself `@MainActor` and calls this synchronously.
    @MainActor
    static func make() -> CPListTemplate {
        let server = AuthStore.shared.serverURL
        let connected = AuthStore.shared.isConfigured

        // Non-selectable status rows ("label" + detail).
        let rows: [(String, String)] = [
            (String(localized: "Account"), connected ? String(localized: "Signed in") : String(localized: "Not signed in")),
            (String(localized: "Server"), server.isEmpty ? "—" : server),
            // PL-13 (docs/design-review.md, Round 5): was `String(format: "%.2gx", …)`, a
            // second copy of the rate formatting with a lower-case "x" that rounded 2.75
            // to "2.8x". The coordinator's formatter is the one the live row uses.
            (String(localized: "Playback Speed"), CarPlayCoordinator.formattedPlaybackRate(AudioPlayerService.shared.playbackRate)),
            (String(localized: "Downloaded"), String(localized: "\(DownloadManager.shared.downloadedItems.count) audiobooks", comment: "CarPlay Setup row detail. %lld is the number of downloaded audiobooks."))
        ]

        let items = rows.map { title, detail -> CPListItem in
            let item = CPListItem(text: title, detailText: detail)
            item.handler = { _, completion in completion() }   // no-op; read-only
            return item
        }

        let template = CPListTemplate(
            title: String(localized: "Setup"),
            sections: [CPListSection(items: items, header: String(localized: "Manage your account on the phone"), sectionIndexTitle: nil)]
        )
        template.tabTitle = String(localized: "Setup")
        template.tabImage = UIImage(systemName: "gearshape.fill")
        return template
    }
}
