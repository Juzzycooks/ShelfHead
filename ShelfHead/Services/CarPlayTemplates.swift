import Foundation
import CarPlay
import UIKit

// =============================================================================
// ShelfHead • CarPlay template builders
// =============================================================================

/// Setup holds the two playback controls a driver uses in the car (Playback Speed and
/// Listening Profile). CarPlay has no in-car sign-in flow, and account status doesn't
/// belong on the car's screen.
///
/// NOTE: it is a `CPListTemplate`, NOT a `CPInformationTemplate`. Only templates
/// conforming to `CPBarButtonProviding` (list/grid) are valid tabs inside a
/// `CPTabBarTemplate`; using `CPInformationTemplate` as a tab makes
/// `-[CPTabBarTemplate validateTemplates:]` throw at launch.
enum SetupTemplateBuilder {
    // Kept `@MainActor` (its only caller, `CarPlayCoordinator`, is `@MainActor` and calls
    // this synchronously).
    //
    // Batch 490 (REVIEW 2026-11-11 C4): this used to build inert Account, Server, Speed
    // and Downloaded rows under a "Manage your account on the phone" header. They were
    // never seen — `CarPlayCoordinator.start()` replaces them synchronously via
    // `reloadSetup()` — but they repeated copy CarPlay must not show. The template now
    // starts empty and `reloadSetup()` owns every row.
    @MainActor
    static func make() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Setup"), sections: [])
        template.tabTitle = String(localized: "Setup")
        template.tabImage = UIImage(systemName: "gearshape.fill")
        return template
    }
}
