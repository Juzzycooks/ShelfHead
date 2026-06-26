import SwiftUI
import UIKit

// MARK: - Color Extensions

extension Color {
    // Retro tape-deck palette — warm espresso shell, amber VU glow, teal accents, cream readout.

    /// Primary amber/gold — VU-meter glow, controls, progress.
    static let shelfAmber = Color(hex: "E8A838")

    /// Deep warm espresso background (the "deck" body).
    static let shelfBackground = Color(hex: "16110C")

    /// Raised brown card / panel.
    static let shelfCard = Color(hex: "241B12")

    /// Retro teal accent for secondary interactive bits.
    static let shelfAccent = Color(hex: "2FB6A8")

    /// Muted warm taupe text.
    static let shelfMuted = Color(hex: "A89177")

    /// Elevated surface (knobs, wells).
    static let shelfSurface = Color(hex: "32261A")

    /// Burnt orange — peaks/emphasis, "record" dot.
    static let shelfOrange = Color(hex: "E0612F")

    /// Cream — primary readout text, like a printed cassette label.
    static let shelfCream = Color(hex: "F4E9D6")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Cover URL helper

func shelfCoverURL(itemId: String, width: Int = 300) -> URL? {
    // Prefer a locally-cached cover so downloaded books show art offline.
    if let local = DownloadManager.shared.localCoverURL(itemId: itemId) { return local }
    let server = AuthStore.shared.serverURL
    let token = AuthStore.shared.accessToken
    // Token goes in the query string: the cover endpoint is built for <img>-style GETs,
    // and an Authorization header can be stripped by reverse proxies (e.g. nginx).
    return URL(string: "\(server)/api/items/\(itemId)/cover?width=\(width)&token=\(token)")
}

// MARK: - View Extensions

extension View {
    func shelfCardStyle() -> some View {
        self
            .background(Color.shelfCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Presents an alert whenever `message` becomes non-nil, clearing it on dismiss.
    /// Pass `retry` to add a Retry button (e.g. for failed loads).
    func errorAlert(title: String = "Something went wrong", message: Binding<String?>, retry: (() -> Void)? = nil) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            if let retry {
                Button("Retry") {
                    message.wrappedValue = nil
                    retry()
                }
            }
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    /// Shows a transient toast at the bottom whenever `message` becomes non-nil.
    func toast(message: Binding<String?>, duration: Double = 3) -> some View {
        modifier(ToastModifier(message: message, duration: duration))
    }

    func shelfButtonStyle() -> some View {
        self
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.shelfAmber)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Toast

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let duration: Double

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(msg)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 140)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        withAnimation { message = nil }
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: message)
    }
}

// MARK: - Cached cover image

/// In-memory cover cache so rebuilding a view (e.g. the tab "scroll to top" reset)
/// repaints artwork instantly instead of re-fetching and flashing blank.
enum CoverImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 96 * 1024 * 1024   // ~96 MB cap so decoded covers can't grow unbounded
        return c
    }()
}

/// A cover that fills its frame, backed by `CoverImageCache`. Reads the cache
/// synchronously at init, so a cached image shows immediately with no blank frame.
struct CachedCover: View {
    let url: URL?
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { CoverImageCache.shared.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.shelfSurface)
                    .overlay(Image(systemName: "book.closed.fill").foregroundColor(Color.shelfMuted))
            }
        }
        .task(id: url) {
            if image != nil { return }
            guard let url else { return }
            if let cached = CoverImageCache.shared.object(forKey: url as NSURL) {
                image = cached
                return
            }
            if let (data, _) = try? await URLSession.shared.data(from: url), let ui = UIImage(data: data) {
                CoverImageCache.shared.setObject(ui, forKey: url as NSURL, cost: data.count)
                image = ui
            }
        }
    }
}

// MARK: - Cover Image View

struct CoverImageView: View {
    let itemId: String
    let width: CGFloat
    let height: CGFloat

    init(itemId: String, width: CGFloat = 120, height: CGFloat = 120) {
        self.itemId = itemId
        self.width = width
        self.height = height
    }

    var body: some View {
        CachedCover(url: shelfCoverURL(itemId: itemId, width: Int(width * 2)))
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Progress Bar

struct BookProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.shelfSurface)
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.shelfAmber)
                    .frame(width: geometry.size.width * min(progress, 1.0), height: 4)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Loading View

struct LoadingView: View {
    let message: String

    init(_ message: String = "Loading...") {
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.shelfAmber)
                .scaleEffect(1.2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(Color.shelfMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(Color.shelfMuted)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(Color.shelfMuted)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
