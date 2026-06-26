import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    @State private var showFullPlayer = false
    @State private var appeared = false
    @State private var bounceOffset: CGFloat = 60

    var body: some View {
        if playerViewModel.currentBook != nil {
            Button {
                showFullPlayer = true
            } label: {
                miniPlayerContent
            }
            .buttonStyle(.plain)
            .offset(y: bounceOffset)
            .onAppear {
                if !appeared {
                    appeared = true
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0)) {
                        bounceOffset = 0
                    }
                }
            }
            .onChange(of: playerViewModel.currentBook?.id) { _, _ in
                // Bounce when a new book starts
                bounceOffset = 30
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                    bounceOffset = 0
                }
            }
            .sheet(isPresented: $showFullPlayer) {
                PlayerView()
                    .presentationDragIndicator(.hidden)
                    .presentationDetents([.large])
                    .presentationBackground(Color(hex: "0F0F1A"))
                    .interactiveDismissDisabled(false)
            }
        }
    }

    private var miniPlayerContent: some View {
        VStack(spacing: 0) {
            // Progress line
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.shelfCream.opacity(0.08))
                    Rectangle()
                        .fill(Color.shelfAmber)
                        .frame(width: geometry.size.width * playerViewModel.progress)
                        .animation(.linear(duration: 0.5), value: playerViewModel.progress)
                }
            }
            .frame(height: 3)

            HStack(spacing: 12) {
                // Cover with a little spinning reel overlay for the tape-deck feel
                if let book = playerViewModel.currentBook {
                    ZStack(alignment: .bottomTrailing) {
                        CoverImageView(itemId: book.id, width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        CassetteReel(spinning: playerViewModel.isPlaying, size: 16)
                            .padding(2)
                    }
                }

                // Title & chapter/author
                VStack(alignment: .leading, spacing: 2) {
                    Text(playerViewModel.currentBook?.title ?? "")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.shelfCream)
                        .lineLimit(1)

                    if let chapter = playerViewModel.currentChapter {
                        Text(chapter.title)
                            .font(.system(size: 11))
                            .foregroundColor(Color.shelfMuted)
                            .lineLimit(1)
                    } else {
                        Text(playerViewModel.currentBook?.authorName ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(Color.shelfMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Play/Pause
                Button {
                    playerViewModel.togglePlayPause()
                } label: {
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.shelfBackground)
                        .frame(width: 36, height: 36)
                        .background(Color.shelfAmber)
                        .clipShape(Circle())
                }

                Button {
                    playerViewModel.skipForward()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 14))
                        .foregroundColor(Color.shelfCream.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.shelfCard.opacity(0.3)
            }
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: -4)
        }
        .overlay(alignment: .top, content: { Rectangle().fill(Color.shelfCream.opacity(0.08)).frame(height: 1) })
    }
}

#Preview {
    VStack {
        Spacer()
        MiniPlayerView()
    }
    .background(Color.shelfBackground)
    .environment(PlayerViewModel())
}
