import SwiftUI
import UIKit

/// Batch 462: everything the Year in Review video shows, gathered once so the reel can be drawn
/// frame by frame from a single time value. Built from the figures `YearInReviewView` already
/// computes plus `FinishedBookCatalog`; covers are preloaded because `ImageRenderer` can't wait
/// for an async image.
struct YearInReviewReelData: Identifiable {
    var id: Int { year }
    struct TopBook: Identifiable {
        var id: String
        var title: String
        var author: String?
        var seconds: Double
    }

    struct Month: Identifiable {
        var id: Int
        var label: String
        var minutes: Double
    }

    var year: Int
    var totalSeconds: Double
    /// Distinct books played this year, or nil when the sessions couldn't be loaded.
    var booksPlayed: Int?
    var topBooks: [TopBook]
    var months: [Month]
    /// This year's finished books, newest first (the reel draws the first few).
    var finishedBooks: [FinishedBook]
    /// Preloaded covers keyed by library item id.
    var covers: [String: UIImage] = [:]

    /// How many spines the finished scene draws.
    static let maxSpines = 10
}

/// Batch 462: the Year in Review video, drawn purely from `time` (seconds, 0…30): no animations,
/// no `TimelineView` inside, so `ImageRenderer` can rasterise any frame and the preview can
/// drive it from its own clock. 1080×1920 points. Dark espresso ground with one amber light
/// (the rule/bar/peak in each scene); teal appears only for finished books (Teal-Means-Done).
///
/// DESIGN.md departure, deliberate: type is sized in fixed video pixels (via `scaledFont` with
/// the environment pinned to the standard Dynamic Type size by the renderer), not the in-app
/// Typo roles, which are far too small for a 1080-wide canvas.
struct YearInReviewReel: View {
    static let size = CGSize(width: 1080, height: 1920)

    let data: YearInReviewReelData
    let time: Double

    var body: some View {
        ZStack {
            Color.shelfBackground
            // The one light: a soft amber glow low in the frame.
            RadialGradient(colors: [Color.shelfAmber.opacity(0.16), .clear],
                           center: .init(x: 0.5, y: 0.78), startRadius: 0, endRadius: 900)
            ForEach(Array(ReelTimeline.weights(at: time).enumerated()), id: \.offset) { _, entry in
                sceneView(entry.scene, progress: ReelTimeline.progress(of: entry.scene, at: time))
                    .opacity(entry.weight)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }

    @ViewBuilder private func sceneView(_ scene: ReelTimeline.Scene, progress p: Double) -> some View {
        switch scene {
        case .title: titleScene(p)
        case .hours: hoursScene(p)
        case .topBooks: topBooksScene(p)
        case .months: monthsScene(p)
        case .finished: finishedScene(p)
        case .closing: closingScene(p)
        }
    }

    // MARK: - Pieces

    private func caption(_ text: Text, _ opacity: Double = 1) -> some View {
        text
            .scaledFont(40, weight: .bold, design: .rounded)
            .tracking(8)
            .textCase(.uppercase)
            .foregroundStyle(Color.shelfMuted)
            .opacity(opacity)
    }

    private func rise(_ amount: Double) -> CGFloat { CGFloat((1 - amount) * 60) }

    // MARK: - Scene 1: title

    private func titleScene(_ p: Double) -> some View {
        let a = ReelTimeline.reveal(p, delay: 0.05, length: 0.2)
        let b = ReelTimeline.reveal(p, delay: 0.15, length: 0.25)
        let c = ReelTimeline.reveal(p, delay: 0.35, length: 0.25)
        return VStack(spacing: 40) {
            caption(Text("Your year in"), a)
            Text(verbatim: String(data.year))
                .scaledFont(300, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.shelfCream)
                .opacity(b)
                .offset(y: rise(b))
            Capsule().fill(Color.shelfAmber)
                .frame(width: 520 * c, height: 10)
            caption(Text("audiobooks"), c)
        }
    }

    // MARK: - Scene 2: hours

    private func hoursScene(_ p: Double) -> some View {
        let figure = YearInReviewView.heroFigure(totalSeconds: data.totalSeconds)
        let target = Double(figure.value) ?? 0
        let count = ReelTimeline.reveal(p, delay: 0.08, length: 0.6)
        let shown = Int((target * count).rounded())
        let labelIn = ReelTimeline.reveal(p, delay: 0.5, length: 0.2)
        let booksIn = ReelTimeline.reveal(p, delay: 0.62, length: 0.2)
        return VStack(spacing: 24) {
            caption(Text("You listened for"), ReelTimeline.reveal(p, delay: 0, length: 0.15))
            Text(verbatim: String(shown))
                .scaledFont(380, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.shelfCream)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, 60)
            Text(verbatim: figure.unit)
                .scaledFont(96, weight: .semibold, design: .rounded)
                .foregroundStyle(Color.shelfCream)
                .opacity(labelIn)
            // The amber light: a counter strip that fills as the number climbs.
            Capsule().fill(Color.shelfSurface).frame(width: 640, height: 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.shelfAmber).frame(width: 640 * count, height: 10)
                }
                .padding(.top, 24)
            if let books = data.booksPlayed {
                Text("\(books) books played")
                    .scaledFont(56, weight: .medium, design: .rounded)
                    .foregroundStyle(Color.shelfMuted)
                    .opacity(booksIn)
                    .padding(.top, 24)
            }
        }
    }

    // MARK: - Scene 3: top books

    private func topBooksScene(_ p: Double) -> some View {
        let books = Array(data.topBooks.prefix(3))
        return VStack(spacing: 56) {
            caption(Text("Most played"), ReelTimeline.reveal(p, delay: 0, length: 0.12))
            if books.isEmpty {
                Text("Pick a few favourites next year")
                    .scaledFont(64, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.shelfMuted)
            }
            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                let a = ReelTimeline.reveal(p, delay: 0.1 + 0.2 * Double(index), length: 0.2)
                HStack(spacing: 44) {
                    Text(verbatim: "\(index + 1)")
                        .scaledFont(120, weight: .bold, design: .monospaced)
                        .foregroundStyle(index == 0 ? Color.shelfAmber : Color.shelfMuted)
                        .frame(width: 90)
                    cover(book.id, side: index == 0 ? 360 : 260)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: book.title)
                            .scaledFont(index == 0 ? 56 : 44, weight: .bold, design: .rounded)
                            .foregroundStyle(Color.shelfCream)
                            .lineLimit(3)
                        if let author = book.author {
                            Text(verbatim: author)
                                .scaledFont(36, design: .rounded)
                                .foregroundStyle(Color.shelfMuted)
                                .lineLimit(1)
                        }
                        Text(verbatim: YearInReviewView.formatHours(book.seconds))
                            .scaledFont(36, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Color.shelfMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 60)
                .opacity(a)
                .offset(x: CGFloat((1 - a) * 120))
            }
        }
    }

    @ViewBuilder private func cover(_ id: String, side: CGFloat) -> some View {
        if let image = data.covers[id] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.shelfSurface)
                .frame(width: side, height: side)
                .overlay(Image(systemName: "book.closed.fill")
                    .scaledFont(side * 0.3)
                    .foregroundStyle(Color.shelfMuted))
        }
    }

    // MARK: - Scene 4: months

    private func monthsScene(_ p: Double) -> some View {
        let months = data.months
        let peak = months.max { $0.minutes < $1.minutes }
        let maxMinutes = max(peak?.minutes ?? 0, 1)
        let chartHeight: CGFloat = 760
        return VStack(spacing: 60) {
            caption(Text("Month by month"), ReelTimeline.reveal(p, delay: 0, length: 0.12))
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(months) { month in
                    let grow = ReelTimeline.reveal(p, delay: 0.1 + 0.04 * Double(month.id), length: 0.3)
                    let isPeak = month.id == peak?.id && month.minutes > 0
                    VStack(spacing: 18) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isPeak ? Color.shelfAmber : Color.shelfCream.opacity(0.35))
                            .frame(width: 62, height: max(8, chartHeight * CGFloat(month.minutes / maxMinutes * grow)))
                        Text(verbatim: String(month.label.prefix(1)))
                            .scaledFont(34, weight: .semibold, design: .rounded)
                            .foregroundStyle(Color.shelfMuted)
                    }
                    .frame(height: chartHeight + 60, alignment: .bottom)
                }
            }
            if let peak, peak.minutes > 0 {
                let note = ReelTimeline.reveal(p, delay: 0.65, length: 0.2)
                VStack(spacing: 8) {
                    Text("Biggest month")
                        .scaledFont(40, weight: .medium, design: .rounded)
                        .foregroundStyle(Color.shelfMuted)
                    Text(verbatim: "\(peak.label) \u{00B7} \(YearInReviewView.formatHours(peak.minutes * 60))")
                        .scaledFont(72, weight: .bold, design: .rounded)
                        .foregroundStyle(Color.shelfCream)
                }
                .opacity(note)
            }
        }
    }

    // MARK: - Scene 5: finished

    private func finishedScene(_ p: Double) -> some View {
        let books = Array(data.finishedBooks.prefix(YearInReviewReelData.maxSpines))
        let count = data.finishedBooks.count
        let shownCount = Int((Double(count) * ReelTimeline.reveal(p, delay: 0.1, length: 0.35)).rounded())
        return VStack(spacing: 40) {
            caption(Text("You finished"), ReelTimeline.reveal(p, delay: 0, length: 0.12))
            if count == 0 {
                Text("Your next finish is out there")
                    .scaledFont(64, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.shelfMuted)
            } else {
                // Teal-Means-Done: the only teal in the reel.
                Text(verbatim: String(shownCount))
                    .scaledFont(320, weight: .bold, design: .monospaced)
                    .foregroundStyle(Color.shelfAccent)
                Text(count == 1 ? "book" : "books")
                    .scaledFont(80, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.shelfCream)
                HStack(spacing: 10) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        let a = ReelTimeline.reveal(p, delay: 0.3 + 0.05 * Double(index), length: 0.25)
                        CassetteSpineView(book: book, width: 80)
                            .offset(y: CGFloat((1 - a) * 200))
                            .opacity(a)
                    }
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Scene 6: closing

    private func closingScene(_ p: Double) -> some View {
        let a = ReelTimeline.reveal(p, delay: 0.05, length: 0.3)
        let b = ReelTimeline.reveal(p, delay: 0.35, length: 0.3)
        return VStack(spacing: 36) {
            Image(systemName: "headphones.circle.fill")
                .scaledFont(220)
                .foregroundStyle(Color.shelfAmber)
                .opacity(a)
                .scaleEffect(0.85 + 0.15 * a)
            Text(verbatim: "ShelfHead")
                .scaledFont(150, weight: .bold, design: .rounded)
                .foregroundStyle(Color.shelfCream)
                .opacity(a)
            Text("Audiobooks, perfectly placed.")
                .scaledFont(52, weight: .medium, design: .rounded)
                .foregroundStyle(Color.shelfMuted)
                .opacity(b)
        }
    }
}
