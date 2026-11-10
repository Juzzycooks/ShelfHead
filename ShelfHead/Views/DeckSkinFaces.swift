import SwiftUI

// Batch 460: the artwork-slot faces for the non-classic deck skins. Each face fits inside a
// `size`×`size` box (the slot the classic cover/cassette already budgets) and keeps the book's
// cover visible. Hardware is dark in both themes, like `CassetteView`. Reels turn only while
// playing, at a speed tied to the playback rate, and hold still under Reduce Motion. Cream
// detailing only: the one amber accent on the player stays the play button.

/// Chooses between the classic artwork (the caller's own content, unchanged) and a skin face.
struct DeckSkinStage<Classic: View>: View {
    @AppStorage(SettingsKeys.deckSkin) private var skinRaw = DeckSkin.default.rawValue
    let coverURL: URL?
    let spinning: Bool
    let rate: Float
    /// A closure so the playback-tick dependency of `currentChapterIndex` is only taken (inside
    /// this view's body) for the 8-track skin.
    let chapterIndex: () -> Int?
    let palette: CoverPalette?
    let size: CGFloat
    @ViewBuilder var classic: () -> Classic

    var body: some View {
        let skin = DeckSkin(rawValue: skinRaw) ?? .classic
        // Batch 464: the cover/cassette flip belongs to Classic only. It used to win over every
        // skin, so anyone who had ever flipped to the cassette (a persisted setting) saw the
        // classic cassette whichever skin they picked (device test DS1).
        if skin == .classic {
            classic()
        } else {
            DeckSkinFace(skin: skin, coverURL: coverURL, spinning: spinning, rate: rate,
                         chapterIndex: skin == .eightTrack ? chapterIndex() : nil, palette: palette, size: size)
                .transition(.opacity)
        }
    }
}

struct DeckSkinFace: View {
    let skin: DeckSkin
    let coverURL: URL?
    let spinning: Bool
    let rate: Float
    let chapterIndex: Int?
    let palette: CoverPalette?
    let size: CGFloat

    var body: some View {
        Group {
            switch skin {
            case .walkman: walkman
            case .reelToReel: reelToReel
            case .eightTrack: eightTrack
            case .boombox: boombox
            case .fromTheCover: fromTheCover
            case .classic: EmptyView()
            }
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .dark)
    }

    private var shell: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(colors: skin.shellColors, startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LinearGradient(colors: [Color.shelfCream.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 10)
    }

    private func label(_ side: CGFloat) -> some View {
        CachedCover(url: coverURL, fit: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.shelfCream.opacity(0.18), lineWidth: 1))
    }

    private func reel(_ side: CGFloat) -> some View {
        DeckReel(spinning: spinning, rate: rate, size: side)
    }

    // Walkman: a compact cassette, cover as the label, window with turning reels.
    private var walkman: some View {
        ZStack {
            shell
            VStack(spacing: size * 0.04) {
                label(size * 0.56)
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                    HStack {
                        reel(size * 0.2)
                        Spacer()
                        Rectangle().fill(Color.shelfCream.opacity(0.12)).frame(height: 4)
                        Spacer()
                        reel(size * 0.2)
                    }
                    .padding(.horizontal, size * 0.06)
                }
                .frame(height: size * 0.24)
                .padding(.horizontal, size * 0.08)
            }
        }
    }

    // Reel-to-reel: two big reels joined by a tape path over a head block; cover on a label card.
    private var reelToReel: some View {
        ZStack {
            shell
            VStack(spacing: size * 0.05) {
                ZStack {
                    Path { p in
                        let w = size, y = size * 0.36
                        p.move(to: CGPoint(x: w * 0.22, y: y))
                        p.addLine(to: CGPoint(x: w * 0.40, y: y))
                        p.addLine(to: CGPoint(x: w * 0.44, y: y - 4))
                        p.addLine(to: CGPoint(x: w * 0.56, y: y - 4))
                        p.addLine(to: CGPoint(x: w * 0.60, y: y))
                        p.addLine(to: CGPoint(x: w * 0.78, y: y))
                    }
                    .stroke(Color.shelfCream.opacity(0.35), lineWidth: 2)
                    .frame(width: size, height: size * 0.4)
                    HStack {
                        reel(size * 0.36)
                        Spacer()
                        reel(size * 0.36)
                    }
                    .padding(.horizontal, size * 0.06)
                }
                .frame(height: size * 0.4)
                label(size * 0.42)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.shelfCream.opacity(0.08)))
            }
            .padding(.vertical, size * 0.05)
        }
    }

    // 8-track: a cartridge with the cover as its label and a four-lamp program indicator.
    private var eightTrack: some View {
        let program = DeckSkin.programNumber(chapterIndex: chapterIndex)
        return ZStack {
            shell
            VStack(spacing: size * 0.05) {
                HStack(spacing: size * 0.04) {
                    ForEach(1...4, id: \.self) { n in
                        Circle()
                            .fill(Color.shelfCream.opacity(n == program ? 0.9 : 0.15))
                            .frame(width: size * 0.05, height: size * 0.05)
                    }
                }
                label(size * 0.62)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.4))
                    .frame(width: size * 0.5, height: size * 0.05)
            }
            .padding(.vertical, size * 0.06)
        }
        .accessibilityHidden(true)
    }

    // Boombox: twin speaker grilles around a cassette door with the cover and turning reels.
    private var boombox: some View {
        ZStack {
            shell
            HStack(spacing: size * 0.04) {
                grille(size * 0.24)
                VStack(spacing: size * 0.03) {
                    label(size * 0.34)
                    HStack {
                        reel(size * 0.13)
                        Spacer()
                        reel(size * 0.13)
                    }
                    .padding(.horizontal, size * 0.03)
                    .frame(width: size * 0.38)
                }
                grille(size * 0.24)
            }
            .padding(.horizontal, size * 0.05)
        }
    }

    private func grille(_ side: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.4))
            ForEach(1..<4, id: \.self) { i in
                Circle().strokeBorder(Color.shelfCream.opacity(0.18), lineWidth: 1)
                    .frame(width: side * CGFloat(i) / 3.4, height: side * CGFloat(i) / 3.4)
            }
        }
        .frame(width: side, height: side)
    }

    // From the Cover: the classic plain layout, on the book's own palette.
    private var fromTheCover: some View {
        let p = palette ?? .brand
        return ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: p.deckBodyTones, startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.highlight.opacity(0.35), lineWidth: 1))
            label(size * 0.82)
        }
    }
}

// MARK: - Reel

/// A tape reel whose speed follows the playback rate (`DeckSkin.reelDegreesPerSecond`). The
/// angle accumulates across rate changes, so changing speed never snaps the reel.
struct DeckReel: View {
    var spinning: Bool
    var rate: Float
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = ReelClock()
    @State private var cue = DeckCue.shared

    final class ReelClock {
        var angle: Double = 0
        var last: Date?
    }

    var body: some View {
        // Batch 465: the reels also wind (fast, in the skip's direction) for a moment after a
        // skip or chapter jump, playing or not, like a deck's cue/review.
        let animate = (spinning || cue.isWinding) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
            reel.rotationEffect(.degrees(advance(to: context.date, animate: animate)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func advance(to date: Date, animate: Bool) -> Double {
        guard animate else { clock.last = nil; return clock.angle }
        if let last = clock.last {
            let play = spinning ? DeckSkin.reelDegreesPerSecond(rate: rate) : 0
            let wind = DeckCue.windDegreesPerSecond(direction: cue.direction, since: cue.startedAt, now: date)
            clock.angle = (clock.angle + date.timeIntervalSince(last) * (play + wind))
                .truncatingRemainder(dividingBy: 360)
        }
        clock.last = date
        return clock.angle
    }

    private var reel: some View {
        ZStack {
            Circle().fill(Color.shelfSurface)
            Circle().strokeBorder(Color.shelfCream.opacity(0.25), lineWidth: 2)
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(Color.shelfCream.opacity(0.45))
                    .frame(width: max(2, size * 0.065), height: size * 0.30)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(Double(i) / 6 * 360))
            }
            Circle().fill(Color.shelfCream.opacity(0.85)).frame(width: size * 0.20, height: size * 0.20)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Reel cue

/// Batch 465: a skip or chapter jump "winds" the skin's reels for a moment. The transport
/// buttons call `wind(_:)`; every `DeckReel` on screen reads it.
@MainActor
@Observable
final class DeckCue {
    static let shared = DeckCue()
    private init() {}

    /// -1 rewinds, +1 fast-forwards.
    private(set) var direction = 0
    private(set) var startedAt: Date?
    /// True for `windSeconds` after a wind; drives the reels' timeline while paused.
    private(set) var isWinding = false
    @ObservationIgnored private var endTask: Task<Void, Never>?

    // `nonisolated` so the pure `windDegreesPerSecond` can read them off the main actor.
    nonisolated static let windSeconds: TimeInterval = 0.7
    /// Peak wind speed, degrees per second (about 4 turns a second).
    nonisolated static let peakWindDegreesPerSecond: Double = 1_440

    func wind(_ direction: Int) {
        self.direction = direction < 0 ? -1 : 1
        startedAt = Date()
        isWinding = true
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.windSeconds))
            guard !Task.isCancelled else { return }
            self?.isWinding = false
        }
    }

    /// The wind's contribution to reel speed: peaks at once, eases to zero over `windSeconds`.
    /// Pure, so the shape is pinned by a test.
    nonisolated static func windDegreesPerSecond(direction: Int, since start: Date?, now: Date) -> Double {
        guard let start, direction != 0 else { return 0 }
        let t = now.timeIntervalSince(start)
        guard t >= 0, t < windSeconds else { return 0 }
        let remaining = 1 - t / windSeconds
        return Double(direction.signum()) * peakWindDegreesPerSecond * remaining * remaining
    }
}

// MARK: - Skin materials

extension DeckSkin {
    /// Each skin's body colour (the face's shell and the transport's key plate). All dark, so
    /// cream detailing and the single amber play key keep their contrast.
    var shellColors: [Color] {
        switch self {
        case .walkman: return [Color(hex: "2E3D4F"), Color(hex: "1B2531")]      // blue steel
        case .reelToReel: return [Color(hex: "4B4B4E"), Color(hex: "262628")]   // brushed graphite
        case .eightTrack: return [Color(hex: "4E301B"), Color(hex: "2C190C")]   // walnut
        case .boombox: return [Color(hex: "262626"), Color(hex: "121212")]      // black plastic
        case .classic, .fromTheCover: return [Color.cassetteShellTop, Color.cassetteShellBottom]
        }
    }

    /// Key cap fill, top to bottom.
    func keyColors(palette: CoverPalette?) -> [Color] {
        switch self {
        case .walkman: return [Color(hex: "E3E6EA"), Color(hex: "A3A8AF")]      // brushed aluminium
        case .reelToReel: return [Color(hex: "F0F0F0"), Color(hex: "8C8C8E")]   // chrome
        case .eightTrack: return [Color(hex: "EFE5D0"), Color(hex: "C9BB9C")]   // cream bakelite
        case .boombox: return [Color(hex: "353535"), Color(hex: "1C1C1C")]      // black rubber
        case .fromTheCover: return (palette ?? .brand).deckKeyTones
        case .classic: return [Color.shelfSurface, Color.shelfSurface]
        }
    }

    /// Glyph ink on the key cap. Light caps get dark ink, measured against the darkest end of
    /// each gradient: Walkman 6.5:1, Reel-to-Reel 4.9:1, 8-Track 7.8:1 (non-text glyphs need
    /// 3:1). Dark caps keep the player's cream.
    ///
    /// Batch 466: the cream is the fixed `deckCream`, not the adaptive `shelfCream`, which turns
    /// espresso in light appearance (device test DS2: Boombox's glyphs vanished on its black
    /// keys). From the Cover picks dark or light ink for its own key colour.
    func keyInk(palette: CoverPalette?) -> Color {
        switch self {
        case .walkman: return Color(hex: "1B2531")
        case .reelToReel: return Color(hex: "202022")
        case .eightTrack: return Color(hex: "3A2312")
        case .fromTheCover: return CoverPalette.ink(on: (palette ?? .brand).deckKeyTones[1])
        case .boombox, .classic: return Color.deckCream
        }
    }

    /// Whether the cap is round (chrome buttons) rather than a key.
    var hasRoundKeys: Bool { self == .reelToReel }

    var keyCornerRadius: CGFloat {
        switch self {
        case .walkman: return 5
        case .eightTrack: return 4
        case .boombox: return 9
        default: return 8
        }
    }

    /// How far a key travels when pressed (and a latched Play key sits), in points.
    var keyTravel: CGFloat {
        switch self {
        case .eightTrack: return 4
        case .walkman, .boombox: return 3
        default: return 2
        }
    }
}

// MARK: - Transport styling

/// The cap drawn behind a transport glyph on a skin: the skin's material, a top highlight, and a
/// hard drop shadow that collapses as the key goes down. Fills the button's 46×46 frame, so the
/// row's spacing maths and 44 pt targets are unchanged.
struct DeckKeyCap: View {
    let skin: DeckSkin
    var palette: CoverPalette?
    var down: Bool

    var body: some View {
        let travel = skin.keyTravel
        let fill = LinearGradient(colors: skin.keyColors(palette: palette), startPoint: .top, endPoint: .bottom)
        let rim = Color.black.opacity(0.55)
        let shine = Color.white.opacity(skin == .boombox || skin == .fromTheCover ? 0.18 : 0.6)
        Group {
            if skin.hasRoundKeys {
                Circle().fill(fill)
                    .overlay(Circle().strokeBorder(rim, lineWidth: 1.5))
                    .overlay(Circle().inset(by: 5).strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                    .overlay(Circle().inset(by: 1.5).trim(from: 0.55, to: 0.95).stroke(shine, lineWidth: 1))
            } else {
                let shape = RoundedRectangle(cornerRadius: skin.keyCornerRadius)
                shape.fill(fill)
                    .overlay(shape.strokeBorder(rim, lineWidth: 1))
                    .overlay(alignment: .top) {
                        shape.inset(by: 1.5).fill(shine).frame(height: 1.5).padding(.horizontal, 4).offset(y: 1.5)
                    }
                    .overlay(skin == .boombox ? shape.strokeBorder(Color(hex: "BFC3C8").opacity(0.55), lineWidth: 1.5) : nil)
            }
        }
        .shadow(color: .black.opacity(down ? 0.15 : 0.55), radius: 0, x: 0, y: down ? 0.5 : travel)
        .offset(y: down ? travel : 0)
    }
}

/// Key styling for a transport button on a non-classic skin.
struct DeckKeyStyle: ButtonStyle {
    let skin: DeckSkin
    var palette: CoverPalette?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .offset(y: down ? skin.keyTravel : 0)
            .background(DeckKeyCap(skin: skin, palette: palette, down: down))
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.7), value: down)
    }
}

/// The housing the five keys sit in: a plate in the skin's body colour, drawn outside the row's
/// own frame (into the column's margin) so the row's width maths is untouched.
struct DeckKeyPlate: View {
    let skin: DeckSkin
    var palette: CoverPalette?

    var body: some View {
        let colors = skin == .fromTheCover ? (palette ?? .brand).deckBodyTones : skin.shellColors
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LinearGradient(colors: [Color.deckCream.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            .accessibilityHidden(true)
    }
}

/// The amber play key's shape per skin. Classic is a circle, exactly as before. On a skin the
/// key latches down while the book plays, the way a deck's Play key stays in. From the Cover's
/// play key takes the cover's own accent instead of amber (Batch 466): it is still the one lit key.
struct DeckPlayShape: View {
    let skin: DeckSkin
    var palette: CoverPalette?
    var latched: Bool = false

    private var fill: Color {
        skin == .fromTheCover ? (palette ?? .brand).primaryAccent : Color.shelfAmber
    }

    var body: some View {
        switch skin {
        case .classic:
            Circle().fill(Color.shelfAmber)
        default:
            cap.shadow(color: .black.opacity(latched ? 0.15 : 0.55), radius: 0, x: 0, y: latched ? 0.5 : skin.keyTravel)
                .offset(y: latched ? skin.keyTravel : 0)
        }
    }

    @ViewBuilder private var cap: some View {
        if skin.hasRoundKeys || skin == .fromTheCover {
            Circle().fill(fill)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1.5))
        } else {
            let shape = RoundedRectangle(cornerRadius: skin == .eightTrack ? 6 : 12)
            shape.fill(fill)
                .overlay(shape.strokeBorder(Color.black.opacity(0.45), lineWidth: 1.5))
                .overlay(alignment: .top) {
                    shape.fill(Color.white.opacity(0.35)).frame(height: 1.5).padding(.horizontal, 8).offset(y: 2)
                }
        }
    }
}
