import SwiftUI

struct SettingsView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var showLogoutConfirmation = false
    @State private var showAddServer = false

    @AppStorage(SettingsKeys.defaultPlaybackSpeed) private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage(SettingsKeys.skipForwardInterval) private var skipForwardInterval: Double = 30
    @AppStorage(SettingsKeys.skipBackwardInterval) private var skipBackwardInterval: Double = 15
    @AppStorage(SettingsKeys.autoDownloadContinueListening) private var autoDownload = false
    @AppStorage(SettingsKeys.wifiOnlyDownloads) private var wifiOnlyDownloads = true
    @AppStorage(SettingsKeys.smartRewind) private var smartRewind = true
    @AppStorage(SettingsKeys.sleepFadeOut) private var sleepFadeOut = true
    @AppStorage(SettingsKeys.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(SettingsKeys.autoDeleteFinished) private var autoDeleteFinished = false
    @AppStorage(SettingsKeys.allowCellularStreaming) private var allowCellularStreaming = true

    @State private var cacheSizeText = ""

    private let skipOptions: [Double] = [10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground
                    .ignoresSafeArea()

                List {
                    // Server Info
                    Section {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(Color.shelfAmber)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Server")
                                    .font(.caption)
                                    .foregroundColor(Color.shelfMuted)
                                Text(authViewModel.serverURL)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                        }

                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(Color.shelfAmber)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Username")
                                    .font(.caption)
                                    .foregroundColor(Color.shelfMuted)
                                Text(authViewModel.username)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                        }
                    } header: {
                        RetroSectionHeader(title: "Account")
                    }
                    .listRowBackground(Color.shelfCard)

                    // Servers (multi-server switching)
                    Section {
                        ForEach(authViewModel.accounts) { account in
                            Button {
                                if account.id != authViewModel.currentAccountId {
                                    Task { await authViewModel.switchAccount(account) }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(Color.shelfMuted)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.username)
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text(account.displayHost)
                                            .font(.caption)
                                            .foregroundColor(Color.shelfMuted)
                                    }
                                    Spacer()
                                    if account.id == authViewModel.currentAccountId {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color.shelfAmber)
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            let toRemove = indexSet.map { authViewModel.accounts[$0] }
                            Task { for account in toRemove { await authViewModel.removeAccount(account) } }
                        }

                        Button {
                            showAddServer = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(Color.shelfAmber)
                                    .frame(width: 24)
                                Text("Add Server")
                                    .foregroundColor(Color.shelfAmber)
                            }
                        }
                    } header: {
                        RetroSectionHeader(title: "Servers")
                    }
                    .listRowBackground(Color.shelfCard)

                    // Playback Settings
                    Section {
                        HStack {
                            Image(systemName: "gauge.with.needle")
                                .foregroundColor(Color.shelfAccent)
                                .frame(width: 24)
                            Picker("Default Speed", selection: $defaultPlaybackSpeed) {
                                ForEach(PlaybackSpeed.allCases, id: \.rawValue) { speed in
                                    Text(speed.label).tag(speed.rawValue)
                                }
                            }
                            .tint(Color.shelfAmber)
                        }

                        HStack {
                            Image(systemName: "gobackward")
                                .foregroundColor(Color.shelfAccent)
                                .frame(width: 24)
                            Picker("Skip Back", selection: $skipBackwardInterval) {
                                ForEach(skipOptions, id: \.self) { secs in
                                    Text("\(Int(secs)) seconds").tag(secs)
                                }
                            }
                            .tint(Color.shelfAmber)
                        }

                        HStack {
                            Image(systemName: "goforward")
                                .foregroundColor(Color.shelfAccent)
                                .frame(width: 24)
                            Picker("Skip Forward", selection: $skipForwardInterval) {
                                ForEach(skipOptions, id: \.self) { secs in
                                    Text("\(Int(secs)) seconds").tag(secs)
                                }
                            }
                            .tint(Color.shelfAmber)
                        }
                        Toggle(isOn: $smartRewind) {
                            settingRow("gobackward", "Smart rewind on resume")
                        }.tint(Color.shelfAmber)

                        Toggle(isOn: $sleepFadeOut) {
                            settingRow("speaker.wave.1.fill", "Fade out before sleep")
                        }.tint(Color.shelfAmber)

                        Toggle(isOn: $keepScreenAwake) {
                            settingRow("sun.max.fill", "Keep screen awake while playing")
                        }.tint(Color.shelfAmber)
                    } header: {
                        RetroSectionHeader(title: "Playback")
                    }
                    .listRowBackground(Color.shelfCard)

                    // Downloads
                    Section {
                        Toggle(isOn: $autoDownload) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(Color.shelfAccent)
                                    .frame(width: 24)
                                Text("Auto-download Continue Listening")
                                    .foregroundColor(.white)
                            }
                        }
                        .tint(Color.shelfAmber)

                        Toggle(isOn: $wifiOnlyDownloads) {
                            HStack {
                                Image(systemName: "wifi")
                                    .foregroundColor(Color.shelfAccent)
                                    .frame(width: 24)
                                Text("Download on Wi-Fi only")
                                    .foregroundColor(.white)
                            }
                        }
                        .tint(Color.shelfAmber)

                        Toggle(isOn: $allowCellularStreaming) {
                            settingRow("antenna.radiowaves.left.and.right", "Stream on cellular")
                        }.tint(Color.shelfAmber)

                        Toggle(isOn: $autoDeleteFinished) {
                            settingRow("trash.fill", "Auto-delete finished downloads")
                        }.tint(Color.shelfAmber)

                        Button {
                            CoverImageCache.shared.removeAllObjects()
                            URLCache.shared.removeAllCachedResponses()
                            cacheSizeText = "0 KB"
                        } label: {
                            HStack {
                                settingRow("photo.stack", "Clear image cache")
                                Spacer()
                                Text(cacheSizeText).font(.caption).foregroundColor(Color.shelfMuted)
                            }
                        }
                    } header: {
                        RetroSectionHeader(title: "Downloads")
                    }
                    .listRowBackground(Color.shelfCard)

                    // Stats
                    Section {
                        NavigationLink(destination: StatsView()) {
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(Color.shelfAccent)
                                    .frame(width: 24)
                                Text("Listening Stats")
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .listRowBackground(Color.shelfCard)

                    // About
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(Color.shelfMuted)
                                .frame(width: 24)
                            Text("Version")
                                .foregroundColor(.white)
                            Spacer()
                            Text("1.0.0")
                                .foregroundColor(Color.shelfMuted)
                        }

                        HStack {
                            Image(systemName: "headphones.circle.fill")
                                .foregroundColor(Color.shelfAmber)
                                .frame(width: 24)
                            Text("ShelfHead")
                                .foregroundColor(.white)
                            Spacer()
                            Text("for Audiobookshelf")
                                .font(.caption)
                                .foregroundColor(Color.shelfMuted)
                        }
                    } header: {
                        RetroSectionHeader(title: "About")
                    }
                    .listRowBackground(Color.shelfCard)

                    // Logout
                    Section {
                        Button {
                            showLogoutConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.forward")
                                    .foregroundColor(.red)
                                    .frame(width: 24)
                                Text("Sign Out")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .listRowBackground(Color.shelfCard)
                }
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    // This List is inside its own NavigationStack, so the tab-container
                    // inset doesn't reach it — reserve space here so the last row
                    // (Sign Out) clears the floating mini-player + tab bar.
                    Color.clear
                        .frame(height: playerViewModel.currentBook != nil ? 152 : 88)
                }
            }
            .navigationTitle("Settings")
            .task {
                await authViewModel.loadAccounts()
                cacheSizeText = ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.currentDiskUsage), countStyle: .file)
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
            .onChange(of: skipForwardInterval) { _, _ in
                AudioPlayerService.shared.refreshSkipIntervals()
            }
            .onChange(of: skipBackwardInterval) { _, _ in
                AudioPlayerService.shared.refreshSkipIntervals()
            }
            .alert("Sign Out", isPresented: $showLogoutConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    Task {
                        await authViewModel.logout()
                    }
                }
            } message: {
                Text("Are you sure you want to sign out? Your playback will be stopped.")
            }
        }
    }

    private func settingRow(_ icon: String, _ text: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(Color.shelfAccent)
                .frame(width: 24)
            Text(text)
                .foregroundColor(.white)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AuthViewModel())
        .environment(PlayerViewModel())
}
