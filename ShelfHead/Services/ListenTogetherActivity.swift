import Foundation
import GroupActivities
import CoreTransferable

/// Batch 456: the SharePlay activity for listening to one book together. It carries the book's
/// `libraryItemId` plus a fingerprint of the sharer's server, so a participant on a different
/// Audiobookshelf server is told "not on your server" instead of opening the wrong book.
///
/// `GroupActivity & Transferable` gets a `GroupActivityTransferRepresentation` for free (iOS 17,
/// from the GroupActivities swiftinterface), which is what makes `ShareLink(item: activity, ...)`
/// start SharePlay, or fall back to the Messages share sheet when no FaceTime call is active.
nonisolated struct ListenTogetherActivity: GroupActivity, Transferable {
    var libraryItemId: String
    var serverFingerprint: String
    var title: String
    var author: String

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.type = .listenTogether
        meta.title = String(localized: "Listen to \(title)", comment: "SharePlay activity title; the interpolation is a book title")
        meta.subtitle = author
        return meta
    }
}

/// Batch 456: messages the participants exchange over `GroupSessionMessenger`. The coordinator
/// syncs play/pause/seek/rate within an item but "doesn't manage the playback queue", so a change of
/// book, or of audio file inside a multi-file book, travels as a message.
nonisolated enum ListenTogetherMessage: Codable, Equatable, Sendable {
    case bookChanged(itemId: String, title: String)
    case trackChanged(itemId: String, trackIndex: Int)
}

/// Batch 456: the UI-facing state of a Listen Together session.
nonisolated enum ListenTogetherState: Equatable, Sendable {
    case idle
    /// Asked to share (or accepted) and waiting for the session to start.
    case waiting
    case active(participants: Int, title: String)
    /// A session offered a book from a different server; we did not join.
    case notOnYourServer(title: String)
    /// SharePlay can't be used (no entitlement, disabled, or the session was invalidated with an error).
    case unavailable
}

nonisolated enum ListenTogetherEvent: Equatable, Sendable {
    case startedSharing
    case sessionOffered(matchesMyServer: Bool, title: String)
    case joined(participants: Int, title: String)
    case participantsChanged(Int)
    case invalidated(failed: Bool)
    case left
    case failedToStart
    case dismissedNotice
    /// Review 4 Medium 7: no session arrived after we asked to share.
    case waitTimedOut
}

/// Batch 456: pure rules for the Listen Together flow (no I/O, unit-tested).
nonisolated enum ListenTogetherLogic {
    /// An empty fingerprint on either side (no usable host) never matches: better to refuse than
    /// to open a book id from an unknown server.
    static func fingerprintsMatch(_ theirs: String, _ mine: String) -> Bool {
        !theirs.isEmpty && theirs == mine
    }

    static func reduce(_ state: ListenTogetherState, _ event: ListenTogetherEvent) -> ListenTogetherState {
        switch event {
        case .startedSharing:
            if case .active = state { return state }
            return .waiting
        case .sessionOffered(let matches, let title):
            // Review 4 Low (foreign offer): a session on another server never clobbers a live or pending one.
            if !matches { switch state { case .waiting, .active: return state; default: break } }
            return matches ? .waiting : .notOnYourServer(title: title)
        case .joined(let count, let title):
            return .active(participants: max(1, count), title: title)
        case .participantsChanged(let count):
            guard case .active(_, let title) = state else { return state }
            return .active(participants: max(1, count), title: title)
        case .invalidated(let failed):
            return failed ? .unavailable : .idle
        case .left:
            return .idle
        case .failedToStart:
            return .unavailable
        case .waitTimedOut:
            if case .waiting = state { return .idle }
            return state
        case .dismissedNotice:
            switch state {
            case .notOnYourServer, .unavailable: return .idle
            default: return state
            }
        }
    }

    /// Review 4 Medium 6: only join once the shared book is actually the one loaded.
    static func shouldJoin(loadedItemId: String?, sharedItemId: String) -> Bool { loadedItemId == sharedItemId }

    /// How long `.waiting` may last with no session arriving before it resets to idle.
    static let waitingTimeout: TimeInterval = 90

    /// "SharePlay · 2 people" style count text is built in the view; this clamps nonsense counts.
    static func displayCount(_ participants: Int) -> Int { max(1, participants) }
}
