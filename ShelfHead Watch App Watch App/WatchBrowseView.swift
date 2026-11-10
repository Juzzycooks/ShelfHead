import SwiftUI

/// Batch 412 (Watch redesign): the real Library screen the Shelf's toolbar button pushes
/// ("Library: a pushed List with search, an 'In Progress' section, then items"). With a
/// session on this Watch it is `StandaloneLibraryView` (switcher, search, In Progress,
/// paged items); without one it is a short list that explains setup. Companion-mirror
/// shortcuts (`WatchFromiPhoneSection`) follow `WatchRootTiles` availability and show
/// only when they can open. Downloads is the toolbar button, in every state.
struct WatchBrowseView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        Group {
            if store.authState == .active {
                StandaloneLibraryView()
            } else {
                setupList
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    StandaloneDownloadsView()
                } label: {
                    // Same styling as the Shelf's toolbar glyphs: the app-wide accent tint
                    // would otherwise fill the button solid amber and hide the glyph.
                    Image(systemName: "arrow.down.circle")
                        .font(WatchMetrics.rowIconFont())
                        .foregroundStyle(WatchTheme.icon)
                }
                .tint(WatchTheme.cardBackground)
                .accessibilityLabel("Downloads")
            }
        }
    }

    private var setupList: some View {
        List {
            WatchFromiPhoneSection()
            Section {
                NavigationLink {
                    WatchAccountView()
                } label: {
                    WatchRow(systemImage: "applewatch", title: "Set Up to Browse All Books")
                }
            } footer: {
                Text("Sign in on this Watch to search your whole library and download books.")
                    .font(WatchMetrics.captionFont())
                    .foregroundStyle(WatchTheme.secondaryText)
            }
        }
        .navigationTitle("Library")
    }
}

/// Recently Added and Collections, the iPhone's mirrored shelves, as two compact rows.
/// Availability is `WatchRootTiles`' (Recently Added in standalone only with a non-empty
/// mirror; Collections in companion only); a row that can't open is left out, not dimmed.
/// Renders nothing (no empty section) when neither is available.
struct WatchFromiPhoneSection: View {
    @Environment(WatchStore.self) private var store

    private func isAvailable(_ destination: WatchRootDestination) -> Bool {
        WatchRootTiles.state(
            for: destination,
            mode: store.mode,
            hasWatchSession: store.authState == .active,
            hasMirroredRecentlyAdded: !store.recentlyAdded.isEmpty).isAvailable
    }

    var body: some View {
        let showRecent = isAvailable(.recentlyAdded)
        let showCollections = isAvailable(.collections)
        if showRecent || showCollections {
            Section("From iPhone") {
                if showRecent {
                    NavigationLink {
                        RecentlyAddedView()
                    } label: {
                        WatchRow(systemImage: "sparkles", title: "Recently Added",
                                 subtitle: store.recentlyAdded.isEmpty ? nil : "\(store.recentlyAdded.count) books")
                    }
                }
                if showCollections {
                    NavigationLink {
                        WatchCollectionsView()
                    } label: {
                        WatchRow(systemImage: "folder", title: "Collections",
                                 subtitle: store.collections.isEmpty ? nil : "\(store.collections.count) collections")
                    }
                }
            }
        }
    }
}
