import SwiftUI

/// "Recently Added" — mirrors the iPhone's Home shelf of the same name (server's
/// `LabelRecentlyAdded` personalized-view shelf), capped to a small count by the phone
/// side (`WatchSessionManager.recentlyAddedCap`) to keep this a lightweight companion
/// list rather than a full library browser. Tapping a row asks the phone to start
/// playing that book.
struct RecentlyAddedView: View {
    @Environment(WatchConnectivityStore.self) private var store
    // Stage 3 (addendum §10.2): read only to decide standalone-vs-companion tap
    // behavior below — this view's actual list data still comes entirely from
    // `store` (`WatchConnectivityStore`) above, unchanged. Already injected at the
    // app root (`ShelfHeadWatchApp.swift`) alongside `store`, so this is an additive
    // read, not a re-point of this screen onto the facade.
    @Environment(WatchStore.self) private var watchStore
    @State private var pendingPlay: WatchPlayRequest?

    var body: some View {
        Group {
            if store.recentlyAdded.isEmpty {
                WatchOpenOniPhoneEmptyState(systemImage: "book.fill", message: "Open ShelfHead on iPhone to sync recently added titles")
            } else {
                List(store.recentlyAdded) { book in
                    if watchStore.mode == .standalone {
                        NavigationLink {
                            StandaloneNowPlayingView(itemId: book.id, title: book.title, author: book.author, coverData: book.coverData)
                        } label: {
                            BookSummaryRow(book: book)
                        }
                    } else {
                        Button {
                            store.requestPlay(itemId: book.id, title: book.title, pending: $pendingPlay)
                        } label: {
                            BookSummaryRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Batch 412: default list style (no `.carousel` on Library screens).
            }
        }
        .navigationTitle("Recently Added")
        .confirmsPlayReplacement($pendingPlay)
    }
}

/// A companion-mode play tap waiting on the "this replaces what's playing" confirmation.
struct WatchPlayRequest: Equatable {
    let itemId: String
    let title: String
    let currentTitle: String
}

extension WatchConnectivityStore {
    /// Plays `itemId` now, or parks a request in `pending` when it would replace a different
    /// book that is playing (see `WatchPlayRequestDecision`).
    func requestPlay(itemId: String, title: String, pending: Binding<WatchPlayRequest?>) {
        switch WatchPlayRequestDecision.decide(requestedItemId: itemId, current: playbackState) {
        case .playNow:
            playItem(itemId: itemId)
        case .confirmReplacing(let currentTitle):
            pending.wrappedValue = WatchPlayRequest(itemId: itemId, title: title, currentTitle: currentTitle)
        }
    }
}

private struct PlayReplacementConfirmation: ViewModifier {
    @Environment(WatchConnectivityStore.self) private var store
    @Binding var pending: WatchPlayRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending.map { String(localized: "Play \u{201C}\($0.title)\u{201D}?") } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Play") {
                if let request = pending { store.playItem(itemId: request.itemId) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let request = pending {
                // Critique 2026-10-06 (polish): same shape as standalone's "stops on this Watch".
                Text("\u{201C}\(request.currentTitle)\u{201D} stops on your iPhone.")
            }
        }
    }
}

extension View {
    func confirmsPlayReplacement(_ pending: Binding<WatchPlayRequest?>) -> some View {
        modifier(PlayReplacementConfirmation(pending: pending))
    }
}

/// Shared row layout for a `WatchBookSummary` — used by Recently Added and by a
/// collection's book list.
struct BookSummaryRow: View {
    let book: WatchBookSummary

    // Batch 412 (Watch redesign): the shared `WatchBookRow` (40pt cover, two-line title,
    // Finished badge at >= 99%, progress bar otherwise).
    var body: some View {
        WatchBookRow(title: book.title, author: book.author, progress: book.progress,
                     cover: { CoverThumbnail(data: book.coverData, side: 40) })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(book.title) by \(book.author)")
    }
}

#Preview {
    NavigationStack { RecentlyAddedView() }
        .environment(WatchConnectivityStore.shared)
}
