import Intents

/// PL-14 (docs/design-review.md): the Intents Extension CarPlay needs before an audio app may
/// show the Siri "assistant cell" (`CPAssistantCellConfiguration`, iOS 15.0; Apple docs: "audio
/// apps must support `INPlayMediaIntent`"). App Intents alone don't qualify.
///
/// The extension does no work of its own: it carries what Siri heard to the app and answers
/// `.handleInApp`. The app searches the library and starts playback (`ContentView`'s
/// `INPlayMediaIntent` continuation, then `PlaybackCoordinator`), because playback needs the
/// player, the Keychain session and the audio session that only the app process has.
class IntentHandler: INExtension, INPlayMediaIntentHandling {

    /// Type name the app registers in `NSUserActivityTypes` and listens for.
    static let activityType = "INPlayMediaIntent"
    /// `userInfo` key holding the spoken title or author ("play Emma"); absent for a bare "play".
    static let mediaNameKey = "mediaName"

    override func handler(for intent: INIntent) -> Any {
        self
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let activity = NSUserActivity(activityType: Self.activityType)
        if let name = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            activity.userInfo = [Self.mediaNameKey: name]
        }
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity))
    }
}
