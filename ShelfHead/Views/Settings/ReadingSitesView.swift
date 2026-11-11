import SwiftUI
import UniformTypeIdentifiers

/// Batch 443: the Reading Sites page content (Hardcover sync, want-to-read import, finished-books
/// export). Like `TranscriptsSettingsView`, the body is a group of sections for
/// `SettingsCategoryPage` to host. Nothing syncs until a token is connected and a toggle is on.
struct ReadingSitesView: View {
    @AppStorage(SettingsKeys.readingSiteSyncProgress) private var syncProgress = false
    @AppStorage(SettingsKeys.readingSiteMarkFinished) private var markFinished = false
    @AppStorage(SettingsKeys.readingSiteAskRating) private var askRating = false

    @Environment(LibraryViewModel.self) private var library
    @State private var model = ReadingSitesViewModel()
    @State private var showingImporter = false
    @State private var confirmDisconnect = false

    var body: some View {
        Group {
            connectionSection
            if model.isConnected { syncSection }
            wantToReadSection
            exportSection
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { model.importCSV(from: url) }
        }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                settingRow("books.vertical", "Hardcover")
                if model.isConnected {
                    if let name = model.username {
                        // Batch 490 (REVIEW 2026-11-11 V4): type role and token, not `.footnote`/`.secondary`.
                        Typo.supporting(Text(verbatim: name)).foregroundStyle(Color.shelfMuted)
                            .padding(.leading, 32)
                    }
                    HStack {
                        Button("Test Connection") { Task { await model.testConnection() } }
                        Spacer()
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 32)
                } else {
                    SecureField("API token", text: $model.tokenInput)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.leading, 32)
                    HStack {
                        Link("Get a Token", destination: HardcoverAPI.tokenPage)
                        Spacer()
                        Button("Connect") { Task { await model.connect() } }
                            .disabled(HardcoverAPI.cleanedToken(model.tokenInput).isEmpty || model.connectPhase == .working)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 32)
                }
                phaseText(model.connectPhase)
                SettingsCaption(text: "Your token is kept in this iPhone’s Keychain and only sent to hardcover.app. Your Audiobookshelf server never sees it.")
            }
            .confirmationDialog("Disconnect Hardcover?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Syncing turns off and the saved token is deleted.")
            }
            // Batch 490 (REVIEW 2026-11-11 V3)
            .systemChromeTint()
        } header: {
            RetroSectionHeader(title: "Reading Sites")
        }
        .listRowBackground(Color.shelfCard)
    }

    private var syncSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $syncProgress) { settingRow("arrow.triangle.2.circlepath", "Sync progress") }
                SettingsCaption(text: "Marks a book Currently Reading when you start it, then sends your progress at most every 10 minutes.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $markFinished) { settingRow("checkmark.circle", "Mark finished") }
                SettingsCaption(text: "Moves a book to Read when you finish it.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $askRating) { settingRow("star", "Ask to rate on finish") }
                    .disabled(!markFinished)
                SettingsCaption(text: "After a book finishes, asks for a star rating to send to Hardcover.")
            }
        } header: {
            RetroSectionHeader(title: "Sync")
        }
        .listRowBackground(Color.shelfCard)
    }

    private var wantToReadSection: some View {
        Section {
            if model.isConnected {
                Button { Task { await model.importFromHardcover() } } label: {
                    settingRow("square.and.arrow.down", "Import from Hardcover")
                }
                .disabled(model.importPhase == .working)
            }
            Button { showingImporter = true } label: {
                settingRow("doc.text", "Import Goodreads or StoryGraph CSV")
            }
            phaseText(model.importPhase)
            NavigationLink {
                WantToReadView(model: model)
            } label: {
                LabeledContent {
                    Text(model.wantToRead.count.formatted())
                } label: {
                    settingRow("bookmark", "Want to Read")
                }
            }
            SettingsCaption(text: "Export your list from Goodreads (My Books › Import and export) or StoryGraph (Manage Account › Export). Books already on your server are marked.")
        } header: {
            RetroSectionHeader(title: "Want to Read")
        }
        .listRowBackground(Color.shelfCard)
    }

    private var exportSection: some View {
        Section {
            let count = model.finishedCount(library: library)
            ShareLink(item: model.finishedBooksCSV(library: library),
                      preview: SharePreview(Text("Finished books"))) {
                settingRow("square.and.arrow.up", "Export finished books (CSV)")
            }
            .disabled(count == 0)
            SettingsCaption(text: "A Goodreads-format file of the books you’ve finished (\(count.formatted())). StoryGraph can import it too.")
        } header: {
            RetroSectionHeader(title: "Export")
        }
        .listRowBackground(Color.shelfCard)
    }

    @ViewBuilder
    private func phaseText(_ phase: ReadingSitesViewModel.Phase) -> some View {
        switch phase {
        case .idle: EmptyView()
        case .working: ProgressView().padding(.leading, 32)
        // Batch 490 (REVIEW 2026-11-11 V4): tokens, and a failure follows the DESIGN.md
        // orange rule (orange glyph beside a cream sentence) instead of red text.
        case .done(let text):
            Typo.supporting(Text(verbatim: text)).foregroundStyle(Color.shelfMuted).padding(.leading, 32)
        case .failed(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.shelfOrange)
                    .accessibilityHidden(true)
                Typo.supporting(Text(verbatim: text))
                    .foregroundStyle(Color.shelfCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.leading, 32)
        }
    }
}

/// Batch 443: asks for a star rating after a finished book. Attach once at the root with
/// `.readingRatingPrompt()`; it presents when `ReadingSiteSync.pendingRating` is set.
struct ReadingRatingSheet: View {
    let pending: PendingReadingRating
    @State private var stars: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(verbatim: pending.title).font(.headline).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { n in
                        Button { stars = Double(n) } label: {
                            Image(systemName: Double(n) <= stars ? "star.fill" : "star")
                                .font(.title).frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(n.formatted()) stars"))
                    }
                }
                .foregroundStyle(Color.shelfAmberText)
            }
            .padding()
            .navigationTitle("Rate on Hardcover")
            .navigationBarTitleDisplayMode(.inline)
            // Batch 490 (REVIEW 2026-11-11 V1): the shared sheet buttons (system ✕ and ✓ on
            // iOS 26, which also place in iPhone Duo's side bar). Skip is the cancel role, so it
            // reads "Cancel" below iOS 26, as every other sheet's does.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { ReadingSiteSync.shared.submitRating(nil); dismiss() }
                        .monochromeToolbarItem()
                }
                .shelfVisibilityPriority(.high)
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "Send") { ReadingSiteSync.shared.submitRating(stars); dismiss() }
                        .disabled(stars == 0)
                }
                .shelfVisibilityPriority(.high)
            }
        }
        .presentationDetents([.height(260)])
    }
}

extension View {
    func readingRatingPrompt() -> some View { modifier(ReadingRatingPromptModifier()) }
}

private struct ReadingRatingPromptModifier: ViewModifier {
    @State private var sync = ReadingSiteSync.shared
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { sync.pendingRating }, set: { if $0 == nil { sync.pendingRating = nil } })) {
            ReadingRatingSheet(pending: $0)
        }
    }
}
