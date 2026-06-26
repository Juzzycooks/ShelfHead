import SwiftUI
import AVFoundation
import UIKit

/// Handles background URLSession completion events for downloads.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
        DownloadManager.shared.ensureSessionReady()
    }
}

@main
struct ShelfHeadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var authViewModel = AuthViewModel()
    @State private var playerViewModel = PlayerViewModel()
    @State private var libraryViewModel = LibraryViewModel()

    init() {
        SettingsStore.registerDefaults()
        configureAudioSession()
        configureAppearance()
        // Recreate the background download session so it reconnects to any
        // in-flight downloads from a previous launch.
        DownloadManager.shared.ensureSessionReady()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authViewModel)
                .environment(playerViewModel)
                .environment(libraryViewModel)
                .preferredColorScheme(.dark)
        }
    }

    private func configureAudioSession() {
        do {
            // Set the category at launch; activation happens when playback starts
            // (see AudioPlayerService.play) so we don't interrupt other audio early.
            let session = AVAudioSession.sharedInstance()
            // Allow (and auto-route to) Bluetooth A2DP / AirPlay so output switches to
            // AirPods when they connect. Passing [] can suppress that auto-routing.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        } catch {
            #if DEBUG
            print("Failed to configure audio session: \(error)")
            #endif
        }
    }

    private func configureAppearance() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Color.shelfBackground)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Color.shelfBackground)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}
