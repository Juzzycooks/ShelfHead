import SwiftUI
import WatchConnectivity

// ADD THESE TO: a new watchOS App target ("ShelfHead Watch").
// The watch app mirrors playback state and sends transport commands to the phone
// over WatchConnectivity. On the phone side, implement a matching WCSessionDelegate
// that maps commands ("play","pause","skipForward","skipBackward") onto
// AudioPlayerService.shared. See ShelfHeadExtras/SETUP.md.

@main
struct ShelfHeadWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityModel()

    var body: some Scene {
        WindowGroup {
            WatchPlayerView()
                .environmentObject(connectivity)
        }
    }
}

final class WatchConnectivityModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var title: String = "Not Playing"
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ command: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": command], replyHandler: nil)
    }

    // Receive state updates pushed from the phone.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.title = applicationContext["title"] as? String ?? self.title
            self.isPlaying = applicationContext["isPlaying"] as? Bool ?? self.isPlaying
            self.progress = applicationContext["progress"] as? Double ?? self.progress
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}

struct WatchPlayerView: View {
    @EnvironmentObject var model: WatchConnectivityModel

    var body: some View {
        VStack(spacing: 12) {
            Text(model.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            ProgressView(value: model.progress).tint(.orange)
            HStack(spacing: 20) {
                Button { model.send("skipBackward") } label: { Image(systemName: "gobackward.15") }
                Button { model.send(model.isPlaying ? "pause" : "play") } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { model.send("skipForward") } label: { Image(systemName: "goforward.30") }
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}
