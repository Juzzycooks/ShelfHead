import SwiftUI
import UniformTypeIdentifiers

/// Batch 444: Upload screen. Pick a library and folder, add audio / EPUB / PDF files (or arrive here
/// from "Open in ShelfHead"), check the title, author and series suggested from the files' own
/// metadata, and send them to the server (`POST /api/upload`) with a progress screen and Cancel.
/// Only for accounts that may upload (`User.canUpload`). Pushable (Settings > Server) and
/// presentable as a sheet via `UploadSheet`.
struct UploadView: View {
    // Polish pass (Phase 5): was a fixed 48pt glyph.
    @ScaledMetric(relativeTo: .largeTitle) private var doneGlyphSize: CGFloat = 48
    var bottomInset: CGFloat = 0
    /// Called when the user taps "Open Library" after a successful upload.
    var onOpenLibrary: ((String) -> Void)?

    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var model = UploadViewModel()
    @State private var inbox = UploadInbox.shared
    @State private var showImporter = false

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .epub, .pdf, .image]
        if let cue = UTType(filenameExtension: "cue") { types.append(cue) }
        return types
    }()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingView("Checking access\u{2026}")
            case .notPermitted:
                EmptyStateView(icon: "lock.shield", title: LocalizedStringResource("Uploads aren’t allowed"),
                               subtitle: LocalizedStringResource("This account doesn’t have permission to upload. Ask a server admin to turn on Upload for it."))
            case .editing:
                form
            case .preparing:
                progress(sent: 0, total: 0)
            case .uploading(let sent, let total):
                progress(sent: sent, total: total)
            case .done:
                done
            case .failed(let message):
                EmptyStateView(icon: "exclamationmark.triangle", title: LocalizedStringResource("Upload didn’t finish"),
                               subtitle: .verbatim(message),
                               actionTitle: LocalizedStringResource("Back to Upload")) { model.backToEditing() }
            }
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(user: authViewModel.currentUser, preferredLibraryId: libraryViewModel.selectedLibrary?.id)
            model.addFiles(inbox.drain())
        }
        .onChange(of: inbox.pendingFiles) { _, _ in
            if model.phase == .editing { model.addFiles(inbox.drain()) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        // Review 2 Medium 9 (30 October 2026): no `.onDisappear` teardown. It also fires on a tab
        // switch and killed a running upload. The view model's `deinit` (Review Medium 32) cancels the
        // upload, releases file access and deletes the temp body once the view is popped or the sheet
        // dismissed, which is when `@State` lets the model go.
        .tint(Color.shelfAmberText)
        .systemChromeTint()
        .reexpandsTabBarOnAppear()
    }

    // MARK: Form

    private var form: some View {
        @Bindable var model = model
        return List {
            Section {
                Picker("Library", selection: $model.libraryId) {
                    ForEach(model.libraries) { library in Text(verbatim: library.name).tag(library.id) }
                }
                .onChange(of: model.libraryId) { _, _ in model.libraryChanged() }
                if model.folders.count > 1 {
                    Picker("Folder", selection: $model.folderId) {
                        ForEach(model.folders) { folder in
                            Text(verbatim: folder.fullPath ?? folder.id).tag(folder.id)
                        }
                    }
                }
            } header: {
                RetroSectionHeader(title: "Destination")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                fileRows
                Button { showImporter = true } label: {
                    Label("Add Files", systemImage: "plus.circle")
                }
                .frame(minHeight: 44)
            } header: {
                RetroSectionHeader(title: "Files")
            } footer: {
                if !model.files.isEmpty {
                    Typo.supporting(Text("\(model.files.count) files, \(Self.sizeText(model.totalBytes))"))
                        .foregroundStyle(Color.shelfMuted)
                }
            }
            .listRowBackground(Color.shelfCard)

            Section {
                TextField("Title", text: $model.title)
                    .onChange(of: model.title) { _, _ in model.markEdited("title") }
                if !model.isPodcastLibrary {
                    TextField("Author", text: $model.author)
                        .onChange(of: model.author) { _, _ in model.markEdited("author") }
                    TextField("Series (optional)", text: $model.series)
                        .onChange(of: model.series) { _, _ in model.markEdited("series") }
                    if let sequence = model.suggestedSequence, !model.series.isEmpty {
                        Typo.supporting(Text("The file says book \(sequence) in this series. Audiobookshelf can’t take a number while uploading; set it on the book afterwards."))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
            } header: {
                RetroSectionHeader(title: "Details")
            } footer: {
                Typo.supporting(Text("Suggested from the files. The server stores them in a folder named after the author, series and title."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Button { model.start() } label: {
                    Label("Upload", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!model.canStart)
            }
            .listRowBackground(Color.shelfCard)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var fileRows: some View {
        ForEach(model.files) { entry in
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: entry.url)).foregroundStyle(Color.shelfAmberText)
                    .frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name).foregroundStyle(Color.shelfCream).lineLimit(2)
                    Typo.supporting(Text(verbatim: Self.sizeText(entry.size))).foregroundStyle(Color.shelfMuted)
                }
                Spacer(minLength: 0)
                Button { model.remove(entry) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.shelfMuted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(entry.name)"))
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: Progress / done

    private func progress(sent: Int64, total: Int64) -> some View {
        VStack(spacing: 16) {
            if total > 0 {
                ProgressView(value: Double(sent), total: Double(total)).shelfSpinner()
                    .padding(.horizontal, 40)
                Text("Uploading \(Self.sizeText(sent)) of \(Self.sizeText(total))")
                    .foregroundStyle(Color.shelfMuted)
                    .monospacedDigit()
            } else {
                ProgressView().shelfSpinner()
                Text("Preparing files\u{2026}").foregroundStyle(Color.shelfMuted)
            }
            Button("Cancel", role: .cancel) { model.cancel() }
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: min(doneGlyphSize, 72))).foregroundStyle(Color.shelfAmberText)
                .accessibilityHidden(true)
            Text("Uploaded").font(.title3.weight(.semibold)).foregroundStyle(Color.shelfCream)
            Typo.supporting(Text(model.scanned
                                 ? "Scan started. The book will appear in the library in a moment."
                                 : "The book shows up in the library after the server scans it."))
                .foregroundStyle(Color.shelfMuted)
                .multilineTextAlignment(.center)
            if model.isAdmin && !model.scanned {
                Button { Task { await model.scanLibrary() } } label: {
                    if model.isScanning { ProgressView() } else { Text("Scan Library Now") }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(model.isScanning)
            }
            if let onOpenLibrary {
                Button("Open Library") { onOpenLibrary(model.libraryId) }.frame(minHeight: 44)
            }
            Button("Upload Another") { model.reset() }.frame(minHeight: 44)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "epub": return "book.closed"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png": return "photo"
        case "cue": return "doc.text"
        default: return "waveform"
        }
    }
}

/// Batch 444: `UploadView` in its own navigation stack, for presenting as a sheet (files arriving
/// from "Open in ShelfHead", or the Library toolbar menu).
struct UploadSheet: View {
    var onOpenLibrary: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UploadView(onOpenLibrary: { id in dismiss(); onOpenLibrary?(id) })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
    }
}
