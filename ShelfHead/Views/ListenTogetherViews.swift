import SwiftUI
import GroupActivities

/// Batch 456: Listen Together (SharePlay) surfaces: the share entry, the in-player status banner,
/// and the "not on your server" notice.

/// "SharePlay" entry for the player's menu. On iOS 17+ a `ShareLink` over a `GroupActivity &
/// Transferable` starts SharePlay when a FaceTime call is active and otherwise offers the system
/// share sheet (Messages etc.), so no separate sharing controller is needed on this deployment
/// target. Apple's HIG uses "SharePlay" as both noun and verb.
struct ListenTogetherButton: View {
    let item: LibraryItem

    var body: some View {
        ShareLink(item: ListenTogetherController.activity(for: item,
                                                           fingerprint: ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL)),
                  preview: SharePreview(Text(verbatim: item.title))) {
            Label("SharePlay", systemImage: "shareplay")
        }
    }
}

/// Persistent strip while a session is live: "SharePlay · 2 people" with a Leave button.
struct ListenTogetherStatusBanner: View {
    @State private var controller = ListenTogetherController.shared

    var body: some View {
        if case .active(let participants, let title) = controller.state {
            HStack(spacing: 12) {
                Image(systemName: "shareplay").foregroundStyle(Color.shelfMuted).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Typo.supporting(Text("SharePlay \u{00B7} \(ListenTogetherLogic.displayCount(participants)) people"),
                                    weight: .semibold)
                        .foregroundStyle(Color.shelfCream)
                    Typo.fine(Text(verbatim: title)).foregroundStyle(Color.shelfMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Leave", role: .destructive) { controller.leave() }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// Alert for a session on a book from another server, or SharePlay being unavailable.
    func listenTogetherNotices() -> some View { modifier(ListenTogetherNoticeModifier()) }
}

private struct ListenTogetherNoticeModifier: ViewModifier {
    @State private var controller = ListenTogetherController.shared

    private var message: (title: LocalizedStringKey, detail: Text)? {
        switch controller.state {
        case .notOnYourServer(let title):
            return ("This book isn't on your server",
                    Text("\(Text(verbatim: title)) is on a different Audiobookshelf server, so you can't listen along."))
        case .unavailable:
            return ("SharePlay isn't available", Text("Listening together couldn't start. Check that SharePlay is on in Settings > FaceTime."))
        default:
            return nil
        }
    }

    func body(content: Content) -> some View {
        content.alert(message?.title ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { controller.dismissNotice() } }
        )) {
            Button("OK", role: .cancel) { controller.dismissNotice() }
        } message: {
            message?.detail
        }
    }
}
