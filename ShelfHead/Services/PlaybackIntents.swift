import Foundation
import AppIntents

/// Bridges Siri / Shortcuts "resume" into the running app's player.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()
    weak var playerViewModel: PlayerViewModel?
    private init() {}

    /// Resume the most recently played, unfinished book.
    func resumeMostRecent() async {
        await ensureConfigured()
        guard let item = try? await AudiobookshelfAPI.shared.getItemsInProgress().first else { return }
        await playerViewModel?.startPlayback(for: item)
    }

    /// On a cold launch via Siri the session may not be restored yet — seed it from the Keychain.
    private func ensureConfigured() async {
        guard await !AudiobookshelfAPI.shared.isConfigured else { return }
        guard let serverURL = try? await KeychainService.shared.get(.serverURL),
              let accessToken = try? await KeychainService.shared.get(.authToken) else { return }
        let refresh = try? await KeychainService.shared.get(.refreshToken)
        await AudiobookshelfAPI.shared.configure(serverURL: serverURL, accessToken: accessToken, refreshToken: refresh ?? nil)
    }
}

struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Listening"
    static var description = IntentDescription("Resume your most recent audiobook.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackCoordinator.shared.resumeMostRecent()
        return .result()
    }
}

struct ShelfHeadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue my audiobook in \(.applicationName)",
                "Play my book in \(.applicationName)"
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.fill"
        )
    }
}
