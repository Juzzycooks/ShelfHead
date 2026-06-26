import SwiftUI

// MARK: - Cassette Reel (spins while playing)

struct CassetteReel: View {
    var spinning: Bool
    var size: CGFloat = 46

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate * 60  // ~60°/sec
            reel.rotationEffect(.degrees(spinning ? degrees : 0))
        }
        .frame(width: size, height: size)
    }

    private var reel: some View {
        ZStack {
            Circle().fill(Color.shelfSurface)
            Circle().strokeBorder(Color.shelfCream.opacity(0.25), lineWidth: 2)
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(Color.shelfCream.opacity(0.45))
                    .frame(width: 3, height: size * 0.30)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(Double(i) / 6 * 360))
            }
            Circle().fill(Color.shelfCream.opacity(0.85)).frame(width: size * 0.20, height: size * 0.20)
        }
    }
}

// MARK: - Cassette body framing the cover art

struct CassetteView: View {
    let coverURL: URL?
    var spinning: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "3A2B1C"), Color(hex: "281D12")],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 18, x: 0, y: 12)

            VStack(spacing: 12) {
                // Printed label = the cover art
                ZStack {
                    CachedCover(url: coverURL)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.55, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.shelfCream.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.top, 14)

                // Reel window
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.35))
                    HStack(spacing: 0) {
                        CassetteReel(spinning: spinning)
                        Spacer()
                        // tape strip between reels
                        Rectangle().fill(Color.shelfCream.opacity(0.12)).frame(height: 6)
                        Spacer()
                        CassetteReel(spinning: spinning)
                    }
                    .padding(.horizontal, 26)
                }
                .frame(height: 60)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        // Size to the content (cover + reel window) rather than a fixed ratio that
        // could clip and bleed over the title beneath it.
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Waveform scrubber

struct WaveformScrubber: View {
    @Binding var value: Double                 // 0...1
    var onEditingChanged: (Bool) -> Void
    @State private var isEditing = false

    private let barCount = 50
    private let heights: [CGFloat]

    init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
        self._value = value
        self.onEditingChanged = onEditingChanged
        // Deterministic pseudo-waveform so it doesn't jitter between renders.
        self.heights = (0..<50).map { i in
            let x = Double(i)
            let v = abs(sin(x * 0.7) * 0.6 + sin(x * 0.27) * 0.4)
            return CGFloat(0.28 + 0.72 * v)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let filled = Int((value * Double(barCount)).rounded())
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= filled ? Color.shelfAmber : Color.shelfMuted.opacity(0.30))
                        .frame(height: max(3, heights[i] * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isEditing { isEditing = true; onEditingChanged(true) }
                        value = min(max(0, g.location.x / geo.size.width), 1)
                    }
                    .onEnded { _ in
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 44)
    }
}

// MARK: - Cassette-styled cover tile (for grids & shelves)

struct CassetteTile: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    var progress: Double = 0
    var downloaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                CachedCover(url: coverURL)

                // "tape window" band across the bottom
                HStack(spacing: 6) {
                    reelHub
                    Rectangle().fill(Color.shelfCream.opacity(0.25)).frame(height: 3)
                    reelHub
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.5))
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.shelfCream.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Color.shelfAmber)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }

            if progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.shelfCream.opacity(0.12)).frame(height: 3)
                        Capsule().fill(Color.shelfAmber).frame(width: geo.size.width * min(progress, 1), height: 3)
                    }
                }
                .frame(height: 3)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(Color.shelfCream)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(Color.shelfMuted)
                .lineLimit(1)
        }
    }

    private var reelHub: some View {
        Circle()
            .fill(Color.shelfSurface)
            .overlay(Circle().strokeBorder(Color.shelfCream.opacity(0.5), lineWidth: 2))
            .overlay(Circle().fill(Color.shelfCream.opacity(0.8)).frame(width: 4, height: 4))
            .frame(width: 14, height: 14)
    }
}

// MARK: - Printed-label section header

struct RetroSectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "recordingtape")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.shelfAmber)
            Text(title.uppercased())
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundColor(Color.shelfCream.opacity(0.85))
            Rectangle()
                .fill(
                    LinearGradient(colors: [Color.shelfAmber.opacity(0.5), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .frame(height: 1)
        }
    }
}

// MARK: - Tape-deck tab bar

struct RetroTabItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
}

struct RetroTabBar: View {
    @Binding var selection: Int
    let items: [RetroTabItem]
    var onRetap: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    if selection == index {
                        // Same tab tapped again — notify parent to pop to root
                        onRetap?(index)
                    }
                    selection = index
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                        Text(item.label.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1)
                    }
                    .foregroundColor(selection == index ? Color.shelfAmber : Color.shelfCream.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.shelfAmber)
                            .frame(width: 16, height: 3)
                            .opacity(selection == index ? 1 : 0)
                            .offset(y: -8)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.shelfCard.opacity(0.35)   // subtle warm tint over the glass
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.shelfAmber.opacity(0.18)).frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Tape counter readout (mechanical digits)

struct TapeCounter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(Color.shelfCream)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.shelfCream.opacity(0.12), lineWidth: 1))
    }
}
