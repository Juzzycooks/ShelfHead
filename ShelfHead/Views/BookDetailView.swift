import SwiftUI

struct BookDetailView: View {
    let item: LibraryItem
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var detailedItem: LibraryItem?
    @State private var showChapters = false
    @State private var isLoading = true
    @State private var downloadManager = DownloadManager.shared
    @State private var strippedDescription = ""   // HTML stripped once, off the render path

    private var displayItem: LibraryItem {
        detailedItem ?? item
    }

    /// Prefer the shared progress map (kept current across the app), falling back to
    /// whatever progress the item itself carries.
    private var resolvedProgress: Double {
        libraryViewModel.progressFor(itemId: displayItem.id)?.progress ?? displayItem.progressPercent
    }

    private var resolvedFinished: Bool {
        libraryViewModel.progressFor(itemId: displayItem.id)?.isFinished ?? displayItem.isFinished
    }

    var body: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Cover Art & Info Header
                    headerSection

                    // Action Buttons
                    actionButtons

                    // Download status
                    downloadSection

                    // Details
                    detailsSection

                    // Chapters
                    if !displayItem.chapters.isEmpty {
                        chaptersSection
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if resolvedFinished {
                        Button {
                            runProgressAction { await libraryViewModel.markUnfinished(item: displayItem) }
                        } label: {
                            Label("Mark as Not Finished", systemImage: "circle")
                        }
                    } else {
                        Button {
                            runProgressAction { await libraryViewModel.markFinished(item: displayItem) }
                        } label: {
                            Label("Mark as Finished", systemImage: "checkmark.circle")
                        }
                    }

                    if resolvedProgress > 0 || resolvedFinished {
                        Button(role: .destructive) {
                            runProgressAction { await libraryViewModel.resetProgress(item: displayItem) }
                        } label: {
                            Label("Reset Progress", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Color.shelfAmber)
                }
            }
        }
        .task {
            // Strip the description's HTML once here, not in body — NSAttributedString
            // HTML parsing is expensive and was running on every re-render.
            strippedDescription = (item.description ?? "").strippingHTML
            if let detailed = await libraryViewModel.getItemDetail(itemId: item.id) {
                detailedItem = detailed
                if let d = detailed.description, !d.isEmpty {
                    strippedDescription = d.strippingHTML
                }
            }
            isLoading = false
        }
    }

    /// Runs a progress mutation, then refreshes the detail so the UI reflects it.
    private func runProgressAction(_ action: @escaping () async -> Bool) {
        Task {
            _ = await action()
            if let refreshed = await libraryViewModel.getItemDetail(itemId: item.id) {
                detailedItem = refreshed
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            CoverImageView(itemId: displayItem.id, width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)

            VStack(spacing: 8) {
                Text(displayItem.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(displayItem.authorName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Color.shelfAmber)

                if let narrator = displayItem.narratorName {
                    Text("Narrated by \(narrator)")
                        .font(.caption)
                        .foregroundColor(Color.shelfMuted)
                }

                if let series = displayItem.seriesName {
                    Text(series)
                        .font(.caption.weight(.medium))
                        .foregroundColor(Color.shelfAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.shelfAccent.opacity(0.12))
                        .clipShape(Capsule())
                }

                HStack(spacing: 16) {
                    if displayItem.duration > 0 {
                        Label(displayItem.duration.formattedDuration, systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(Color.shelfMuted)
                    }

                    if !displayItem.chapters.isEmpty {
                        Label("\(displayItem.chapters.count) chapters", systemImage: "list.bullet")
                            .font(.caption)
                            .foregroundColor(Color.shelfMuted)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Play button
            Button {
                Task {
                    await playerViewModel.startPlayback(for: displayItem)
                }
            } label: {
                HStack(spacing: 8) {
                    if playerViewModel.isLoadingSession {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                        Text(playButtonText)
                            .fontWeight(.semibold)
                    }
                }
                .shelfButtonStyle()
            }
            .disabled(playerViewModel.isLoadingSession)

            // Progress indicator
            if resolvedProgress > 0 && !resolvedFinished {
                HStack(spacing: 8) {
                    BookProgressBar(progress: resolvedProgress)
                    Text("\(Int(resolvedProgress * 100))% complete")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Color.shelfAmber)
                }
            }

            if resolvedFinished {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Finished")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)
                }
            }
        }
    }

    private var playButtonText: String {
        if resolvedFinished {
            return "Listen Again"
        } else if resolvedProgress > 0 {
            return "Continue Listening"
        }
        return "Start Listening"
    }

    // MARK: - Download Section

    private var downloadSection: some View {
        Group {
            if downloadManager.isDownloaded(itemId: displayItem.id) {
                // Already downloaded
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.green)
                    Text("Downloaded — Available Offline")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)

                    Spacer()

                    Button {
                        downloadManager.removeDownload(itemId: displayItem.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(Color.shelfMuted)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if downloadManager.isDownloading(itemId: displayItem.id) {
                // Downloading — show progress bar
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(Color.shelfAmber)
                            .font(.system(size: 14))
                        Text("Downloading...")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Color.shelfAmber)

                        Spacer()

                        if let task = downloadManager.activeDownloads[displayItem.id] {
                            Text("\(Int(task.progress * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.shelfAmber)
                        }

                        Button {
                            downloadManager.cancelDownload(itemId: displayItem.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color.shelfMuted)
                        }
                    }

                    // Full-width progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 6)

                            Capsule()
                                .fill(Color.shelfAmber)
                                .frame(
                                    width: geo.size.width * (downloadManager.activeDownloads[displayItem.id]?.progress ?? 0),
                                    height: 6
                                )
                                .animation(.linear(duration: 0.3), value: downloadManager.activeDownloads[displayItem.id]?.progress)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(12)
                .background(Color.shelfCard)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Not downloaded — show download button
                Button {
                    downloadManager.downloadBook(displayItem)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download for Offline")
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    .foregroundColor(Color.shelfAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.shelfAmber.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.shelfAmber.opacity(0.3), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !strippedDescription.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(strippedDescription)
                        .font(.subheadline)
                        .foregroundColor(Color.shelfMuted)
                        .lineLimit(nil)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shelfCardStyle()
            }

            // Metadata grid
            let metadata = buildMetadata()
            if !metadata.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details")
                        .font(.headline)
                        .foregroundColor(.white)

                    ForEach(metadata, id: \.0) { label, value in
                        HStack {
                            Text(label)
                                .font(.caption)
                                .foregroundColor(Color.shelfMuted)
                                .frame(width: 80, alignment: .leading)
                            Text(value)
                                .font(.caption)
                                .foregroundColor(.white)
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shelfCardStyle()
            }
        }
    }

    private func buildMetadata() -> [(String, String)] {
        var metadata: [(String, String)] = []
        if let year = displayItem.media?.metadata?.publishedYear, !year.isEmpty {
            metadata.append(("Year", year))
        }
        if let publisher = displayItem.media?.metadata?.publisher, !publisher.isEmpty {
            metadata.append(("Publisher", publisher))
        }
        if let genres = displayItem.media?.metadata?.genres, !genres.isEmpty {
            metadata.append(("Genres", genres.joined(separator: ", ")))
        }
        if let language = displayItem.media?.metadata?.language, !language.isEmpty {
            metadata.append(("Language", language.capitalized))
        }
        return metadata
    }

    // MARK: - Chapters Section

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { showChapters.toggle() }
            } label: {
                HStack {
                    Text("Chapters (\(displayItem.chapters.count))")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Image(systemName: showChapters ? "chevron.up" : "chevron.down")
                        .foregroundColor(Color.shelfMuted)
                        .font(.caption)
                }
            }

            if showChapters {
                LazyVStack(spacing: 0) {
                    ForEach(displayItem.chapters) { chapter in
                        ChapterRow(chapter: chapter) {
                            Task {
                                await playerViewModel.startPlayback(for: displayItem)
                                playerViewModel.seekToChapter(chapter)
                            }
                        }
                        if chapter.id != displayItem.chapters.last?.id {
                            Divider()
                                .background(Color.shelfSurface)
                        }
                    }
                }
            }
        }
        .padding(16)
        .shelfCardStyle()
    }
}

// MARK: - Chapter Row

struct ChapterRow: View {
    let chapter: Chapter
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text((chapter.end - chapter.start).formattedDuration)
                        .font(.caption2)
                        .foregroundColor(Color.shelfMuted)
                }

                Spacer()

                Text(chapter.start.formattedTime)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color.shelfMuted)
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - String HTML Stripping

extension String {
    var strippingHTML: String {
        guard let data = self.data(using: .utf8) else { return self }
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return self }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    NavigationStack {
        BookDetailView(item: LibraryItem(
            id: "test",
            ino: nil,
            libraryId: nil,
            mediaType: "book",
            media: nil,
            numFiles: nil,
            size: nil,
            addedAt: nil,
            updatedAt: nil,
            mediaProgress: nil
        ))
    }
    .environment(PlayerViewModel())
    .environment(LibraryViewModel())
}
