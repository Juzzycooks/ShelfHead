import SwiftUI

/// Batch 441: Settings > Server > Library Doctor. Scans the selected library for duplicates, missing
/// covers, series numbering problems and chapter problems, and offers confirmed fixes through the
/// Audiobookshelf API. Nothing is ever deleted. Only for admins or users with the update permission.
struct LibraryDoctorView: View {
    var bottomInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var model: LibraryDoctorViewModel?
    @State private var selected: DoctorFinding?

    private var bottomClearance: CGFloat {
        bottomBarClearance(bottomInset: bottomInset, hasMiniPlayer: playerViewModel.currentBook != nil)
    }

    var body: some View {
        Group {
            if let model { content(model) } else { LoadingView("Checking access\u{2026}") }
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: bottomClearance) }
        .navigationTitle("Library Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let created = LibraryDoctorViewModel(libraryId: libraryViewModel.selectedLibrary?.id)
                model = created
                created.start(user: authViewModel.currentUser)
            }
        }
        .onDisappear { model?.cancel() }
        .tint(Color.shelfAmberText)
        .systemChromeTint()
        .reexpandsTabBarOnAppear()
    }

    @ViewBuilder
    private func content(_ model: LibraryDoctorViewModel) -> some View {
        switch model.phase {
        case .idle, .checkingAccess:
            LoadingView("Checking access\u{2026}")
        case .notPermitted:
            EmptyStateView(icon: "lock.shield", title: LocalizedStringResource("Admins only"),
                           subtitle: LocalizedStringResource("Library Doctor needs a server admin, or an account that is allowed to update items."))
        case .scanning(let loaded, let total):
            VStack(spacing: 16) {
                if total > 0 {
                    ProgressView(value: Double(loaded), total: Double(total)).shelfSpinner()
                        .padding(.horizontal, 40)
                    Text("Scanning \(loaded) of \(total) books\u{2026}")
                        .foregroundStyle(Color.shelfMuted)
                } else {
                    ProgressView().shelfSpinner()
                    Text("Scanning library\u{2026}").foregroundStyle(Color.shelfMuted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(icon: "exclamationmark.triangle", title: LocalizedStringResource("Couldn’t scan the library"),
                           subtitle: .verbatim(message))
                .overlay(alignment: .bottom) {
                    Button("Retry") { model.start(user: authViewModel.currentUser) }
                        .foregroundStyle(Color.shelfAmberText)
                        .padding(.bottom, 40)
                }
        case .ready:
            if model.findings.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: LocalizedStringResource("Nothing to fix"),
                               subtitle: LocalizedStringResource("No duplicates, missing covers, series or chapter problems were found."),
                               actionTitle: LocalizedStringResource("Scan Again")) { model.rescan() }
            } else {
                list(model)
            }
        }
    }

    private func list(_ model: LibraryDoctorViewModel) -> some View {
        List {
            Section {
                Typo.supporting(Text("\(model.findings.count) things to look at across \(model.scannedCount) books. Nothing is changed until you confirm, and nothing is ever deleted."))
                    .foregroundStyle(Color.shelfMuted)
                Button("Scan Again") { model.rescan() }
            }
            .listRowBackground(Color.shelfCard)

            ForEach(model.grouped, id: \.kind) { group in
                Section {
                    ForEach(group.findings) { finding in
                        Button { selected = finding } label: { row(finding, model) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        RetroSectionHeader(title: Self.title(group.kind))
                        Spacer()
                        Text(verbatim: "\(group.findings.count)").foregroundStyle(Color.shelfMuted)
                    }
                }
                .listRowBackground(Color.shelfCard)
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $selected) { finding in
            LibraryDoctorFindingSheet(finding: finding, model: model)
        }
    }

    private func row(_ finding: DoctorFinding, _ model: LibraryDoctorViewModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: finding.severity == .warning ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(finding.severity == .warning ? Color.shelfAmberText : Color.shelfMuted)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: finding.subject).foregroundStyle(Color.shelfCream)
                Typo.supporting(Self.summary(finding)).foregroundStyle(Color.shelfMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.shelfMuted)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    static func title(_ kind: DoctorFindingKind) -> LocalizedStringResource {
        switch kind {
        case .duplicate: return "Possible Duplicates"
        case .missingCover: return "Missing Covers"
        case .seriesMissingSequence: return "Series: No Number"
        case .seriesDuplicateSequence: return "Series: Repeated Number"
        case .seriesGap: return "Series: Gaps"
        case .badChapters: return "Chapters"
        }
    }

    static func summary(_ finding: DoctorFinding) -> Text {
        switch finding.detail {
        case .duplicate(let reason, _):
            switch reason {
            case .asin: return Text("\(finding.itemIds.count) books share an ASIN")
            case .isbn: return Text("\(finding.itemIds.count) books share an ISBN")
            case .titleAndAuthor: return Text("\(finding.itemIds.count) books share title and author")
            }
        case .missingCover: return Text("No cover image")
        case .seriesMissingSequence(let series): return Text("Has no number in \(series)")
        case .seriesDuplicateSequence(let series, let sequence):
            return Text("\(finding.itemIds.count) books are #\(SeriesSequenceFormat.string(sequence)) in \(series)")
        case .seriesGap(_, let missing):
            return Text("No book numbered \(missing.map(String.init).joined(separator: ", "))")
        case .badChapters(let issues):
            return Text(chapterIssueText(issues))
        }
    }

    static func chapterIssueText(_ issues: [ChapterHealthIssue]) -> String {
        issues.compactMap { issue -> String? in
            switch issue {
            case .none: return String(localized: "No chapters")
            case .single: return String(localized: "Only one chapter")
            case .overlong: return String(localized: "A chapter is over 3 hours")
            case .dropped: return String(localized: "Some chapters couldn\u{2019}t be read")
            }
        }.joined(separator: ". ")
    }
}

// MARK: - Finding sheet

struct LibraryDoctorFindingSheet: View {
    let finding: DoctorFinding
    let model: LibraryDoctorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sequenceText = ""
    @State private var pending: LibraryDoctorViewModel.PendingChange?
    @State private var done = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Typo.supporting(LibraryDoctorView.summary(finding)).foregroundStyle(Color.shelfCream)
                    if case .seriesGap = finding.detail {
                        Typo.supporting(Text("This is only a heads-up. Renumbering books would break their real order."))
                            .foregroundStyle(Color.shelfMuted)
                    }
                    if case .duplicate = finding.detail {
                        Typo.supporting(Text("Library Doctor never deletes anything. Open each book to decide what to keep."))
                            .foregroundStyle(Color.shelfMuted)
                    }
                }
                .listRowBackground(Color.shelfCard)

                Section {
                    ForEach(finding.itemIds, id: \.self) { id in
                        if let item = model.item(id) {
                            NavigationLink { BookDetailView(item: item) } label: {
                                Text(verbatim: model.title(id)).foregroundStyle(Color.shelfCream)
                            }
                        } else {
                            Text(verbatim: model.title(id)).foregroundStyle(Color.shelfCream)
                        }
                    }
                } header: { RetroSectionHeader(title: "Books") }
                .listRowBackground(Color.shelfCard)

                fixSection
                    .listRowBackground(Color.shelfCard)

                if let error = model.actionError {
                    Section { Text(verbatim: error).foregroundStyle(Color.red) }
                        .listRowBackground(Color.shelfCard)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle(Text(LibraryDoctorView.title(finding.kind)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.monochromeToolbarItem()
                }
            }
            .alert(Text("Apply This Change?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("Apply") {
                    guard let change = pending else { return }
                    pending = nil
                    Task { if await model.apply(change) { done = true } }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                if let p = pending { Text(verbatim: "\(p.title)\n\(p.before)  \u{2192}  \(p.after)") }
            }
        }
        .tint(Color.shelfAmberText)
        .systemChromeTint()
        .onAppear {
            model.actionError = nil
            sequenceText = model.proposedSequence(for: finding)
        }
    }

    @ViewBuilder
    private var fixSection: some View {
        if done {
            Section {
                Label("Fixed. The book was refreshed from the server.", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.shelfAmberText)
            }
        } else if let fix = finding.fix {
            switch fix {
            case .setCover(let itemId):
                Section {
                    if model.isSearchingCovers { ProgressView().shelfSpinner() }
                    if let note = model.coverSearchNote {
                        Typo.supporting(Text(verbatim: note)).foregroundStyle(Color.shelfMuted)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.coverCandidates, id: \.self) { url in
                                Button { pending = model.proposeCover(itemId: itemId, url: url) } label: {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: { Color.shelfCard }
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .accessibilityLabel(Text("Use this cover"))
                            }
                        }
                    }
                } header: { RetroSectionHeader(title: "Pick a Cover") }
                .task { await model.searchCovers(for: itemId) }
            case .setSequence(let itemId, let series, _):
                Section {
                    HStack {
                        Text("Number in \(series)")
                        Spacer()
                        TextField("Number", text: $sequenceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    Button("Review Change") {
                        pending = model.proposeSequence(itemId: itemId, series: series, value: sequenceText)
                    }
                    .disabled(model.proposeSequence(itemId: itemId, series: series, value: sequenceText) == nil)
                } header: { RetroSectionHeader(title: "Set the Number") }
            case .chapters(let itemId):
                Section {
                    if model.localChapters(itemId: itemId) != nil {
                        Button("Upload These Chapters to the Server") { pending = model.proposeChapters(itemId: itemId) }
                    } else {
                        Typo.supporting(Text("To fix this, open the book, go to its chapter list and use Suggest Chapters. After you accept them on this device you can send them to the server from here."))
                            .foregroundStyle(Color.shelfMuted)
                    }
                } header: { RetroSectionHeader(title: "Fix") }
            }
        }
    }
}
