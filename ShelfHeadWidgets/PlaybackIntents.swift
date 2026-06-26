import AppIntents
import Foundation

/// Tapped from the widget's play/pause button. Posts a Darwin notification that the
/// running app observes (see AudioPlayerService) and toggles playback. This works
/// while the app is alive in the background (i.e. while audio is playing/paused);
/// if the app has been fully terminated, open it to resume.
struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var description = IntentDescription("Toggle audiobook playback.")

    func perform() async throws -> some IntentResult {
        postDarwin("com.shelfhead.togglePlayback")
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward in the current book.")

    func perform() async throws -> some IntentResult {
        postDarwin("com.shelfhead.skipForward")
        return .result()
    }
}

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString),
        nil, nil, true
    )
}
