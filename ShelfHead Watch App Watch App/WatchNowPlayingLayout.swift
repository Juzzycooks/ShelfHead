import SwiftUI

// Batch 497 (REVIEW 2026-11-11 W10): the pure decisions behind Now Playing's first
// screen. `WatchNowPlayingLayout` picks how much the screen sheds so Speed, Sleep and
// Chapters fit above the fold on 40/41 mm; `WatchChapterWindow` makes the bar, the
// times and the Crown's scrub range chapter-relative when the book has chapters.
//
// Apple pages read (developer.apple.com JSON endpoint, 13 Nov 2026):
// - HIG Accessibility: watchOS controls default 44×44 pt, minimum 28×28 pt.
// - HIG Layout (watchOS): no more than three glyph buttons in a row. The tool row keeps
//   four (Speed, Sleep, Chapters, Bookmark) as before this batch; a deliberate departure.
// - onGeometryChange(for:of:action:) (watchOS 9.0), used to measure the container.

/// How the first screen of Now Playing is laid out.
nonisolated enum WatchNowPlayingLayoutStyle: Equatable, Sendable {
    /// Cover, two-line title, tools with a caption under the icon.
    case regular
    /// Cover and two-line title kept; the tools drop their captions.
    case compactTools
    /// No cover (the blurred backdrop still shows it), one-line title, icon-only tools,
    /// Play no bigger than the skip buttons.
    case compact
    /// Accessibility text sizes: the compact header, 44 pt icon-only tools, and the
    /// screen scrolls rather than squeezing anything below the HIG minimum.
    case accessibility
}

nonisolated struct WatchNowPlayingLayout: Equatable, Sendable {
    var style: WatchNowPlayingLayoutStyle

    var showsCover: Bool { style == .regular || style == .compactTools }
    var titleLineLimit: Int { showsCover ? 2 : 1 }
    var showsToolCaptions: Bool { style == .regular }
    /// Never below the HIG's 28 pt watchOS minimum; 44 where there's room for it.
    var toolMinHeight: CGFloat {
        switch style {
        case .regular, .accessibility: return 44
        case .compactTools, .compact: return Self.iconOnlyToolHeight
        }
    }
    var stackSpacing: CGFloat {
        switch style {
        case .regular, .accessibility: return 6
        case .compactTools: return 4
        case .compact: return 3
        }
    }
    var scrubVerticalPadding: CGFloat { style == .regular || style == .accessibility ? 3 : 2 }
    var transportTopPadding: CGFloat { style == .regular || style == .accessibility ? 2 : 0 }
    /// Caps the Play button's side; nil leaves `WatchTransportLayout`'s choice.
    var playSizeCap: CGFloat? { style == .compact ? WatchTransportLayout.minimumPlay : nil }

    static let iconOnlyToolHeight: CGFloat = 32
    /// Room left under the estimate so a rounding difference doesn't clip the tool row.
    static let fitMargin: CGFloat = 2
    /// Top bar (clock and "⋯") the container loses before it's measured. From memory of
    /// the watchOS 10 navigation bar, not an Apple figure; only used until the first
    /// `onGeometryChange` reading replaces it.
    static let estimatedTopBarHeight: CGFloat = 44

    /// Picks the roomiest style whose estimated height fits `containerSize`, else
    /// `.compact` (the screen scrolls). Any accessibility size gets `.accessibility`.
    static func decide(containerSize: CGSize, dynamicTypeSize: DynamicTypeSize) -> WatchNowPlayingLayout {
        if dynamicTypeSize.isAccessibilitySize { return WatchNowPlayingLayout(style: .accessibility) }
        for style in [WatchNowPlayingLayoutStyle.regular, .compactTools, .compact] {
            let height = estimatedHeight(style: style, containerWidth: containerSize.width, dynamicTypeSize: dynamicTypeSize)
            if height + fitMargin <= containerSize.height { return WatchNowPlayingLayout(style: style) }
        }
        return WatchNowPlayingLayout(style: .compact)
    }

    /// The container a screen of this size offers before the view has been measured.
    static func estimatedContainerSize(screen: CGSize) -> CGSize {
        CGSize(width: screen.width, height: max(0, screen.height - estimatedTopBarHeight))
    }

    /// Rough relative text size for the estimate (Large = 1). Not Apple's table.
    static func textScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        default: return 1.6
        }
    }

    /// Header + time row + transport + tool row, plus the gaps between them. Leaves out
    /// the banners and notices that only show some of the time.
    static func estimatedHeight(style: WatchNowPlayingLayoutStyle, containerWidth: CGFloat,
                                dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let layout = WatchNowPlayingLayout(style: style)
        let scale = textScale(dynamicTypeSize)
        let titleLine = 20 * scale
        let captionLine = 17 * scale
        let iconLine = 23 * scale

        let text = CGFloat(layout.titleLineLimit) * titleLine + 1 + captionLine
        let cover = layout.showsCover
            ? max(WatchNowPlayingHeaderLayout.minimumCoverSide,
                  min(WatchNowPlayingHeaderLayout.maximumCoverSide, (containerWidth * 0.45).rounded(.down)))
            : 0
        let header = max(cover, text)
        let scrub = 2 * layout.scrubVerticalPadding + 4 + 3 + captionLine
        var play = WatchTransportLayout.forScreenWidth(containerWidth).play
        if let cap = layout.playSizeCap { play = min(play, cap) }
        let transport = play + layout.transportTopPadding
        let tools = layout.showsToolCaptions
            ? max(layout.toolMinHeight, iconLine + 2 + captionLine)
            : max(layout.toolMinHeight, iconLine + 8)
        return header + scrub + transport + tools + 3 * layout.stackSpacing
    }
}

// MARK: - Chapter-relative position

/// The span the bar, the times and the Crown work within: the current chapter when the
/// book has usable chapters, else the whole book.
nonisolated struct WatchChapterWindow: Equatable, Sendable {
    var start: Double
    var end: Double
    /// Index into the valid chapters, nil for the whole-book window.
    var chapterIndex: Int?
    var title: String?

    var isChapter: Bool { chapterIndex != nil }
    var length: Double { max(end - start, 0) }

    static func wholeBook(duration: Double) -> WatchChapterWindow {
        WatchChapterWindow(start: 0, end: duration.isFinite ? max(duration, 0) : 0, chapterIndex: nil, title: nil)
    }

    /// Chapters with finite bounds and a positive length. Bad server data otherwise
    /// gives a zero or negative window.
    static func validChapters(_ chapters: [WatchChapterRow]) -> [WatchChapterRow] {
        chapters.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
    }

    /// The window for `time`, by `WatchChapterRow.current(in:at:)`'s rule. Falls back to
    /// the whole book when there are no usable chapters or none contains `time`.
    static func resolve(chapters: [WatchChapterRow], at time: Double, duration: Double) -> WatchChapterWindow {
        let valid = validChapters(chapters)
        guard time.isFinite,
              let hit = WatchChapterRow.current(in: valid, at: time),
              let index = valid.firstIndex(of: hit) else {
            return wholeBook(duration: duration)
        }
        // A chapter that runs past the book's end ends with the book.
        var end = hit.end
        if duration.isFinite, duration > hit.start, end > duration { end = duration }
        let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchChapterWindow(start: hit.start, end: end, chapterIndex: index,
                                  title: title.isEmpty ? nil : title)
    }

    /// Seconds into the window, clamped to it.
    func elapsed(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(max(time - start, 0), length)
    }

    /// Seconds left in the window, clamped to it.
    func remaining(at time: Double) -> Double {
        guard time.isFinite else { return length }
        return min(max(end - time, 0), length)
    }

    func progress(at time: Double) -> Double {
        length > 0 ? elapsed(at: time) / length : 0
    }

    /// The Crown's range. A chapter's runs from one second before its start (into the
    /// previous chapter) to its end (the next chapter's start), so turning past either
    /// edge carries into the neighbour and the window follows. The book's start and end
    /// stay hard stops.
    func crownRange(bookDuration: Double) -> ClosedRange<Double> {
        let bookEnd = bookDuration.isFinite ? max(bookDuration, 1) : 1
        guard isChapter else { return 0...bookEnd }
        let lower = max(0, start - 1)
        let upper = min(max(end, lower + 1), max(bookEnd, lower + 1))
        return lower...upper
    }

    /// A seek target clamped to the book. Seeking across a chapter boundary is allowed;
    /// only the book's ends stop it.
    static func clampedSeek(_ target: Double, duration: Double) -> Double {
        guard target.isFinite else { return 0 }
        let upper = duration.isFinite ? max(duration, 0) : 0
        return min(max(target, 0), upper)
    }

    /// The time the screen shows: the Crown's while it scrubs, so the window, bar and
    /// times follow the turn (across a boundary too) before the seek commits.
    static func displayTime(elapsed: Double, crownPosition: Double, isScrubbing: Bool) -> Double {
        isScrubbing && crownPosition.isFinite ? crownPosition : elapsed
    }
}
