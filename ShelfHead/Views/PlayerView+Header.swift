import SwiftUI
import TipKit

/// N-5 (REVIEW_2026-09-14_DESIGN.md): split out of `PlayerView.swift`, which had grown to
/// ~2,980 lines. Structural only — every view, modifier, gesture and doc comment below is
/// verbatim what lived on `PlayerView` itself, so nothing here changes what the screen
/// renders or how it behaves.
///
/// This file is the player's top edge: the drag handle (tap-to-close + swipe-to-dismiss),
/// the overflow ("…") menu in the top-trailing corner, the share composer that menu opens,
/// and the two constants the handle and the menu button share so their reserved space can
/// never drift apart.
extension PlayerView {
    /// H4 (REVIEW_2026-09-04_UI.md Pass 3): the header menu button's own hit-target side
    /// and its distance off the trailing edge (see `playerHeaderMenu`'s `.frame` and the
    /// `.overlay`'s `.padding(.trailing, ...)` in `body`, both of which now read from these
    /// two constants instead of repeating the literals). Named here, not just inlined at
    /// the button, so `headerMenuReservedTrailingWidth` below is computed FROM the button's
    /// actual geometry rather than a second, independently-typed magic number that could
    /// silently drift out of sync with it.
    static let headerMenuButtonSide: CGFloat = 44
    static let headerMenuButtonTrailingPadding: CGFloat = 16

    /// H4: the width the drag-handle row's `NOW PLAYING` / `CONTINUE LISTENING` text must
    /// stay clear of so it can never sit under the header menu button's 44×44 tap target.
    /// Reserving the button's full slot (side + its own trailing padding) directly on the
    /// row — rather than trying to characterize exactly how much clearance the row's own
    /// ambient padding already provides — guarantees no overlap regardless of that ambient
    /// amount: whatever margin the row already had, this adds the button's whole slot on
    /// top of it, so the row's trailing edge ends up at least this far short of the
    /// button's own reserved zone.
    static let headerMenuReservedTrailingWidth: CGFloat =
        headerMenuButtonSide + headerMenuButtonTrailingPadding

    /// Batch 424: a transcript worth searching exists (finished, paused part-way, or running with some text).
    static func hasSearchableTranscript(_ state: TranscriptionCenter.ItemState) -> Bool {
        switch state {
        case .complete, .paused: return true
        case .running(let fraction): return fraction > 0
        default: return false
        }
    }

    var playerHeaderMenu: some View {
        Menu {
            Button {
                Haptics.selection()
                showBookDetails = true
            } label: { Label("Book Details", systemImage: "info.circle") }
            Button {
                Task { await presentShare() }
            } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            // Batch 490 (REVIEW 2026-11-11 P9): the queue had no way in from the player
            // except the Up Next chip, which only shows while something is queued.
            Button {
                Haptics.selection()
                showQueue = true
            } label: { Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            // Batch 426: cut a short quote clip from the current book.
            if let book = playerViewModel.currentBook, !book.isPodcast {
                Button {
                    Haptics.selection()
                    showClipEditor = true
                } label: { Label("Clip\u{2026}", systemImage: "scissors") }
            }
            // Batch 455: post to this book's household club, pinned to where you are now.
            if HouseholdStore.shared.isSocialAvailable, let book = playerViewModel.currentBook, !book.isPodcast {
                Button {
                    Haptics.selection()
                    showBookClub = true
                } label: {
                    // Batch 490 (REVIEW 2026-11-11 P5): the same moment wording as a bookmark
                    // ("12:04 · Chapter 7"), chapter-relative, instead of the whole-book clock.
                    Label("Post to Book Club at \(BookmarksSheet.momentLabel(time: playerViewModel.currentTime, chapter: playerViewModel.currentChapter))", systemImage: "person.3")
                }
            }
            // Batch 456: listen along with someone over SharePlay (FaceTime, Messages or nearby).
            if let book = playerViewModel.currentBook, !book.isPodcast {
                ListenTogetherButton(item: book)
            }
            // Moved here from the bottom toolbar so that row holds only the five
            // core actions (Speed/Sleep/Chapters/Marks/Output) per the redesign —
            // Driving Mode is used far less often than those.
            Button {
                Haptics.selection()
                openDrivingMode()
            } label: { Label("Driving Mode", systemImage: "car.fill") }
            Button {
                Haptics.selection()
                showChapterSkip = true
            } label: { Label("Chapter Skip\u{2026}", systemImage: "forward.end") }
            // Batch 424: only when the book has transcript text to search.
            if let book = playerViewModel.currentBook, !book.isPodcast,
               Self.hasSearchableTranscript(TranscriptionCenter.shared.state(for: book.id)) {
                Button {
                    Haptics.selection()
                    showTranscriptSearch = true
                } label: { Label("Search in Book\u{2026}", systemImage: "text.magnifyingglass") }
                // Batch 425: live captions in place of the cover.
                Button {
                    Haptics.selection()
                    showsCaptions.toggle()
                } label: {
                    if showsCaptions {
                        Label("Hide Captions", systemImage: "captions.bubble.fill")
                    } else {
                        Label("Show Captions", systemImage: "captions.bubble")
                    }
                }
                // Batch 428: on-device recap and "I zoned out" (iOS 26+). Shown even when Apple
                // Intelligence is off; the sheet then says why (HIG: explain, don't hide).
                if #available(iOS 26.0, *) {
                    Button {
                        Haptics.selection()
                        showRecap = true
                    } label: { Label("Previously On\u{2026}", systemImage: "sparkles") }
                    Button {
                        Haptics.selection()
                        showZonedOut = true
                    } label: { Label("I Zoned Out", systemImage: "arrow.counterclockwise") }
                    // Batch 429: X-Ray (people, places, terms) and Ask the Book.
                    Button {
                        Haptics.selection()
                        showXRay = true
                    } label: { Label("X-Ray", systemImage: "person.2") }
                    Button {
                        Haptics.selection()
                        showAskBook = true
                    } label: { Label("Ask the Book\u{2026}", systemImage: "questionmark.circle") }
                    // Batch 431: the ebook, highlighting the sentence being spoken.
                    if book.media?.ebookFile?.metadata?.normalizedExtension == "epub" {
                        Button {
                            Haptics.selection()
                            showReadAlong = true
                        } label: { Label("Read Along", systemImage: "book") }
                    }
                }
            }

            // Batch 439: quiet rain/fire/train/brown-noise bed under the narration.
            Button {
                Haptics.selection()
                AmbientBedEngine.shared.pickerRequested = true
            } label: {
                Label("Ambient Sound", systemImage: AmbientBedEngine.shared.bed?.icon ?? "waveform")
            }

            Divider()

            // P-14 (REVIEW_2026-09-14_DESIGN.md): the Listening Profile switcher lived
            // only at Settings → Playback & Appearance → scroll, which is three levels
            // away from the one screen whose settings it changes — and the moments it
            // exists for ("I'm about to drive", "I'm going to sleep") are precisely the
            // moments nobody is going to go looking for it in Settings.
            //
            // A `Picker` inside a `Menu` renders as a submenu with the current choice
            // checked, so this stays one row in the "…" menu rather than four. Labels and
            // icons come from `ListeningProfile` itself, which is also what
            // `PlaybackSettingsSection` renders from — so the two surfaces can't drift.
            Picker(selection: Binding(
                get: { listeningProfileManager.activeProfile },
                set: { profile in
                    guard profile != listeningProfileManager.activeProfile else { return }
                    Haptics.selection()
                    listeningProfileManager.activate(profile)
                    // Critique 2026-10-05 (adapt): picking Commute here means "I'm about
                    // to drive", and Driving Mode is the screen for that — it used to be a
                    // separate trip back into this same menu, in its hardest-to-reach
                    // corner. Only from the player: Settings and CarPlay's auto-switch
                    // change the profile without opening anything.
                    if profile == .driving { openDrivingMode() }
                }
            )) {
                ForEach(ListeningProfile.allCases) { profile in
                    Label(profile.label, systemImage: profile.icon).tag(profile)
                }
            } label: {
                Label("Listening Profile", systemImage: listeningProfileManager.activeProfile.icon)
            }
        } label: {
            // iOS 26/27 Liquid Glass polish pass (26 August 2026): this button used to
            // be a bare `ellipsis.circle.fill` glyph with no background at all — a
            // single cream-on-whatever's-behind-it shape floating directly over
            // arbitrary cover art, with no guaranteed contrast. Swapped for a plain
            // `ellipsis` glyph inside a real `glassPill(Circle())` — the same helper
            // `MiniPlayerView`'s card and `RetroTabBar`'s pill already use — so this
            // reads as a proper floating glass control instead of a flat icon.
            // Critique 2026-10-05 (typeset): the glyph scales with Dynamic Type, capped at
            // 1.4× like the transport row, and its glass circle grows in proportion up to
            // the 44pt slot the drag handle already reserves for it — so H4's reserved
            // width still holds at every size.
            let glyph = Self.cappedTransportMetric(headerMenuGlyphMetric, base: 15)
            Image(systemName: "ellipsis")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(Color.shelfCream)
                .frame(width: min(32 * glyph / 15, Self.headerMenuButtonSide),
                       height: min(32 * glyph / 15, Self.headerMenuButtonSide))
                .glassPill(Circle())
                // H4 (REVIEW_2026-09-04_UI.md Pass 3): named, not a literal — the drag
                // handle's reserved trailing inset reads this same constant so the two
                // can't drift apart.
                .frame(width: Self.headerMenuButtonSide, height: Self.headerMenuButtonSide)
                .contentShape(Rectangle())
        }
        // CO-7 pilot (Batch 353): item glyphs and the profile checkmark in the label colour
        // rather than amber over the cover (measured 2.3–2.7:1). Applied on the `Menu`, not
        // after `.popoverTip`, so the tip keeps the root tint.
        .systemChromeTint()
        .accessibilityLabel("More options")
        // Batch 439: hosts the Ambient Sound sheet without new state in PlayerView.swift.
        .background(AmbientSheetHost())
        // Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10, §5.3): Driving Mode's only
        // entry point is inside this menu — see `DrivingModeTip`'s own doc comment
        // for its trigger (~20 real minutes of playback in one open session).
        .popoverTip(DrivingModeTip())
    }

    /// Loads the cover, builds the card data for the current book, and opens the
    /// swipeable style picker.
    @MainActor
    func presentShare(quote: String? = nil, quoteIsPassage: Bool = false, quoteAttribution: String? = nil, attachments: [URL] = []) async {
        guard let book = playerViewModel.currentBook else { return }
        // Load cover + stats + sessions concurrently.
        async let coverA = ShareCardRenderer.loadCover(itemId: book.id)
        async let statsA = AudiobookshelfAPI.shared.getListeningStats()
        async let sessionsA = AudiobookshelfAPI.shared.getListeningSessions(itemsPerPage: 100)
        let cover = await coverA
        let statsModel = try? await statsA
        let sessions = (try? await sessionsA) ?? []
        let speed = Double(playerViewModel.playbackRate)
        let speedStr = speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
        let finished = playerViewModel.progress >= 0.999
        let progressData = ProgressShareData(
            progress: playerViewModel.progress,
            listened: playerViewModel.currentTime.formattedDuration,
            remaining: "\(playerViewModel.remainingTime.formattedDuration) remaining",
            speed: speedStr,
            chapters: book.chapters.count
        )
        let chapter = playerViewModel.currentChapter.map {
            ChapterShareData(index: nil, total: book.chapters.count, title: $0.title)
        }
        let stats = ListeningStatistics.from(stats: statsModel, sessions: sessions,
                                             finishedBooks: libraryViewModel.finishedBooksCount,
                                             streak: libraryViewModel.listeningStreak)
        let completion = finished ? CompletionShareData(
            totalTime: playerViewModel.duration.formattedDuration,
            finishedInDays: nil,
            bookNumber: libraryViewModel.finishedBooksCount) : nil
        let ctx = ShareCardContext(
            itemId: book.id,
            serverId: AuthStore.shared.serverURL,
            userId: AccountStore.currentAccountId ?? "",
            cover: cover,
            title: book.title,
            author: book.authorName,
            narrator: book.narratorName,
            quote: quote,
            quoteAttribution: quoteAttribution,
            quoteIsUserNote: quote != nil && !quoteIsPassage,   // Y2 (REVIEW_2026-09-04_UI.md): a bookmark note, not a book passage
            quoteIsPassage: quote != nil && quoteIsPassage,
            chapter: chapter,
            progress: progressData,
            completion: completion,
            statistics: stats,
            isFinished: finished
        )
        shareSession = ShareSession(context: ctx, attachments: attachments)
    }

    // MARK: - Drag to dismiss

    /// The one dismiss action for the full player — the drag handle's tap, the swipe
    /// threshold below, and (HIG audit 2026-09-17 M9) VoiceOver's `.accessibilityAction
    /// (.escape)` on the outer container in `PlayerView.body` all call this rather than
    /// each spelling out their own `withAnimation`/Reduce-Motion handling, so the three
    /// can't drift out of sync.
    func dismissFullPlayer() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            playerViewModel.showFullPlayer = false
        }
    }

    /// Interactive swipe-down-to-dismiss on the header. Follows the finger, then
    /// either dismisses (quick ease-out slide) or snaps back.
    var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if value.translation.height > 0 { dragOffset = value.translation.height * 0.7 }
            }
            .onEnded { value in
                if value.translation.height > 90 || value.velocity.height > 500 {
                    dismissFullPlayer()
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Drag Handle

    var dragHandle: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.shelfCream.opacity(0.3))
                .frame(width: 40, height: 5)

            // Batch 218 (R10.5): the doc comment right below already called this
            // region "a visible, tappable close affordance" — but that was only
            // true in the code, not on screen; nothing visually signaled it. A
            // small, muted `chevron.down` next to the grabber does, without
            // competing with "NOW PLAYING"/the playing-state dot for attention.
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    // H4 (REVIEW_2026-09-04_UI.md Pass 3): was a hardcoded 10 that stayed
                    // 10pt while the wordmark next to it tripled in size at AX5, so the
                    // close affordance U4 fixed for contrast became invisible again by
                    // comparison. `relativeTo: .caption2` matches the wordmark's own
                    // `scaledFont` below, so the two scale together; at `.large` this is
                    // exactly 10, unchanged.
                    .font(.system(size: dragHandleChevronMetric, weight: .semibold))
                    // U4 (REVIEW_2026-08-20_UI_SECURITY.md): 0.35 measured 2.09:1 Light /
                    // 2.89:1 Dark against the 3:1 non-text floor — the close affordance
                    // R10.5 added was itself near-invisible. 0.6 clears 3:1 in both themes.
                    .foregroundStyle(Color.shelfCream.opacity(0.6))
                Circle()
                    .fill(playerViewModel.isPlaying ? Color.shelfOrange : Color.shelfMuted)
                    .frame(width: 6, height: 6)
                // Critique 2026-10-05 (clarify): a live transport state instead of a
                // whole-session "CONTINUE LISTENING". See `PlayerHeaderStatusLabel`.
                PlayerHeaderStatusLabel(usesAccessibilityLayout: usesAccessibilityLayout)
            }
            // H4 (REVIEW_2026-09-04_UI.md Pass 3): the header menu button is an
            // `.overlay` on the whole column (see `body`), not a sibling in this row, so
            // this row has no natural way to know it's there — at AX5 the wordmark's last
            // glyphs sat inside the button's 44×44 tap target, so tapping the end of
            // "NOW PLAYING" opened the overflow menu instead of closing the player.
            // Reserving the button's full slot directly on this row (rather than trying
            // to characterize the row's existing ambient clearance) guarantees the two
            // can never occupy the same points, regardless of that ambient amount. Zero
            // below `usesAccessibilityLayout`, so `.large` keeps its exact current
            // layout — this is a no-op modifier there, not a smaller one.
            // Critique 2026-10-05 (second run): below the AX layout this used to reserve
            // nothing, so at AX1–AX2 on a 375 pt phone "WAITING FOR SERVER" could run under
            // the ••• button's 44 pt target. Reserving the same width on both sides keeps the
            // row centred; at `.large` NOW PLAYING is far narrower than what's left.
            // Critique 2026-10-05 (fourth run): at AX3+ this reserved the ••• width on the
            // trailing side only, so the status word sat off-centre. Reserving it on both
            // sides keeps the guarantee (nothing under the button) and the centring.
            .padding(.horizontal, usesAccessibilityLayout ? Self.headerMenuReservedTrailingWidth : 0)
            // Critique 2026-10-05 (third run): the strip already sits 48 pt in from each edge
            // (column 24 + handle 24), so only the part of the ••• slot past that needs
            // reserving; the full width left ~131 pt and truncated WAITING FOR SERVER.
            .padding(.horizontal, usesAccessibilityLayout ? 0 : max(0, Self.headerMenuReservedTrailingWidth - 48))
        }
        // AX-4 (docs/design-review.md, Round 4): the tap-to-close and its accessibility
        // element moved to the call site in `PlayerView.body`, after the handle's
        // padding, so the whole padded strip (~50 pt tall) is the target rather than
        // this ~28 pt content. See the comment there.
    }

    /// iPhone Duo (§4): the drag-handle strip for the folded player's controls pane — the
    /// same modifiers, in the same order, that `body` applies to `dragHandle` in the flat
    /// column (padding, whole-strip tap-to-close, one accessibility element, the exclusive
    /// `dismissDrag`). `body`'s own copy is deliberately left where it is so the flat layout
    /// is untouched; keep the two in step.
    var foldedDragHandleStrip: some View {
        dragHandle
            .padding(.top, 14)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissFullPlayer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Close player")
            .accessibilityValue(PlayerView.headerStatus(
                isPlaying: playerViewModel.isPlaying,
                isWaiting: playerViewModel.isTransportWaiting,
                stalled: playerViewModel.transportStalled,
                isStreaming: playerViewModel.isStreamingCurrentBook).spokenText)
            .accessibilityAddTraits(.isButton)
            .gesture(dismissDrag)
    }
}

extension PlayerView {
    /// Presents Driving Mode and retires its tip. Code review fix (26 August 2026): TipKit
    /// hygiene — retire `DrivingModeTip` the moment someone actually opens Driving Mode,
    /// the exact action it exists to surface. Without this, the tip could keep reappearing
    /// for someone who already found the entry point. `drivingModeOpened` also stops the
    /// elapsed-time donation loop from continuing to write to TipKit's datastore for a tip
    /// that's already retired — `invalidate` alone doesn't inform that loop.
    func openDrivingMode() {
        showDrivingMode = true
        DrivingModeTip.drivingModeOpened = true
        DrivingModeTip().invalidate(reason: .actionPerformed)
    }
}

/// The drag-handle strip's status word (critique 2026-10-05, clarify). Its own view so the
/// stall timer's `@State` and the per-change reads stay out of `PlayerView.body`.
private struct PlayerHeaderStatusLabel: View {
    @Environment(PlayerViewModel.self) private var playerViewModel
    let usesAccessibilityLayout: Bool
    private var status: PlayerView.HeaderStatus {
        PlayerView.headerStatus(isPlaying: playerViewModel.isPlaying,
                                isWaiting: playerViewModel.isTransportWaiting,
                                stalled: playerViewModel.transportStalled,
                                isStreaming: playerViewModel.isStreamingCurrentBook)
    }

    var body: some View {
        Text(status.text)
            .scaledFont(10, weight: .bold, design: .rounded, relativeTo: .caption2)
            // H4 (REVIEW_2026-09-04_UI.md Pass 3): fixed letter-spacing doesn't
            // shrink as a share of the glyph the way the font size does, so at
            // AX5 it's pure extra width this wordmark can't spare. Below
            // `usesAccessibilityLayout` this is the original `.tracking(2)`,
            // unchanged.
            .tracking(usesAccessibilityLayout ? 0 : LocalizedText.tracking(2))
            // `WAITING FOR SERVER` (like the old `CONTINUE LISTENING`) is much
            // wider than `NOW PLAYING` and doesn't fit the accessibility-size
            // column at full size regardless of the header menu button —
            // `.lineLimit(1)` plus a shrink floor (not wrapping) is what keeps it
            // out of the button's reserved trailing width rather than growing
            // into it.
            .lineLimit(1)
            .minimumScaleFactor(usesAccessibilityLayout ? 0.5 : 0.7)
            // U2 (REVIEW_2026-08-20_UI_SECURITY.md): `shelfAmberText` is computed
            // to just barely clear 4.5:1 and stop (Extensions.swift's
            // `adjustedHexForContrast`) — it has zero headroom for an opacity on
            // top, which is exactly what dropped this to 3.59:1 in Light. Full
            // strength is the intended contrast; `shelfAmberText` must never be
            // combined with `.opacity()`. Paused isn't live state, so it reads in
            // `shelfMuted` (5.6:1 Light / 6.2:1 Dark) rather than amber.
            .foregroundStyle(status.isLive ? Color.shelfAmberText : Color.shelfMuted)
            // The stall timer lives in `PlayerViewModel` now (one clock for the header,
            // the close strip and Driving Mode); this only announces the moment it trips.
            .onChange(of: playerViewModel.transportStalled) { _, stalled in
                if stalled, status == .waitingForServer {
                    AccessibilityNotification.Announcement(status.spokenText).post()
                }
            }
    }
}
