import SwiftUI
import UIKit

/// Batch 462: "Make a Video" for Year in Review. A live, scaled-down preview of the reel (a
/// `TimelineView` drives `YearInReviewReel`; a still frame under Reduce Motion or while
/// exporting), an "Add music" toggle (off by default: the pad is only written into the file,
/// and only if asked for), Make Video with progress and Cancel, then a share sheet (`ActivityView`) for the MP4.
/// The temp file is deleted when the sheet goes away.
struct YearInReviewVideoSheet: View {
    @State var data: YearInReviewReelData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var exporter = YearInReviewVideoExporter()
    @State private var exportTask: Task<Void, Never>?
    @State private var includeMusic = false
    @State private var outputURL: URL?
    @State private var showingShareSheet = false
    @State private var failed = false
    @State private var previewStart = Date()

    /// A frame where the title scene is fully drawn, for Reduce Motion and while exporting.
    private static let stillTime: Double = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.l) {
                    preview
                    controls
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
            }
            .background(Color.shelfBackground.ignoresSafeArea())
            .navigationTitle("Make a Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Batch 490 (REVIEW 2026-11-11 V1): the system close button (✕ on iOS 26+), not
                // text "Done". Disabled while exporting, like the swipe-down below: the export's
                // own Cancel stops it first.
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .monochromeToolbarItem()
                        .disabled(exporter.isExporting)
                }
                .shelfVisibilityPriority(.high)
            }
        }
        .task { await loadCovers() }
        .onDisappear {
            exportTask?.cancel()
            removeOutput()
        }
        .interactiveDismissDisabled(exporter.isExporting)
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geo in
            let scale = geo.size.width / YearInReviewReel.size.width
            Group {
                if reduceMotion || exporter.isExporting {
                    YearInReviewReel(data: data, time: Self.stillTime)
                } else {
                    TimelineView(.animation) { context in
                        let elapsed = context.date.timeIntervalSince(previewStart)
                        YearInReviewReel(data: data, time: elapsed.truncatingRemainder(dividingBy: ReelTimeline.duration))
                    }
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .aspectRatio(YearInReviewReel.size.width / YearInReviewReel.size.height, contentMode: .fit)
        .frame(maxWidth: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of your \(String(data.year)) video")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if let outputURL {
            // Batch 464: a share sheet without SharePlay (`ActivityView`), not `ShareLink`.
            // Batch 490 (REVIEW 2026-11-11 V2): the primary style (Amber Ink on the accent), not
            // `.borderedProminent`, which drew white on amber at about 2:1.
            Button { showingShareSheet = true } label: {
                Label("Share Video", systemImage: "square.and.arrow.up")
                    .shelfButtonStyle()
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingShareSheet) { ActivityView(items: [outputURL]) }
            Button("Make Again") { removeOutput() }
                .frame(minHeight: 44)
        } else if exporter.isExporting {
            VStack(spacing: Space.m) {
                ProgressView(value: exporter.progress)
                    .tint(Color.shelfAmber)
                Typo.metadata(Text("Making your video… \(Int(exporter.progress * 100))%"))
                    .foregroundStyle(Color.shelfMuted)
                Button("Cancel", role: .cancel) { exportTask?.cancel() }
                    .frame(minHeight: 44)
            }
        } else {
            Toggle("Add music", isOn: $includeMusic)
                .tint(Color.shelfAmber)
            Typo.metadata(Text("A soft synthesised backing track, written into the video file. Off unless you turn it on."))
                .foregroundStyle(Color.shelfMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                startExport()
            } label: {
                // Batch 490 (REVIEW 2026-11-11 V2): the one primary, Amber Ink on the accent.
                Label("Make Video", systemImage: "film")
                    .shelfButtonStyle()
            }
            .buttonStyle(.plain)
            if failed {
                Typo.metadata(Text("The video couldn\u{2019}t be made. Try again."))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
    }

    // MARK: Actions

    private func startExport() {
        failed = false
        let snapshot = data
        let music = includeMusic
        exportTask = Task {
            do {
                let url = try await exporter.export(data: snapshot, includeMusic: music)
                outputURL = url
            } catch is CancellationError {
                // Cancelled: the exporter already cleaned up.
            } catch {
                failed = true
            }
        }
    }

    private func removeOutput() {
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    /// Covers for the top books, through the same loader the share cards use.
    private func loadCovers() async {
        for book in data.topBooks.prefix(3) where data.covers[book.id] == nil {
            if Task.isCancelled { return }
            if let image = await ShareCardRenderer.loadCover(itemId: book.id) {
                data.covers[book.id] = image
            }
        }
    }
}
