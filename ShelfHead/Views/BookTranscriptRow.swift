import SwiftUI

/// Batch 422 (transcription foundation): the book page's Transcript row, placed after the
/// Bookmarks row. Since Batch 450 it is a row of Book Detail's grouped list (no card of its
/// own) and carries its own actions rather than opening a sheet.
///
/// Shown only on iOS 26+ (on-device speech), only with transcripts switched on in Settings,
/// and only when the book is downloaded or already has a transcript; otherwise it renders
/// nothing, so the call site is a single line.
struct BookTranscriptRow: View {
    let itemId: String
    let title: String
    /// `metadata.language` from the server, shown as the language the transcript follows.
    let language: String?
    /// Batch 424: opens Search in Book. nil hides the Search button.
    var onSearch: (() -> Void)? = nil

    @AppStorage(SettingsKeys.transcriptsEnabled) private var transcriptsEnabled = true
    @State private var center = TranscriptionCenter.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var showLanguageSheet = false
    @State private var pendingLanguage: String??   // outer nil = none pending; inner nil = "Match the book"
    @State private var confirmRedo = false
    @State private var confirmDelete = false

    private var state: TranscriptionCenter.ItemState { center.state(for: itemId) }

    /// Batch 450: also asked by Book Detail, which places this row in its grouped list.
    @MainActor
    static func isVisible(itemId: String, transcriptsEnabled: Bool) -> Bool {
        let center = TranscriptionCenter.shared
        guard center.canTranscribe, transcriptsEnabled else { return false }
        return DownloadManager.shared.isDownloaded(itemId: itemId) || center.state(for: itemId) == .complete
    }

    private var isVisible: Bool {
        guard center.canTranscribe, transcriptsEnabled else { return false }
        return downloadManager.isDownloaded(itemId: itemId) || state == .complete
    }

    var body: some View {
        if isVisible {
            // Batch 450: a row inside Book Detail's grouped list, so no card of its own.
            content
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .sheet(isPresented: $showLanguageSheet) { languageSheet }
                .confirmationDialog("Change transcript language?", isPresented: $confirmRedo, titleVisibility: .visible) {
                    Button("Change and Redo Transcript", role: .destructive) {
                        if let pending = pendingLanguage {
                            center.setLanguageOverride(pending, for: itemId)
                            // The old transcript was invalidated; start the new one right away.
                            center.transcribeNow(itemId: itemId, title: title)
                        }
                        pendingLanguage = nil
                    }
                    Button("Cancel", role: .cancel) { pendingLanguage = nil }
                } message: {
                    Text("This replaces the current transcript. It will be made again in the new language.")
                }
                .systemChromeTint()
                .confirmationDialog("Delete this transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Transcript", role: .destructive) {
                        center.deleteTranscript(itemId: itemId)
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .systemChromeTint()
        }
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        switch state {
        case .notStarted:
            HStack {
                header(subtitle: nil)
                Spacer(minLength: 8)
                actionButton("Transcribe") {
                    center.transcribeNow(itemId: itemId, title: title)
                }
            }
        case .queued:
            HStack {
                header(subtitle: "Waiting to transcribe")
                Spacer(minLength: 8)
                actionButton("Cancel") { center.cancel(itemId: itemId) }
            }
        case .running(let fraction):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    header(subtitle: "Transcribing\u{2026}")
                    Spacer(minLength: 8)
                    actionButton("Cancel") { center.cancel(itemId: itemId) }
                }
                progressBar(fraction)
                    .padding(.leading, 36)
            }
        case .paused(let fraction):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    header(subtitle: "Paused")
                    Spacer(minLength: 8)
                    if let onSearch { actionButton("Search", action: onSearch) }
                    actionButton("Resume") {
                        center.transcribeNow(itemId: itemId, title: title)
                    }
                }
                progressBar(fraction)
                    .padding(.leading, 36)
            }
        case .complete:
            HStack {
                header(subtitle: "Transcript ready", glyph: "checkmark.circle.fill")
                Spacer(minLength: 8)
                if let onSearch { actionButton("Search", action: onSearch) }
                Menu {
                    Button {
                        showLanguageSheet = true
                    } label: { Label("Language\u{2026}", systemImage: "globe") }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: { Label("Delete Transcript", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Color.shelfAmberText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .systemChromeTint()
                .accessibilityLabel("Transcript options")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    header(subtitle: nil)
                    Spacer(minLength: 8)
                    actionButton("Retry") {
                        center.transcribeNow(itemId: itemId, title: title)
                    }
                }
                Label {
                    // DESIGN.md orange rule: orange glyph, cream sentence.
                    Typo.supporting(Text(verbatim: message))
                        .foregroundStyle(Color.shelfCream)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.shelfOrange)
                }
                .padding(.leading, 36)
            }
        }
    }

    private func header(subtitle: LocalizedStringResource?, glyph: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.quote")
                .foregroundStyle(Color.shelfAmberText)
                .frame(width: 24)
                .accessibilityHidden(true)
            headerText(subtitle: subtitle, glyph: glyph)
        }
    }

    private func headerText(subtitle: LocalizedStringResource?, glyph: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Typo.rowTitle(Text("Transcript"))
                .foregroundStyle(Color.shelfCream)
            if let subtitle {
                Label {
                    Typo.supporting(Text(subtitle))
                        .foregroundStyle(Color.shelfMuted)
                } icon: {
                    if let glyph {
                        Image(systemName: glyph).foregroundStyle(Color.shelfAmberText)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func actionButton(_ label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Typo.rowTitle(Text(label))
                .foregroundStyle(Color.shelfAmberText)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progressBar(_ fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let percent = Int((clamped * 100).rounded())
        return HStack(spacing: 12) {
            ProgressView(value: clamped)
                .tint(Color.shelfAmber)
            Typo.figure(Text(verbatim: "\(percent)%"))
                .foregroundStyle(Color.shelfMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcription progress")
        .accessibilityValue(Text(verbatim: "\(percent)%"))
    }

    // MARK: - Language override

    private var languageSheet: some View {
        TranscriptLanguageSheet(
            bookLanguage: language,
            current: center.languageOverride(for: itemId),
            onSelect: { choice in
                showLanguageSheet = false
                guard choice != center.languageOverride(for: itemId) else { return }
                pendingLanguage = .some(choice)
                // Wait a beat so the sheet's dismissal doesn't swallow the dialog.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmRedo = true }
            })
    }
}

/// The per-book language picker: "Match the book" or one of the transcriber's locales.
private struct TranscriptLanguageSheet: View {
    let bookLanguage: String?
    let current: String?
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []

    private var options: [(identifier: String, name: String)] {
        locales
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: Text("Match the book"), selected: current == nil) { onSelect(nil) }
                    ForEach(options, id: \.identifier) { option in
                        row(name: Text(verbatim: option.name), selected: current == option.identifier) {
                            onSelect(option.identifier)
                        }
                    }
                } footer: {
                    Typo.supporting(Text("Changing the language replaces this transcript and makes it again."))
                        .foregroundStyle(Color.shelfMuted)
                }
                .listRowBackground(Color.shelfCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("Transcript Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                }
            }
            .task { locales = await TranscriptionCenter.shared.supportedLocales() }
        }
    }

    private func row(name: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack {
                name.foregroundStyle(Color.shelfCream)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.shelfAmberText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
