import SwiftUI

struct DownloadsView: View {
    @State private var downloadManager = DownloadManager.shared
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var showRemoveAllConfirmation = false

    var body: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            if downloadManager.downloadedItems.isEmpty && downloadManager.activeDownloads.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No Downloads",
                    subtitle: "Downloaded books will appear here for offline listening"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Active downloads
                        if !downloadManager.activeDownloads.isEmpty {
                            Section {
                                ForEach(Array(downloadManager.activeDownloads.values)) { task in
                                    ActiveDownloadRow(task: task) {
                                        downloadManager.cancelDownload(itemId: task.id)
                                    }
                                }
                            } header: {
                                Text("Downloading")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                            }
                        }

                        // Completed downloads
                        if !downloadManager.downloadedItems.isEmpty {
                            Section {
                                ForEach(downloadManager.downloadedLibraryItems()) { item in
                                    NavigationLink {
                                        BookDetailView(item: item)
                                    } label: {
                                        DownloadedItemRow(itemId: item.id) {
                                            downloadManager.removeDownload(itemId: item.id)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Text("Available Offline")
                                        .font(.headline)
                                        .foregroundColor(.white)

                                    Spacer()

                                    Text("\(downloadManager.downloadedItems.count) books · \(downloadManager.formattedStorageUsed())")
                                        .font(.caption)
                                        .foregroundColor(Color.shelfMuted)
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !downloadManager.downloadedItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showRemoveAllConfirmation = true
                    } label: {
                        Text("Remove All")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $showRemoveAllConfirmation, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                downloadManager.removeAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(downloadManager.formattedStorageUsed()). Books stay in your library and can be re-downloaded.")
        }
    }
}

// MARK: - Active Download Row

struct ActiveDownloadRow: View {
    let task: DownloadTask
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                CoverImageView(itemId: task.id, width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("Downloading...")
                        .font(.caption)
                        .foregroundColor(Color.shelfMuted)
                }

                Spacer()

                Text("\(Int(task.progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.shelfAmber)

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
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
                        .frame(width: geo.size.width * task.progress, height: 6)
                        .animation(.linear(duration: 0.3), value: task.progress)
                }
            }
            .frame(height: 6)
        }
        .padding(14)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }
}

// MARK: - Downloaded Item Row

struct DownloadedItemRow: View {
    let itemId: String
    let onRemove: () -> Void

    private var manifest: DownloadedBook? {
        DownloadManager.shared.manifest(for: itemId)
    }

    private var progress: Double {
        guard let m = manifest, m.duration > 0 else { return 0 }
        return min(m.currentTime / m.duration, 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(itemId: itemId, width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(manifest?.title ?? "Downloaded Book")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(manifest?.author ?? "Available offline")
                    .font(.caption)
                    .foregroundColor(Color.shelfMuted)
                    .lineLimit(1)

                if progress > 0.001 {
                    BookProgressBar(progress: progress)
                        .frame(maxWidth: 160)
                    Text("\(Int(progress * 100))% · saved offline")
                        .font(.caption2)
                        .foregroundColor(Color.shelfMuted)
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(Color.shelfMuted)
            }
            .buttonStyle(.borderless)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color.shelfMuted)
        }
        .padding(12)
        .padding(.horizontal, 8)
        .background(Color.shelfCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .environment(LibraryViewModel())
}
