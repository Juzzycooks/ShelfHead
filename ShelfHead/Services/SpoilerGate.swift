import Foundation

/// Batch 455: the pure rules behind Book Club. No I/O, no UI; pinned by `HouseholdSocialTests`.

/// A post is a spoiler until your own position in the book passes its timestamp. Your own posts are always
/// visible (you wrote them). Posts beyond your position collapse into a count the view shows as one row.
nonisolated enum SpoilerGate {
    struct Result: Equatable {
        /// In book order (position, then time).
        var visible: [HouseholdClubPost]
        var hiddenAheadCount: Int
    }

    /// `myPosition` is seconds into the book. Pass `.infinity` for a finished book so everything shows.
    static func filter(posts: [HouseholdClubPost], myPosition: Double, myMemberId: String?) -> Result {
        let ordered = posts.sorted { ($0.positionSeconds, $0.createdAt) < ($1.positionSeconds, $1.createdAt) }
        var visible: [HouseholdClubPost] = []
        var hidden = 0
        for post in ordered {
            if post.memberId == myMemberId || post.positionSeconds <= myPosition {
                visible.append(post)
            } else {
                hidden += 1
            }
        }
        return Result(visible: visible, hiddenAheadCount: hidden)
    }
}

/// A club's optional goal ("Chapter 12 by Friday") and how far each member is toward it.
nonisolated enum ClubGoal {
    enum MemberStatus: Equatable {
        /// The member isn't sharing what they listen to, or is on a different book.
        case notShared
        /// Still short of the goal position by this many seconds.
        case behind(secondsToGo: Double)
        case reached
    }

    /// The member's whole-book progress (0...1) when their shared Now Listening record is for this club's
    /// book; nil otherwise. Matching is by library item id on the same server, or by title and author when
    /// the club has no item id or the member is on another server (Batch 482: clubs span servers).
    static func sharedProgress(of nowListening: HouseholdNowListening?, in club: HouseholdClub) -> Double? {
        guard let nowListening else { return nil }
        if let itemId = club.libraryItemId, !itemId.isEmpty, !club.serverFingerprint.isEmpty,
           nowListening.serverFingerprint == club.serverFingerprint {
            guard nowListening.libraryItemId == itemId,
                  nowListening.serverFingerprint == club.serverFingerprint else { return nil }
        } else {
            guard nowListening.title.lowercased() == club.title.lowercased(),
                  nowListening.author.lowercased() == club.author.lowercased() else { return nil }
        }
        return min(max(nowListening.progress, 0), 1)
    }

    static func status(sharedProgress: Double?, bookDuration: Double, goalSeconds: Double) -> MemberStatus {
        guard let sharedProgress, bookDuration > 0 else { return .notShared }
        let position = min(max(sharedProgress, 0), 1) * bookDuration
        return position >= goalSeconds ? .reached : .behind(secondsToGo: goalSeconds - position)
    }

    /// 0...1 of the way to the goal position. 1 when the goal is at or before the start.
    static func fractionOfGoal(sharedProgress: Double?, bookDuration: Double, goalSeconds: Double) -> Double {
        guard let sharedProgress, bookDuration > 0 else { return 0 }
        guard goalSeconds > 0 else { return 1 }
        let position = min(max(sharedProgress, 0), 1) * bookDuration
        return min(max(position / goalSeconds, 0), 1)
    }

    /// Whole days from `now` to `goalDate` (calendar days, so "tomorrow" is 1); negative once it has passed.
    static func daysLeft(goalDate: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let goalDate else { return nil }
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: goalDate)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    /// A goal is worth showing when it has text, a target position, or a date.
    static func hasGoal(_ club: HouseholdClub?) -> Bool {
        guard let club else { return false }
        let hasText = !(club.goalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasText || club.goalSeconds != nil || club.goalDate != nil
    }
}

/// Post text rules, shared by the composer and tests.
nonisolated enum ClubPostDraft {
    static let maxLength = 500

    static func clamped(_ text: String) -> String { String(text.prefix(maxLength)) }

    static func canPost(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
