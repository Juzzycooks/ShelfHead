import SwiftUI

struct HomeView: View {
    /// Incremented by the parent when the Home tab is re-tapped; changing it rebuilds
    /// the NavigationStack (pops to root).
    var resetToken: Int = 0
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(PlayerViewModel.self) private var playerViewModel

    var body: some View {
        @Bindable var libraryViewModel = libraryViewModel
        return NavigationStack {
            ZStack {
                Color.shelfBackground
                    .ignoresSafeArea()

                if libraryViewModel.isLoadingPersonalized && libraryViewModel.personalizedShelves.isEmpty {
                    LoadingView("Loading your library...")
                } else if libraryViewModel.personalizedShelves.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "Nothing here yet",
                        subtitle: "Your personalized shelves will appear once you start listening"
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Greeting
                            headerView

                            // Render shelves with different layouts
                            ForEach(libraryViewModel.personalizedShelves) { shelf in
                                if let entities = shelf.entities, !entities.isEmpty, shelf.isBookShelf {
                                    if shelf.labelStringKey == "LabelContinueListening" {
                                        ContinueListeningSection(items: entities)
                                    } else {
                                        CompactShelfRow(title: shelf.label, items: entities)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "headphones.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color.shelfAmber)
                        Text("ShelfHead")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(Color.shelfAmber)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if libraryViewModel.libraries.count > 1 {
                        Menu {
                            ForEach(libraryViewModel.libraries) { library in
                                Button {
                                    Task { await libraryViewModel.selectLibrary(library) }
                                } label: {
                                    HStack {
                                        Text(library.name)
                                        if library.id == libraryViewModel.selectedLibrary?.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "square.stack.fill")
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
            }
            .refreshable {
                await libraryViewModel.refresh()
            }
            .task {
                if libraryViewModel.libraries.isEmpty {
                    await libraryViewModel.loadLibraries()
                }
            }
            .errorAlert(message: $libraryViewModel.errorMessage) {
                Task {
                    if libraryViewModel.libraries.isEmpty {
                        await libraryViewModel.loadLibraries()
                    } else {
                        await libraryViewModel.refresh()
                    }
                }
            }
        }
        .id(resetToken)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greetingText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(Color.shelfCream)

            Text("Pick up where you left off")
                .font(.system(size: 13))
                .foregroundColor(Color.shelfMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default: return "Night owl mode"
        }
    }
}

// MARK: - Continue Listening (Wide Cards with Progress)

struct ContinueListeningSection: View {
    let items: [LibraryItem]
    @Environment(LibraryViewModel.self) private var libraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RetroSectionHeader(title: "Continue Listening")
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        ContinueListeningCard(
                            item: item,
                            serverProgress: libraryViewModel.progressFor(itemId: item.id)
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct ContinueListeningCard: View {
    let item: LibraryItem
    let serverProgress: MediaProgress?
    @Environment(PlayerViewModel.self) private var playerViewModel

    private var progressValue: Double {
        serverProgress?.progress ?? item.progressPercent
    }

    private var currentTimeValue: Double {
        serverProgress?.currentTime ?? item.currentTime
    }

    private var durationValue: Double {
        serverProgress?.duration ?? item.duration
    }

    var body: some View {
        NavigationLink(destination: BookDetailView(item: item)) {
            HStack(spacing: 12) {
                // Cover
                CoverImageView(itemId: item.id, width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Info + Progress
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(item.authorName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    // Progress bar + percentage
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(Color.shelfAmber)
                                    .frame(width: geo.size.width * min(progressValue, 1.0), height: 4)
                            }
                        }
                        .frame(height: 4)

                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.shelfAmber)
                            .frame(width: 32, alignment: .trailing)
                    }

                    // Time remaining
                    if durationValue > 0 {
                        let remaining = durationValue - currentTimeValue
                        Text("\(remaining.formattedDuration) remaining")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                // Play button
                Button {
                    Task {
                        await playerViewModel.startPlayback(for: item)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "0F0F1A"))
                        .frame(width: 32, height: 32)
                        .background(Color.shelfAmber)
                        .clipShape(Circle())
                }
            }
            .padding(12)
            .frame(width: 290)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Shelf Row (for other sections)

struct CompactShelfRow: View {
    let title: String
    let items: [LibraryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RetroSectionHeader(title: title)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(destination: BookDetailView(item: item)) {
                            CassetteTile(
                                coverURL: shelfCoverURL(itemId: item.id),
                                title: item.title,
                                subtitle: item.authorName
                            )
                            .frame(width: 128)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

#Preview {
    HomeView(resetToken: 0)
        .environment(LibraryViewModel())
        .environment(PlayerViewModel())
}
