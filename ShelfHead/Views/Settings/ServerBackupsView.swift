import SwiftUI

/// Admin-only server backup management (`/api/backups`) — lists existing backups and
/// lets an admin trigger a new one. Reached from Diagnostics. Non-admins get a plain
/// "admins only" message rather than a raw 403.
struct ServerBackupsView: View {
    var bottomInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerViewModel

    private enum LoadState { case loading, forbidden, failed(String), loaded }

    @State private var state: LoadState = .loading
    @State private var backups: [ServerBackup] = []
    @State private var isCreating = false
    @State private var createError: String?

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    private var sortedBackups: [ServerBackup] {
        backups.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingView("Loading backups…")
            case .forbidden:
                EmptyStateView(icon: "lock.shield", title: LocalizedStringResource("Admins only"),
                               subtitle: LocalizedStringResource("Only server admins can manage backups."))
            case .failed(let message):
                EmptyStateView(icon: "exclamationmark.triangle", title: LocalizedStringResource("Couldn\u{2019}t load backups"), subtitle: .verbatim(message),
                               actionTitle: LocalizedStringResource("Retry"), action: { Task { await load() } })
            case .loaded:
                list
            }
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Server Backups")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .tint(Color.shelfAmberText) // CO-7: see systemChromeTint()
        .alert("Couldn\u{2019}t Create Backup", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(createError ?? "")
        }
        .systemChromeTint()
        .reexpandsTabBarOnAppear()
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lastBackupText)
                            .foregroundStyle(Color.shelfCream)
                        Typo.supporting(Text(summaryText))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }

                Button {
                    Task { await createBackup() }
                } label: {
                    HStack {
                        Spacer()
                        if isCreating {
                            // LS-13 (docs/design-review.md, Round 3): brand-tinted, was
                            // falling back to the system tint.
                            ProgressView()
                                .shelfSpinner()
                        } else {
                            Text("Back Up Now")
                        }
                        Spacer()
                    }
                }
                .disabled(isCreating)
            } header: {
                RetroSectionHeader(title: "Backups")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                ForEach(sortedBackups) { backup in
                    backupRow(backup)
                }
            } header: {
                RetroSectionHeader(title: "History")
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
    }

    private func backupRow(_ backup: ServerBackup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(backup.filename ?? backup.id)
                .foregroundStyle(Color.shelfCream)
            Typo.supporting(HStack(spacing: 6) {
                Text(Self.byteCountText(backup.fileSize))
                Text("\u{00B7}")
                Text(Self.relativeDateText(fromEpochMs: backup.createdAt))
                if let version = backup.serverVersion {
                    Text("\u{00B7} v\(version)")
                }
            })
            .foregroundStyle(Color.shelfMuted)
        }
    }

    private var lastBackupText: String {
        guard let newest = sortedBackups.first else { return String(localized: "No backups yet") }
        return String(localized: "Last backup \(Self.relativeDateText(fromEpochMs: newest.createdAt))", comment: "%@ is a relative time such as '2 hr. ago'.")
    }

    private var summaryText: String {
        let totalBytes = backups.reduce(0) { $0 + ($1.fileSize ?? 0) }
        let count = backups.count
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return count == 1
            ? String(localized: "1 backup \u{00B7} \(size)", comment: "Backups summary. %@ is the total size, e.g. '12 MB'.")
            : String(localized: "\(count) backups \u{00B7} \(size)", comment: "Backups summary. First %lld is the count, second is the total size, e.g. '12 MB'.")
    }

    static func byteCountText(_ bytes: Int?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0), countStyle: .file)
    }

    static func relativeDateText(fromEpochMs ms: Int?) -> String {
        guard let ms else { return String(localized: "unknown time", comment: "Relative-time placeholder when a backup has no date.") }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Critique 2026-10-06 (clarify): plain copy for a backup list that didn't load.
    /// Pure, pinned by `SettingsClarityTests`.
    static func loadFailureMessage(for error: Error) -> String {
        if isOffline(error) {
            return String(localized: "You\u{2019}re offline. Connect to the internet and try again.")
        }
        if let apiError = error as? APIError, case .unauthorized = apiError {
            return String(localized: "Your sign-in to this server has expired. Sign in again to see its backups.")
        }
        return String(localized: "Your server didn\u{2019}t answer. Try again in a moment.")
    }

    /// Plain copy for a backup that couldn't be started. Pure, pinned by `SettingsClarityTests`.
    static func createFailureMessage(for error: Error) -> String {
        if isOffline(error) {
            return String(localized: "You\u{2019}re offline, so no backup was made. Connect and try again.")
        }
        if let apiError = error as? APIError, case .forbidden = apiError {
            return String(localized: "Only server admins can make backups.")
        }
        return String(localized: "Your server didn\u{2019}t make the backup. Try again in a moment, or check the server\u{2019}s free disk space.")
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(urlError.code)
    }

    private func load() async {
        state = .loading
        do {
            let response = try await AudiobookshelfAPI.shared.getBackups()
            backups = response.backups
            state = .loaded
        } catch APIError.forbidden {
            state = .forbidden
        } catch {
            // Critique 2026-10-06 (clarify): plain copy instead of the raw error text.
            ShelfLog.error(.network, "Couldn't load server backups: \(error.localizedDescription)")
            state = .failed(Self.loadFailureMessage(for: error))
        }
    }

    private func createBackup() async {
        isCreating = true
        do {
            backups = try await AudiobookshelfAPI.shared.createBackup()
            Haptics.success()
        } catch {
            // Critique 2026-10-06 (clarify): plain copy instead of the raw error text.
            ShelfLog.error(.network, "Couldn't create a server backup: \(error.localizedDescription)")
            createError = Self.createFailureMessage(for: error)
        }
        isCreating = false
    }
}
