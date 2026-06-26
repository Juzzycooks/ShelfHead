import SwiftUI

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var isCheckingSession = true

    var body: some View {
        Group {
            if isCheckingSession {
                // Splash / loading state — prevents login screen flash
                ZStack {
                    Color.shelfBackground.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "headphones.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(Color.shelfAmber)
                        Text("ShelfHead")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(Color.shelfAmber)
                    }
                }
            } else if authViewModel.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authViewModel.isAuthenticated)
        .animation(.easeInOut(duration: 0.2), value: isCheckingSession)
        .task {
            PlaybackCoordinator.shared.playerViewModel = playerViewModel
            await authViewModel.checkExistingSession()
            // Restore the last-played book into the mini-player (paused, ready to resume)
            // so a relaunch after iOS reclaimed the app picks up where you left off.
            if authViewModel.isAuthenticated {
                playerViewModel.restoreLastSession()
            }
            isCheckingSession = false
        }
    }
}

struct MainTabView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var selectedTab = 0
    @State private var homeReset = 0
    @State private var libraryReset = 0
    @State private var downloadManager = DownloadManager.shared

    private let tabs = [
        RetroTabItem(icon: "radio", label: "Home"),
        RetroTabItem(icon: "recordingtape", label: "Library"),
        RetroTabItem(icon: "arrow.down.to.line", label: "Tapes"),
        RetroTabItem(icon: "slider.horizontal.3", label: "Setup")
    ]

    var body: some View {
        @Bindable var playerViewModel = playerViewModel
        @Bindable var downloadManager = downloadManager
        return ZStack {
            Color.shelfBackground.ignoresSafeArea()

            // Keep all tabs mounted so each preserves its scroll / navigation state.
            ZStack {
                HomeView(resetToken: homeReset).opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
                LibraryView(resetToken: libraryReset).opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
                NavigationStack { DownloadsView() }.opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
                SettingsView().opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)
            }
            // Reserve space for the mini-player + tab bar so content (e.g. the Sign Out
            // button) never hides behind them. safeAreaInset propagates the inset into
            // each tab's scroll view automatically.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if playerViewModel.currentBook != nil {
                        MiniPlayerView()
                    }
                    RetroTabBar(selection: $selectedTab, items: tabs) { tappedIndex in
                        switch tappedIndex {
                        case 0: homeReset += 1
                        case 1: libraryReset += 1
                        default: break
                        }
                    }
                }
            }
        }
        .toast(message: $playerViewModel.errorMessage)
        .toast(message: $downloadManager.downloadError, duration: 6)
    }
}

#Preview {
    ContentView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
        .environment(LibraryViewModel())
}
