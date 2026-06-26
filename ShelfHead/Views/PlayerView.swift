import SwiftUI
import AVKit

/// Wraps `AVRoutePickerView` so AirPlay/output device selection works from the player.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.4)
        picker.activeTintColor = UIColor(Color.shelfAmber)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showChapters = false
    @State private var showBookmarks = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragOffset: CGFloat = 0
    @State private var dismissing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                VStack(spacing: 0) {
                    // Drag handle
                    dragHandle
                        .padding(.top, 14)
                        .padding(.horizontal, 24)

                    // Scrollable content for small screens
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Cover Art
                            coverArtView(screenHeight: geometry.size.height)
                                .padding(.top, 16)

                            // Book Info
                            bookInfoView
                                .padding(.top, 20)

                            // Progress Slider + Times
                            progressSection
                                .padding(.top, 24)

                            // Main Controls
                            controlsView
                                .padding(.top, 20)

                            // Bottom toolbar
                            bottomToolbar
                                .padding(.top, 24)
                                .padding(.bottom, 40)
                        }
                        .padding(.horizontal, 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .offset(y: dragOffset)
            .opacity(dismissing ? 0 : 1)
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .global)
                    .onChanged { value in
                        // Only allow downward drag
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height * 0.7
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 100 || value.velocity.height > 500 {
                            // Dismiss
                            withAnimation(.easeOut(duration: 0.2)) {
                                dragOffset = geometry.size.height
                                dismissing = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                dismiss()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet()
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet()
        }
        .statusBarHidden(false)
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Color.shelfBackground
                .ignoresSafeArea()

            if let book = playerViewModel.currentBook {
                // Reuse the shared cover cache (and its auth header) instead of an
                // uncached AsyncImage that re-downloads the 600px art every present.
                CachedCover(url: coverURL(for: book.id))
                    .frame(width: 300, height: 300)
                    .blur(radius: 100)
                    .opacity(0.2)
                    .offset(y: -100)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.shelfCream.opacity(0.3))
                .frame(width: 40, height: 5)

            HStack(spacing: 6) {
                Circle()
                    .fill(playerViewModel.isPlaying ? Color.shelfOrange : Color.shelfMuted)
                    .frame(width: 6, height: 6)
                Text(playerViewModel.isResuming ? "CONTINUE LISTENING" : "NOW PLAYING")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundColor(Color.shelfAmber.opacity(0.85))
            }
        }
    }

    // MARK: - Cover Art

    private func coverArtView(screenHeight: CGFloat) -> some View {
        Group {
            if let book = playerViewModel.currentBook {
                CassetteView(coverURL: coverURL(for: book.id), spinning: playerViewModel.isPlaying)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Book Info

    private var bookInfoView: some View {
        VStack(spacing: 5) {
            Text(playerViewModel.currentBook?.title ?? "Unknown")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(Color.shelfCream)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(playerViewModel.currentBook?.authorName ?? "")
                .font(.system(size: 13))
                .foregroundColor(Color.shelfMuted)

            if let chapter = playerViewModel.currentChapter {
                Text(chapter.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.shelfAmber)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        VStack(spacing: 10) {
            WaveformScrubber(
                value: Binding(
                    get: { isDragging ? dragProgress : playerViewModel.progress },
                    set: { newValue in
                        dragProgress = newValue
                        isDragging = true
                    }
                ),
                onEditingChanged: { editing in
                    if !editing {
                        let seekTime = dragProgress * playerViewModel.duration
                        playerViewModel.seek(to: seekTime)
                        isDragging = false
                    }
                }
            )

            HStack {
                TapeCounter(text: currentTimeDisplay)
                Spacer()
                TapeCounter(text: remainingTimeDisplay)
            }
        }
    }

    private var currentTimeDisplay: String {
        let time = isDragging ? (dragProgress * playerViewModel.duration) : playerViewModel.currentTime
        return time.formattedTime
    }

    private var remainingTimeDisplay: String {
        let time = isDragging ? (dragProgress * playerViewModel.duration) : playerViewModel.currentTime
        let remaining = max(0, playerViewModel.duration - time)
        return "-\(remaining.formattedTime)"
    }

    // MARK: - Controls

    private var controlsView: some View {
        HStack(alignment: .center, spacing: 18) {
            transportButton("backward.end.fill", size: 16) {
                playerViewModel.previousChapter()
            }

            transportButton("gobackward.15", size: 22) {
                playerViewModel.skipBackward()
            }

            Button {
                playerViewModel.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.shelfAmber)
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.shelfAmber.opacity(playerViewModel.isPlaying ? 0.5 : 0), radius: 12)

                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color.shelfBackground)
                        .offset(x: playerViewModel.isPlaying ? 0 : 2)
                }
            }

            transportButton("goforward.30", size: 22) {
                playerViewModel.skipForward()
            }

            transportButton("forward.end.fill", size: 16) {
                playerViewModel.nextChapter()
            }
        }
    }

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(Color.shelfCream.opacity(0.85))
                .frame(width: 46, height: 46)
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "speedometer", label: speedLabel, active: playerViewModel.playbackRate != 1.0) {
                showSpeedPicker = true
            }
            .confirmationDialog("Playback Speed", isPresented: $showSpeedPicker) {
                ForEach(PlaybackSpeed.allCases, id: \.rawValue) { speed in
                    Button(speed.label) { playerViewModel.setPlaybackSpeed(speed) }
                }
            }

            toolbarButton(icon: "moon.zzz.fill", label: sleepTimerText, active: playerViewModel.sleepTimerOption != .off) {
                showSleepTimer = true
            }
            .confirmationDialog("Sleep Timer", isPresented: $showSleepTimer) {
                ForEach(SleepTimerOption.presets, id: \.label) { option in
                    Button(option.label) { playerViewModel.setSleepTimer(option) }
                }
            }

            toolbarButton(icon: "list.bullet", label: "Chapters", active: false) {
                showChapters = true
            }

            toolbarButton(icon: "bookmark.fill", label: "Marks", active: false) {
                showBookmarks = true
            }

            VStack(spacing: 3) {
                RoutePickerView()
                    .frame(width: 24, height: 24)
                Text("AirPlay")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.shelfCream.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.shelfCream.opacity(0.08), lineWidth: 1))
    }

    private func toolbarButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(active ? Color.shelfAmber : Color.shelfCream.opacity(0.45))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private var speedLabel: String {
        PlaybackSpeed(rawValue: Double(playerViewModel.playbackRate))?.label ?? "\(playerViewModel.playbackRate)×"
    }

    private var sleepTimerText: String {
        if playerViewModel.sleepTimerRemaining > 0 {
            let mins = Int(playerViewModel.sleepTimerRemaining) / 60
            if mins > 0 { return "\(mins)m" }
            return "\(Int(playerViewModel.sleepTimerRemaining))s"
        }
        return playerViewModel.sleepTimerOption != .off ? playerViewModel.sleepTimerOption.label : "Sleep"
    }

    private func coverURL(for itemId: String) -> URL? {
        // Clean URL (no token); CachedCover/CassetteView attach the auth header and
        // prefer a locally-cached cover when the book is downloaded.
        shelfCoverURL(itemId: itemId, width: 600)
    }
}

// MARK: - Custom Slider

struct CustomSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void
    @State private var isEditing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 5)

                Capsule()
                    .fill(Color.shelfAmber)
                    .frame(width: max(0, geo.size.width * value), height: 5)

                Circle()
                    .fill(Color.white)
                    .frame(width: isEditing ? 16 : 12, height: isEditing ? 16 : 12)
                    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                    .offset(x: max(0, geo.size.width * value - (isEditing ? 8 : 6)))
                    .animation(.easeOut(duration: 0.1), value: isEditing)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        value = min(max(0, drag.location.x / geo.size.width), 1)
                    }
                    .onEnded { _ in
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
    }
}

// MARK: - Chapter List Sheet

struct ChapterListSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(playerViewModel.chapters) { chapter in
                                Button {
                                    playerViewModel.seekToChapter(chapter)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        if isCurrentChapter(chapter) {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .foregroundColor(Color.shelfAmber)
                                                .font(.caption)
                                                .frame(width: 20)
                                        } else {
                                            Text("\(chapter.id + 1)")
                                                .font(.caption2.weight(.medium))
                                                .foregroundColor(Color.shelfMuted)
                                                .frame(width: 20)
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(chapter.title)
                                                .font(.subheadline)
                                                .foregroundColor(isCurrentChapter(chapter) ? Color.shelfAmber : .white)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)

                                            Text((chapter.end - chapter.start).formattedDuration)
                                                .font(.caption2)
                                                .foregroundColor(Color.shelfMuted)
                                        }

                                        Spacer()

                                        Text(chapter.start.formattedTime)
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(Color.shelfMuted)
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .background(isCurrentChapter(chapter) ? Color.shelfAmber.opacity(0.06) : Color.clear)
                                }
                                .id(chapter.id)

                                Divider()
                                    .background(Color.shelfSurface)
                                    .padding(.leading, 48)
                            }
                        }
                    }
                    .onAppear {
                        if let current = playerViewModel.currentChapter {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.shelfAmber)
                }
            }
        }
    }

    private func isCurrentChapter(_ chapter: Chapter) -> Bool {
        playerViewModel.currentChapter?.id == chapter.id
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksSheet: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shelfBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Button {
                        isAdding = true
                        Task {
                            await playerViewModel.addBookmarkAtCurrentTime()
                            isAdding = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "bookmark.fill")
                            Text("Bookmark this moment · \(playerViewModel.currentTime.formattedTime)")
                                .fontWeight(.semibold)
                            if isAdding { Spacer(); ProgressView().tint(Color.shelfBackground) }
                        }
                        .shelfButtonStyle()
                    }
                    .disabled(isAdding)
                    .padding(16)

                    if playerViewModel.bookmarks.isEmpty {
                        EmptyStateView(icon: "bookmark", title: "No bookmarks", subtitle: "Saved moments will appear here")
                    } else {
                        List {
                            ForEach(playerViewModel.bookmarks) { bookmark in
                                Button {
                                    playerViewModel.seekToBookmark(bookmark)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "bookmark.fill")
                                            .foregroundColor(Color.shelfAmber)
                                            .font(.caption)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bookmark.title)
                                                .font(.subheadline)
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            Text(bookmark.time.formattedTime)
                                                .font(.caption.monospacedDigit())
                                                .foregroundColor(Color.shelfMuted)
                                        }
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Color.shelfCard)
                            }
                            .onDelete { indexSet in
                                let marks = indexSet.map { playerViewModel.bookmarks[$0] }
                                Task { for m in marks { await playerViewModel.deleteBookmark(m) } }
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Color.shelfAmber)
                }
            }
            .task { await playerViewModel.loadBookmarks() }
        }
    }
}

#Preview {
    PlayerView()
        .environment(PlayerViewModel())
}
