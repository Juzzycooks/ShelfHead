import SwiftUI

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`. Structural only —
/// everything below is verbatim what lived on `PlayerView` itself.
///
/// This file is the title/author/chapter block under the artwork, plus the separately
/// observed chapter caption that block renders (see `PlayerChapterCaption`'s own doc
/// comment for why the caption is its own view rather than a few lines inline).
extension PlayerView {
    // MARK: - Book Info

    var bookInfoView: some View {
        VStack(spacing: 5) {
            // 16 September 2026 (user request): the title is a button into Book Detail.
            // Critique 2026-10-06 (clarify): it used to close the player and open Book Detail
            // through the deep-link route, while "Book Details" in the ••• menu opened a sheet
            // over the player: two behaviours for one destination. Both now open the sheet
            // (`showBookDetails`), so the player is still there when it's closed.
            Button {
                guard playerViewModel.currentBook != nil else { return }
                Haptics.selection()
                showBookDetails = true
            } label: {
                Text(playerViewModel.currentBook?.title ?? String(localized: "Unknown", comment: "Fallback title when no book is loaded in the player"))
                    // @ScaledMetric sizes grow with the user's text-size setting so the
                    // primary reading text honors Dynamic Type (title can wrap to 2 lines).
                    .font(.system(size: npTitleSizeCapped, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shelfCream)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .disabled(playerViewModel.currentBook == nil)
            .accessibilityHint("Opens the book's details")

            Typo.metadata(Text(playerViewModel.currentBook?.authorName ?? ""))
                .foregroundStyle(Color.shelfMuted)

            // Item 10 (REVIEW-2026-09-09.md): the caption is its own view now.
            // Deciding whether to show it at all means reading `currentChapter`, which
            // reads `currentTime` — inlined here that made the book title and author
            // above it re-render at playback-tick frequency along with it.
            PlayerChapterCaption {
                Haptics.selection()
                showChapters = true
            }
        }
    }
}

/// The tappable "current chapter" caption under the book title on the full player.
///
/// Item 10 (REVIEW-2026-09-09.md): extracted from `PlayerView.bookInfoView` — the same
/// pattern `StatsView`'s `HeroPaceLine` (formerly `PaceCard`) uses for a small
/// element that genuinely depends on playback position sitting inside a screen that
/// mostly doesn't. `currentChapter` only *changes* every few minutes, but resolving it
/// reads `currentTime`, so every read of it is a subscription to the playback tick;
/// keeping that read down here means a tick re-runs this caption rather than the whole
/// player. `onTap` carries the caller's own `showChapters = true` (plus its haptic) so
/// this view holds no state of its own.
private struct PlayerChapterCaption: View {
    let onTap: () -> Void

    /// "Chapter: <title>. 56 chapters left", without saying "Chapter: Chapter 2" when the
    /// title is only a number (see `PlayerView.displayChapterTitle`).
    private func spokenChapter(_ chapter: Chapter) -> String {
        let shown = PlayerView.displayChapterTitle(chapter.title)
        let name = shown == chapter.title ? String(localized: "Chapter: \(shown)", comment: "VoiceOver: prefix before a chapter title. %@ is the chapter title") : shown
        // By position in the list, not `chapter.id` — ids are the server's, and needn't be
        // 0-based or contiguous (fourth run).
        let index = playerViewModel.chapters.firstIndex(where: { $0.id == chapter.id }) ?? -1
        return PlayerView.chapterOrientationLabel(index: index, count: playerViewModel.chapters.count)
            .map { String(localized: "\(name). \($0)", comment: "VoiceOver chapter caption. First %@ is the chapter name, second %@ the chapters-left phrase, e.g. '3 chapters left'") } ?? name
    }

    @Environment(PlayerViewModel.self) private var playerViewModel
    /// Moved verbatim from `PlayerView` along with the caption it sizes. A
    /// `@ScaledMetric` resolves against its own view's environment, and this view sits
    /// exactly where the caption did, so the rendered size is unchanged.
    @ViewBuilder
    var body: some View {
        if let chapter = playerViewModel.currentChapter {
            Button(action: onTap) {
                // P-2 (REVIEW_2026-09-14_DESIGN.md): this was a `VStack` whose second line
                // rendered `chapterOrientationLabel` — "17 chapters left". Removed as a
                // *visual* element: it was the fifth simultaneous position readout on this
                // screen, and the WHOLE BOOK rail a few rows down answers the same
                // question ("how far along am I") with a position instead of a count, next
                // to "≈4h 6m left in book" which answers it in the units someone actually
                // plans around. The label is still built for VoiceOver below, where it
                // costs nothing and replaces orientation a sighted user reads off the rail.
                // Critique 2026-10-05 (typeset): the chapter name — the most useful
                // orientation cue on the screen — was its smallest text, an 11pt base.
                // Now `Typo.metadata` (13pt, Subheadline), the same size as the author
                // line above it; amber keeps it reading as the link it is.
                Typo.metadata(
                    HStack(spacing: 4) {
                        Text(PlayerView.displayChapterTitle(chapter.title))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                    }
                )
                .foregroundStyle(Color.shelfAmberText)
            }
            .buttonStyle(.plain)
            // UI-12: this used to be `.padding(.top, 4)` plus
            // `.contentShape(Rectangle().inset(by: -10))` to fake a ≥44pt tap target,
            // on the belief that an inset content shape doesn't extend hit-testing past
            // the view's bounds. Batch 369's simulator test (iOS 27) showed it does — the
            // sleep chip's ✕ relies on it — so that belief was wrong, but real padding
            // here is still the clearer choice for a row this size, so it stays.
            //
            // §12.2/§5.2 (REDESIGN_PROPOSAL_2026-08-26.md): that math only holds at
            // default Dynamic Type. The row's height is otherwise entirely emergent
            // from content + this padding, and at xSmall (body ≈14pt, scale factor
            // ≈0.824) the text shrinks enough that content + 20 padding comes out
            // under 44 — below the size every prior review pass checked. An explicit
            // minHeight makes the target correct at every Dynamic Type size instead
            // of only the one that was measured. That minHeight is now doing strictly
            // more work than it was: P-2 dropped the caption's second line, so the
            // natural content height is a single ~11pt row and this is what keeps the
            // tap target at 44 at *every* size rather than only the small ones.
            .padding(10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(spokenChapter(chapter))
            .accessibilityHint("Opens the chapter list")
        }
    }
}
